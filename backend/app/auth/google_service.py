"""Sign in with Google (``POST /v1/auth/google``).

The Google ID token is verified first (app/auth/google.py). Then, in this order:

1. an account already linked to this Google account signs in;
2. an account with the same (Google-verified) address is linked and signs in. A *pending*
   signup for that address is completed, and its password is replaced by an unusable one: the
   person who typed it may not own the address (an account pre-hijack);
3. otherwise a new, verified account is created (with an unusable password; the person can set
   one later with "Forgot password").

Two-step verification applies exactly as for a password sign-in.
"""

from __future__ import annotations

import secrets
from datetime import datetime

from app.audit import writer as audit
from app.auth.google import GoogleIdentity, GoogleTokenError
from app.auth.models import User
from app.auth.repository import CheckinBootstrapRepository
from app.auth.schemas import GoogleLoginRequest
from app.auth.service import AuthService, IssuedSession
from app.core.errors import GoogleSignInUnavailable, GoogleTokenRejected, InvalidCredentials
from app.plans.repository import PlanRepository
from app.security.rate_limit import LOGIN_PER_ACCOUNT_NETWORK


class GoogleAuthService(AuthService):
    async def google_login(self, body: GoogleLoginRequest) -> IssuedSession:
        verifier = self.services.google
        if not verifier.enabled:
            raise GoogleSignInUnavailable
        try:
            identity = await verifier.verify(body.id_token)
        except GoogleTokenError as exc:
            raise GoogleTokenRejected from exc

        now = await self._now()
        email_norm = identity.email.strip().lower()
        budget = self._budget_subject(email_norm)
        self.ctx.note_rate_limit(
            await self.services.limiter.check(LOGIN_PER_ACCOUNT_NETWORK, budget, now=now)
        )
        user = await self._account_for(identity, email_norm, body, now)
        if user.status != "active":
            raise InvalidCredentials
        await self._second_factor(user, body.otp, now, budget)

        user.last_login_at = now
        user.failed_login_count = 0
        user.locked_until = None
        user.updated_at = now
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
                method="google",
            ),
        )
        await self.session.commit()
        return issued

    async def _unusable_password(self) -> str:
        return await self.services.passwords.hash(secrets.token_urlsafe(48))

    async def _verify_account(self, user: User, now: datetime) -> None:
        user.email_verified_at = now
        await CheckinBootstrapRepository(self.session).create_default(owner_id=user.id, now=now)
        await PlanRepository(self.session).ensure(owner_id=user.id, now=now)

    async def _account_for(
        self,
        identity: GoogleIdentity,
        email_norm: str,
        body: GoogleLoginRequest,
        now: datetime,
    ) -> User:
        linked = await self.users.get_by_google_sub(identity.sub, for_update=True)
        if linked is not None:
            return linked

        existing = await self.users.get_by_email(email_norm, for_update=True)
        if existing is not None:
            if existing.google_sub is not None and existing.google_sub != identity.sub:
                raise GoogleTokenRejected  # the address is linked to another Google account
            if existing.email_verified_at is None:
                existing.password_hash = await self._unusable_password()
                existing.password_changed_at = now
                await self._verify_account(existing, now)
            existing.google_sub = identity.sub
            existing.updated_at = now
            await self._linked(existing, now)
            return existing

        user_id = await self.users.insert_if_absent(
            email=identity.email,
            email_normalized=email_norm,
            password_hash=await self._unusable_password(),
            now=now,
        )
        user = await self.users.get_by_email(email_norm, for_update=True)
        if user_id is None or user is None:  # pragma: no cover - a concurrent signup won
            raise GoogleTokenRejected
        user.google_sub = identity.sub
        await self.profiles.upsert(
            owner_id=user.id,
            display_name=body.display_name or identity.name or identity.email.split("@")[0],
            timezone=body.timezone,
            locale=body.locale,
            country_code=None,
            now=now,
        )
        await self._verify_account(user, now)
        await self.services.audit.record(
            self.session,
            self._event(
                audit.SIGNUP_VERIFIED, now, user.id, resource_type="user", resource_id=user.id
            ),
        )
        await self._linked(user, now)
        return user

    async def _linked(self, user: User, now: datetime) -> None:
        await self.services.audit.record(
            self.session,
            self._event(
                audit.GOOGLE_LINKED, now, user.id, resource_type="user", resource_id=user.id
            ),
        )
