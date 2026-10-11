"""The web session for the lost-phone pages (``/a/login``, ``/a/checkin``, ``/a/safe``).

PRD FR-CHK-07: someone who has lost their phone can still check in, and can still tell their
contacts they are safe. Everything here is the same logic as the app's, reached through a
different door, with the same limits and the same safety rules:

* signing in is the API's sign-in (same lockout, same per-account failure budget, same audit),
  and it tells the person by email that the web page was used;
* the session is ``kind = 'web'``: one hour, then gone; its cookie is an opaque secret whose
  SHA-256 is all that is stored (never a bearer token in a URL, never a refresh token);
* signing in counts as a password confirmation for five minutes, exactly like ``/auth/reauth``;
  I'M SAFE asks for the password again once those minutes have passed.
"""

from __future__ import annotations

import re
import secrets
from datetime import datetime, timedelta
from typing import Final
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.api.deps import CurrentUser, has_fresh_reauth
from app.audit import writer as audit
from app.auth.service import AuthService
from app.core.errors import InvalidCredentials
from app.core.net import rate_limit_subject
from app.core.validation import normalize_email
from app.notifications.mailer import EmailTemplate
from app.security.hashing import sha256
from app.security.rate_limit import (
    LOGIN_PER_ACCOUNT_NETWORK,
    REAUTH_PER_SESSION,
    WEB_LOGIN_PER_IP,
)

WEB_COOKIE: Final = "__Host-afterme_web"
WEB_SESSION_TTL: Final = timedelta(hours=1)
_TOKEN_PREFIX: Final = "wt_"  # noqa: S105
_TOKEN_RE: Final = re.compile(r"^wt_[A-Za-z0-9_-]{43}$")
_FORM_KEY_RE: Final = re.compile(r"^[A-Za-z0-9_.:-]{16,64}$")


def new_form_key() -> str:
    """A one-time key for a form: submitting the same page twice is one check-in."""
    return "web-" + secrets.token_urlsafe(24)


def valid_form_key(value: str) -> bool:
    return _FORM_KEY_RE.fullmatch(value) is not None


class WebSessionService(AuthService):
    async def sign_in(self, email: str, password: str) -> str:
        """Returns the cookie value. Raises :class:`InvalidCredentials` (one answer for every
        failure) or :class:`RateLimited`."""
        now = await self._now()
        await self._limit(WEB_LOGIN_PER_IP, rate_limit_subject(self.ctx.client_ip), now)
        email_norm = normalize_email(email)
        budget = self._budget_subject(email_norm)
        self.ctx.note_rate_limit(
            await self.services.limiter.check(LOGIN_PER_ACCOUNT_NETWORK, budget, now=now)
        )

        user = await self.users.get_by_email(email_norm)
        if user is None:
            await self.services.passwords.dummy_verify(password)
            await self.services.limiter.hit([(LOGIN_PER_ACCOUNT_NETWORK, budget)], now=now)
            raise InvalidCredentials
        if user.locked_until is not None and user.locked_until > now:
            # The same work and the same answer as a wrong password (nothing says the address
            # exists or is locked); a browser has no known device, so the lock binds it.
            await self.services.passwords.verify(user.password_hash, password)
            await self.services.limiter.hit([(LOGIN_PER_ACCOUNT_NETWORK, budget)], now=now)
            raise InvalidCredentials
        verified_hash = user.password_hash
        if not await self.services.passwords.verify(verified_hash, password):
            await self._record_failed_login(user, now, budget)
            raise InvalidCredentials

        locked = await self.users.get(user.id, for_update=True)
        if (
            locked is None
            or locked.password_hash != verified_hash
            or locked.status != "active"
            or locked.email_verified_at is None
            or (locked.locked_until is not None and locked.locked_until > now)
        ):
            raise InvalidCredentials
        locked.failed_login_count = 0
        locked.locked_until = None
        locked.last_login_at = now
        locked.updated_at = now

        token = _TOKEN_PREFIX + secrets.token_urlsafe(32)
        expires = now + WEB_SESSION_TTL
        auth_session = await self.sessions.create(
            owner_id=locked.id,
            device_id=None,
            ip_hash=self.ctx.ip_hash,
            user_agent=self.ctx.user_agent,
            now=now,
            idle_expires_at=expires,
            absolute_expires_at=expires,
            kind="web",
            web_token_hash=sha256(token),
            reauthenticated_at=now,
        )
        await self.services.audit.record(
            self.session,
            self._event(
                audit.WEB_LOGIN_SUCCEEDED,
                now,
                locked.id,
                resource_type="session",
                resource_id=auth_session.id,
            ),
        )
        notice = self.services.mailer.render(
            EmailTemplate.WEB_LOGIN_NOTICE,
            to=locked.email,
            site=self.settings.public_base_url,
        )
        await self._commit_and_send([notice])
        return token

    async def resolve(self, token: str | None) -> CurrentUser | None:
        """The signed-in person for this cookie, or ``None`` (no cookie, unknown, expired,
        revoked, or the account is no longer usable)."""
        if token is None or _TOKEN_RE.fullmatch(token) is None:
            return None
        now = await self._now()
        row = await self.sessions.get_by_web_token(sha256(token))
        if row is None:
            return None
        auth_session, user = row
        if (
            auth_session.revoked_at is not None
            or auth_session.idle_expires_at <= now
            or auth_session.absolute_expires_at <= now
            or user.status != "active"
            or user.email_verified_at is None
        ):
            return None
        return CurrentUser(
            user_id=user.id,
            session_id=auth_session.id,
            device_id=None,
            email=user.email,
            tier=user.tier,
            status=user.status,
            reauthenticated_at=auth_session.reauthenticated_at,
        )

    async def confirm_password(self, current: CurrentUser, password: str) -> CurrentUser | None:
        """Confirm the password for I'M SAFE. Returns the person with a fresh confirmation, or
        ``None`` when the password is wrong. Shares the 5-per-15-minutes budget of
        ``/auth/reauth``: both are password-guessing oracles for a stolen session."""
        now = await self._now()
        if has_fresh_reauth(current, now) and not password:
            return current
        await self._limit(REAUTH_PER_SESSION, str(current.session_id), now)
        user = await self.users.get(current.user_id)
        if user is None or not await self.services.passwords.verify(user.password_hash, password):
            await self.services.audit.record_independent(
                self._event(
                    audit.REAUTH_FAILED,
                    now,
                    current.user_id,
                    resource_type="session",
                    resource_id=current.session_id,
                    reason="web_safe",
                )
            )
            return None
        await self.sessions.set_reauthenticated(
            owner_id=current.user_id, session_id=current.session_id, now=now
        )
        await self.session.commit()
        return CurrentUser(
            user_id=current.user_id,
            session_id=current.session_id,
            device_id=None,
            email=current.email,
            tier=current.tier,
            status=current.status,
            reauthenticated_at=now,
        )

    async def logout(self, current: CurrentUser) -> None:
        now = await self._now()
        await self.sessions.revoke(
            owner_id=current.user_id, session_id=current.session_id, reason="logout", now=now
        )
        await self.session.commit()


def format_local(moment: datetime | None, timezone: str) -> str:
    """``Fri 9 Oct, 8:00 PM`` in the person's own timezone (or UTC for an unknown zone)."""
    if moment is None:
        return ""
    try:
        zone = ZoneInfo(timezone)
    except (ZoneInfoNotFoundError, ValueError):
        zone = ZoneInfo("UTC")
    local = moment.astimezone(zone)
    hour = local.strftime("%I").lstrip("0") or "12"
    day = f"{local.strftime('%a')} {local.day} {local.strftime('%b')}"
    return f"{day}, {hour}:{local.strftime('%M %p')}"
