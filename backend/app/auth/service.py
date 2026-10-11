"""Authentication business rules (API_SPEC §2; SECURITY §6.3, §7; DATABASE §3.1).

Transaction discipline:
* Every method commits the request transaction explicitly before returning success.
* Bookkeeping that must survive an error response (rate-limit counters, failed-login counters
  and lockout, code attempts, failure audit records) is committed in independent transactions,
  always *before* the request transaction locks or writes the same rows.
* Emails are sent only after the relevant transaction has committed.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Final

from app.api.deps import CurrentUser
from app.audit import writer as audit
from app.auth.base import AuthServiceBase
from app.auth.codes import (
    CODE_MAX_ATTEMPTS,
    CODE_RESEND_INTERVAL,
    CODE_TTL,
    code_matches,
    generate_code,
    hash_code,
)
from app.auth.models import AuthSession, Device, RefreshToken, User
from app.auth.repository import (
    AuthTokenRepository,
    CheckinBootstrapRepository,
    UserRepository,
)
from app.auth.schemas import (
    DeviceInfo,
    LoginDeviceInfo,
    LoginRequest,
    ReauthRequest,
    RefreshRequest,
    RegisterResendRequest,
    RegisterStartRequest,
    RegisterVerifyRequest,
    SessionDevice,
    SessionItem,
    SessionList,
)
from app.auth.tokens import (
    IssuedAccessToken,
    hash_refresh_token,
    looks_like_refresh_token,
    new_refresh_token,
)
from app.core.errors import (
    EmailUnverified,
    InvalidCode,
    InvalidCredentials,
    NotFound,
    SessionRevoked,
)
from app.notifications.email import EmailMessage
from app.notifications.mailer import EmailTemplate
from app.plans.repository import PlanRepository
from app.security.rate_limit import (
    LOGIN_PER_ACCOUNT_NETWORK,
    REAUTH_PER_SESSION,
    REFRESH_PER_SESSION,
    REGISTER_PER_EMAIL,
    REGISTER_PER_EMAIL_NETWORK,
)

SIGNUP_PURPOSE: Final = "signup_verify"
LOCK_THRESHOLD: Final = 10
LOCK_DURATION: Final = timedelta(minutes=15)
REFRESH_RETRY_GRACE: Final = timedelta(seconds=30)


@dataclass(frozen=True)
class IssuedSession:
    access: IssuedAccessToken
    refresh_token: str
    session_id: uuid.UUID
    device_id: uuid.UUID
    user_id: uuid.UUID
    email: str
    tier: str


@dataclass(frozen=True)
class RotatedTokens:
    access: IssuedAccessToken
    refresh_token: str


class AuthService(AuthServiceBase):
    async def _issue_signup_code(self, user_id: uuid.UUID, now: datetime) -> str:
        await self.codes.invalidate_unused(owner_id=user_id, purpose=SIGNUP_PURPOSE, now=now)
        code = generate_code()
        await self.codes.create_code(
            owner_id=user_id,
            purpose=SIGNUP_PURPOSE,
            secret_hash=hash_code(
                self.services.pepper, user_id=user_id, purpose=SIGNUP_PURPOSE, code=code
            ),
            expires_at=now + CODE_TTL,
            now=now,
        )
        return code

    def _signup_code_email(self, *, to: str, display_name: str, code: str) -> EmailMessage:
        return self.services.mailer.render(
            EmailTemplate.SIGNUP_CODE,
            to=to,
            display_name=display_name,
            code=code,
            expires_minutes=int(CODE_TTL.total_seconds() // 60),
        )

    async def _create_device(self, user_id: uuid.UUID, info: DeviceInfo, now: datetime) -> Device:
        return await self.devices.create(
            owner_id=user_id,
            platform=info.platform,
            app_version=info.app_version,
            os_version=info.os_version,
            locale=info.locale,
            now=now,
        )

    async def _resolve_login_device(
        self, user_id: uuid.UUID, info: LoginDeviceInfo, now: datetime
    ) -> tuple[uuid.UUID, bool]:
        """Reuse the device when the ID belongs to this user; otherwise register a new one."""
        if info.id is not None:
            existing = await self.devices.get(owner_id=user_id, device_id=info.id)
            if existing is not None:
                await self.devices.update_info(
                    owner_id=user_id,
                    device_id=existing.id,
                    app_version=info.app_version,
                    os_version=info.os_version,
                    locale=info.locale,
                    now=now,
                )
                return existing.id, False
        device = await self._create_device(user_id, info, now)
        return device.id, True

    async def _open_session(
        self, user: User, *, device_id: uuid.UUID, now: datetime
    ) -> IssuedSession:
        absolute = now + timedelta(days=self.settings.session_absolute_days)
        idle = min(now + timedelta(days=self.settings.session_idle_days), absolute)
        auth_session = await self.sessions.create(
            owner_id=user.id,
            device_id=device_id,
            ip_hash=self.ctx.ip_hash,
            user_agent=self.ctx.user_agent,
            now=now,
            idle_expires_at=idle,
            absolute_expires_at=absolute,
        )
        refresh = new_refresh_token()
        await self.refresh_tokens.create(
            session_id=auth_session.id,
            token_hash=hash_refresh_token(refresh),
            expires_at=idle,
            now=now,
        )
        access = self.services.tokens.issue(user_id=user.id, session_id=auth_session.id, now=now)
        return IssuedSession(
            access=access,
            refresh_token=refresh,
            session_id=auth_session.id,
            device_id=device_id,
            user_id=user.id,
            email=user.email,
            tier=user.tier,
        )

    # ------------------------------------------------------------------ signup

    async def register_start(self, body: RegisterStartRequest) -> None:
        """Always the same outcome for the caller (no account enumeration, T18)."""
        now = await self._now()
        email_norm = body.email_normalized
        await self._limit_email(REGISTER_PER_EMAIL_NETWORK, REGISTER_PER_EMAIL, email_norm, now)

        # Hash in every branch so the response time does not reveal which branch ran.
        password_hash = await self.services.passwords.hash(body.password)

        inserted_id = await self.users.insert_if_absent(
            email=body.email, email_normalized=email_norm, password_hash=password_hash, now=now
        )
        user = await self.users.get_by_email(email_norm, for_update=True)
        if user is None:  # pragma: no cover - the row was just inserted or already existed
            raise InvalidCredentials

        outbox: list[EmailMessage] = []
        if user.email_verified_at is not None:
            outcome = "account_exists"
            outbox.append(self.services.mailer.render(EmailTemplate.ACCOUNT_EXISTS, to=user.email))
        else:
            outcome = "new" if inserted_id is not None else "replaced_pending"
            if inserted_id is None:
                # An unverified signup is replaced by the newest attempt.
                user.email = body.email
                user.password_hash = password_hash
                user.password_changed_at = now
                user.updated_at = now
            await self.profiles.upsert(
                owner_id=user.id,
                display_name=body.display_name,
                timezone=body.timezone,
                locale=body.locale,
                country_code=body.country_code,
                now=now,
            )
            code = await self._issue_signup_code(user.id, now)
            outbox.append(
                self._signup_code_email(to=user.email, display_name=body.display_name, code=code)
            )

        await self.services.audit.record(
            self.session,
            self._event(audit.SIGNUP_STARTED, now, user.id, unauthenticated=True, outcome=outcome),
        )
        await self._commit_and_send(outbox)

    async def register_resend(self, body: RegisterResendRequest) -> None:
        now = await self._now()
        email_norm = body.email_normalized
        await self._limit_email(REGISTER_PER_EMAIL_NETWORK, REGISTER_PER_EMAIL, email_norm, now)

        outbox: list[EmailMessage] = []
        user = await self.users.get_by_email(email_norm, for_update=True)
        if user is not None and user.email_verified_at is None and user.status == "active":
            latest = await self.codes.latest_unused(owner_id=user.id, purpose=SIGNUP_PURPOSE)
            if latest is None or now - latest.created_at >= CODE_RESEND_INTERVAL:
                code = await self._issue_signup_code(user.id, now)
                outbox.append(
                    self._signup_code_email(
                        to=user.email, display_name=await self._display_name(user.id), code=code
                    )
                )
        await self._commit_and_send(outbox)

    async def register_verify(self, body: RegisterVerifyRequest) -> IssuedSession:
        now = await self._now()
        email_norm = body.email_normalized
        user = await self.users.get_by_email(email_norm)
        if user is None or user.email_verified_at is not None or user.status != "active":
            raise InvalidCode
        token = await self.codes.latest_unused(owner_id=user.id, purpose=SIGNUP_PURPOSE)
        if token is None or token.expires_at <= now:
            raise InvalidCode

        # Count the attempt first, in its own committed transaction: concurrent guesses can
        # never exceed the limit, and the count survives the error response.
        async with self.services.db.independent_session() as bookkeeping:
            attempts = await AuthTokenRepository(bookkeeping).consume_attempt(
                owner_id=user.id, token_id=token.id, max_attempts=CODE_MAX_ATTEMPTS, now=now
            )
        if attempts is None or not code_matches(
            self.services.pepper,
            token.secret_hash,
            user_id=user.id,
            purpose=SIGNUP_PURPOSE,
            code=body.code,
        ):
            raise InvalidCode

        # The signup password must match too (see RegisterVerifyRequest). Checked before taking
        # the row lock because Argon2 is slow; the lock below re-checks the hash is unchanged.
        if not await self.services.passwords.verify(user.password_hash, body.password):
            raise InvalidCode

        # Lock order matches start/resend/login: user row first, then the token row. The opposite
        # order lets a verify and a resend/login for the same account deadlock.
        locked_user = await self.users.get_by_email(email_norm, for_update=True)
        if (
            locked_user is None
            or locked_user.email_verified_at is not None
            or locked_user.password_hash != user.password_hash  # replaced by a newer signup
        ):
            raise InvalidCode
        if not await self.codes.mark_used(owner_id=user.id, token_id=token.id, now=now):
            raise InvalidCode
        locked_user.email_verified_at = now
        locked_user.updated_at = now
        await CheckinBootstrapRepository(self.session).create_default(owner_id=user.id, now=now)
        await PlanRepository(self.session).ensure(owner_id=user.id, now=now)
        device = await self._create_device(user.id, body.device, now)
        issued = await self._open_session(locked_user, device_id=device.id, now=now)
        await self.services.audit.record(
            self.session,
            self._event(
                audit.SIGNUP_VERIFIED,
                now,
                user.id,
                resource_type="session",
                resource_id=issued.session_id,
                device_id=device.id,
            ),
        )
        await self.session.commit()
        return issued

    # ------------------------------------------------------------------ login

    async def login(self, body: LoginRequest) -> IssuedSession:
        now = await self._now()
        email_norm = body.email_normalized
        # Only failed attempts consume the budget (API_SPEC §16): read it here, count failures
        # below. The budget is per (account, network), never per account alone: a stranger who
        # knows an address must not be able to keep its owner out (Phase 9, F1).
        budget = self._budget_subject(email_norm)
        self.ctx.note_rate_limit(
            await self.services.limiter.check(LOGIN_PER_ACCOUNT_NETWORK, budget, now=now)
        )

        user = await self.users.get_by_email(email_norm)
        if user is None:
            await self.services.passwords.dummy_verify(body.password)  # equalise timing
            await self.services.limiter.hit([(LOGIN_PER_ACCOUNT_NETWORK, budget)], now=now)
            await self.services.audit.record_independent(
                self._event(
                    audit.LOGIN_FAILED, now, None, unauthenticated=True, reason="unknown_account"
                )
            )
            raise InvalidCredentials

        # A locked account answers exactly like a wrong password: same work, same 401, nothing
        # that tells a stranger the address exists or that it is locked. The lock does not bind
        # a phone the account already knows (an unguessable device id) with the right password.
        lock_applies = user.locked_until is not None and user.locked_until > now
        lock_exempt = False
        if lock_applies:
            known = body.device.id is not None and (
                await self.devices.get(owner_id=user.id, device_id=body.device.id) is not None
            )
            correct = await self.services.passwords.verify(user.password_hash, body.password)
            if not (known and correct):
                await self.services.limiter.hit([(LOGIN_PER_ACCOUNT_NETWORK, budget)], now=now)
                await self.services.audit.record_independent(
                    self._event(
                        audit.LOGIN_FAILED, now, user.id, unauthenticated=True, reason="locked"
                    )
                )
                raise InvalidCredentials
            lock_exempt = True

        verified_hash = user.password_hash
        if not lock_exempt and not await self.services.passwords.verify(
            verified_hash, body.password
        ):
            await self._record_failed_login(user, now, budget)
            raise InvalidCredentials

        # Serialise with a concurrent reset / password change: they lock the user row, revoke
        # every session and commit. Re-read the row under the lock and refuse if the credential
        # we just verified is no longer the current one, so no session can outlive that revoke.
        locked = await self.users.get(user.id, for_update=True)
        if (
            locked is None
            or locked.password_hash != verified_hash
            or (not lock_exempt and locked.locked_until is not None and locked.locked_until > now)
        ):
            await self.services.audit.record_independent(
                self._event(
                    audit.LOGIN_FAILED,
                    now,
                    user.id,
                    unauthenticated=True,
                    reason="credential_changed",
                )
            )
            raise InvalidCredentials
        user = locked

        if user.status != "active":
            await self.services.audit.record_independent(
                self._event(
                    audit.LOGIN_FAILED,
                    now,
                    user.id,
                    unauthenticated=True,
                    reason="account_inactive",
                )
            )
            raise InvalidCredentials

        user.failed_login_count = 0
        user.locked_until = None
        user.updated_at = now

        if user.email_verified_at is None:
            outbox: list[EmailMessage] = []
            latest = await self.codes.latest_unused(owner_id=user.id, purpose=SIGNUP_PURPOSE)
            if latest is None or now - latest.created_at >= CODE_RESEND_INTERVAL:
                code = await self._issue_signup_code(user.id, now)
                outbox.append(
                    self._signup_code_email(
                        to=user.email, display_name=await self._display_name(user.id), code=code
                    )
                )
            await self.services.audit.record(
                self.session,
                self._event(
                    audit.LOGIN_FAILED,
                    now,
                    user.id,
                    unauthenticated=True,
                    reason="email_unverified",
                ),
            )
            await self._commit_and_send(outbox)
            raise EmailUnverified

        if self.services.passwords.needs_rehash(user.password_hash):
            user.password_hash = await self.services.passwords.hash(body.password)
        user.last_login_at = now

        device_id, new_device = await self._resolve_login_device(user.id, body.device, now)
        issued = await self._open_session(user, device_id=device_id, now=now)
        await self.services.audit.record(
            self.session,
            self._event(
                audit.LOGIN_SUCCEEDED,
                now,
                user.id,
                resource_type="session",
                resource_id=issued.session_id,
                user_visible=new_device,
                device_id=device_id,
                new_device=new_device,
            ),
        )
        outbox = (
            [
                self.services.mailer.render(
                    EmailTemplate.NEW_DEVICE_LOGIN,
                    to=user.email,
                    platform=body.device.platform,
                    app_version=body.device.app_version,
                )
            ]
            if new_device
            else []
        )
        await self._commit_and_send(outbox)
        return issued

    async def _record_failed_login(self, user: User, now: datetime, budget: str) -> None:
        """Count the failure and maybe lock, on a separate connection (survives the 401)."""
        await self.services.limiter.hit([(LOGIN_PER_ACCOUNT_NETWORK, budget)], now=now)
        async with self.services.db.independent_session() as bookkeeping:
            outcome = await UserRepository(bookkeeping).record_failed_login(
                user.id, now=now, threshold=LOCK_THRESHOLD, lock_until=now + LOCK_DURATION
            )
            writer = self.services.audit
            await writer.record(
                bookkeeping,
                self._event(
                    audit.LOGIN_FAILED, now, user.id, unauthenticated=True, reason="bad_password"
                ),
            )
            if outcome.locked_now:
                await writer.record(
                    bookkeeping,
                    self._event(
                        audit.LOCKED,
                        now,
                        user.id,
                        unauthenticated=True,
                        reason="too_many_failures",
                        lock_minutes=int(LOCK_DURATION.total_seconds() // 60),
                    ),
                )
        if outcome.locked_now:
            await self.services.mailer.deliver(
                [
                    self.services.mailer.render(
                        EmailTemplate.ACCOUNT_LOCKED,
                        to=user.email,
                        lock_minutes=int(LOCK_DURATION.total_seconds() // 60),
                    )
                ]
            )

    # ------------------------------------------------------------------ refresh

    async def refresh(self, body: RefreshRequest) -> RotatedTokens:
        now = await self._now()
        presented = body.refresh_token
        if not looks_like_refresh_token(presented):
            raise SessionRevoked
        token_hash = hash_refresh_token(presented)

        owner = await self.refresh_tokens.find_owner(token_hash)
        if owner is None:
            raise SessionRevoked
        session_id, user_id = owner
        await self._limit(REFRESH_PER_SESSION, str(session_id), now)

        # Lock order: session row first, then token rows. Every refresh of one session
        # serialises on the session row, so rotation and retry handling cannot interleave.
        auth_session = await self.sessions.get(
            owner_id=user_id, session_id=session_id, for_update=True
        )
        token = await self.refresh_tokens.lock_by_hash(session_id=session_id, token_hash=token_hash)
        if auth_session is None or token is None:
            raise SessionRevoked
        if (
            auth_session.revoked_at is not None
            or auth_session.idle_expires_at <= now
            or auth_session.absolute_expires_at <= now
            or token.expires_at <= now
        ):
            raise SessionRevoked
        user = await self.users.get(user_id)
        if user is None or user.status != "active" or user.email_verified_at is None:
            raise SessionRevoked

        if token.used_at is None:
            token.used_at = now
            rotated = await self._rotate(auth_session, token, now)
            await self.session.commit()
            return rotated

        successor = (
            await self.refresh_tokens.lock_in_session(
                session_id=session_id, token_id=token.replaced_by
            )
            if token.replaced_by is not None
            else None
        )
        if (
            now - token.used_at <= REFRESH_RETRY_GRACE
            and successor is not None
            and successor.used_at is None
            and successor.expires_at > now
        ):
            # A network retry: the client never received the successor. Invalidate it and
            # issue a fresh one; the grace window stays anchored to the first use.
            successor.expires_at = now
            rotated = await self._rotate(auth_session, token, now)
            await self.session.commit()
            return rotated

        # Reuse outside the grace window: treat as theft and end the whole session.
        await self.sessions.revoke(
            owner_id=user_id, session_id=session_id, reason="reuse_detected", now=now
        )
        await self.services.audit.record(
            self.session,
            self._event(
                audit.REFRESH_REUSE_DETECTED,
                now,
                user_id,
                resource_type="session",
                resource_id=session_id,
            ),
        )
        await self._commit_and_send(
            [self.services.mailer.render(EmailTemplate.REFRESH_REUSE_DETECTED, to=user.email)]
        )
        raise SessionRevoked

    async def _rotate(
        self, auth_session: AuthSession, token: RefreshToken, now: datetime
    ) -> RotatedTokens:
        idle = min(
            now + timedelta(days=self.settings.session_idle_days),
            auth_session.absolute_expires_at,
        )
        auth_session.idle_expires_at = idle
        auth_session.last_used_at = now
        refresh = new_refresh_token()
        successor = await self.refresh_tokens.create(
            session_id=auth_session.id,
            token_hash=hash_refresh_token(refresh),
            expires_at=idle,
            now=now,
        )
        token.replaced_by = successor.id
        access = self.services.tokens.issue(
            user_id=auth_session.user_id, session_id=auth_session.id, now=now
        )
        return RotatedTokens(access=access, refresh_token=refresh)

    # ------------------------------------------------------------------ sessions

    async def logout(self, current: CurrentUser) -> None:
        now = await self._now()
        revoked, device_id = await self.sessions.revoke(
            owner_id=current.user_id, session_id=current.session_id, reason="logout", now=now
        )
        if device_id is not None:
            await self.devices.clear_push_token(
                owner_id=current.user_id, device_id=device_id, now=now
            )
        if revoked:
            await self.services.audit.record(
                self.session,
                self._event(
                    audit.LOGOUT,
                    now,
                    current.user_id,
                    resource_type="session",
                    resource_id=current.session_id,
                ),
            )
        await self.session.commit()

    async def logout_all(self, current: CurrentUser) -> None:
        now = await self._now()
        count = await self.sessions.revoke_all(
            owner_id=current.user_id, reason="logout_all", now=now
        )
        await self.devices.clear_all_push_tokens(owner_id=current.user_id, now=now)
        await self.services.audit.record(
            self.session,
            self._event(audit.LOGOUT_ALL, now, current.user_id, sessions_revoked=count),
        )
        user = await self.users.get(current.user_id)
        await self._commit_and_send(
            [
                self.services.mailer.render(
                    EmailTemplate.SESSIONS_REVOKED, to=user.email, sessions_revoked=count
                )
            ]
            if user is not None
            else []
        )

    async def reauth(self, current: CurrentUser, body: ReauthRequest) -> None:
        now = await self._now()
        await self._limit(REAUTH_PER_SESSION, str(current.session_id), now)
        user = await self.users.get(current.user_id)
        if user is None or not await self.services.passwords.verify(
            user.password_hash, body.password
        ):
            await self.services.audit.record_independent(
                self._event(
                    audit.REAUTH_FAILED,
                    now,
                    current.user_id,
                    resource_type="session",
                    resource_id=current.session_id,
                    reason="bad_password",
                )
            )
            raise InvalidCredentials
        await self.sessions.set_reauthenticated(
            owner_id=current.user_id, session_id=current.session_id, now=now
        )
        await self.services.audit.record(
            self.session,
            self._event(
                audit.REAUTH_SUCCEEDED,
                now,
                current.user_id,
                resource_type="session",
                resource_id=current.session_id,
            ),
        )
        await self.session.commit()

    async def list_sessions(self, current: CurrentUser) -> SessionList:
        now = await self._now()
        rows = await self.sessions.list_active(owner_id=current.user_id, now=now)
        await self.session.commit()
        return SessionList(
            items=[
                SessionItem(
                    id=s.id,
                    kind=s.kind,
                    device=(
                        SessionDevice(platform=d.platform, app_version=d.app_version)
                        if d is not None
                        else None
                    ),
                    created_at=s.created_at,
                    last_used_at=s.last_used_at,
                    current=s.id == current.session_id,
                )
                for s, d in rows
            ]
        )

    async def revoke_session(self, current: CurrentUser, session_id: uuid.UUID) -> None:
        now = await self._now()
        revoked, device_id = await self.sessions.revoke(
            owner_id=current.user_id, session_id=session_id, reason="logout", now=now
        )
        if not revoked:
            raise NotFound
        if device_id is not None:
            await self.devices.clear_push_token(
                owner_id=current.user_id, device_id=device_id, now=now
            )
        await self.services.audit.record(
            self.session,
            self._event(
                audit.SESSION_REVOKED,
                now,
                current.user_id,
                resource_type="session",
                resource_id=session_id,
                reason="user_request",
            ),
        )
        await self.session.commit()
