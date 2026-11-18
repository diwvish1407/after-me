"""Two-factor authentication with an authenticator app (``/v1/me/2fa``).

Setup is two steps: ``setup`` creates a secret (wrapped by the KMS) and returns it for the
authenticator app; ``enable`` confirms a first code and returns eight one-use recovery codes,
shown once. Setting up, re-keying and turning it off need a fresh re-authentication. Sign-in then
needs a current code (or a recovery code) after the password (``AuthService.login``).
"""

from __future__ import annotations

from datetime import datetime

from app.api.deps import CurrentUser, has_fresh_reauth
from app.audit import writer as audit
from app.auth.base import AuthServiceBase
from app.auth.models import User
from app.auth.schemas import MfaEnabledOut, MfaSetupOut, MfaStatusOut
from app.auth.totp import (
    RECOVERY_CONTEXT,
    b32,
    looks_like_recovery_code,
    matching_step,
    new_recovery_codes,
    new_secret,
    normal_recovery,
    otpauth_uri,
)
from app.core.errors import InvalidOtp, InvalidState, NotFound, ReauthRequired


class MfaService(AuthServiceBase):
    async def _user(self, current: CurrentUser) -> User:
        user = await self.users.get(current.user_id, for_update=True)
        if user is None:  # pragma: no cover - the session proved it exists
            raise NotFound
        return user

    async def status(self, current: CurrentUser) -> MfaStatusOut:
        user = await self.users.get(current.user_id)
        await self.session.commit()
        if user is None:  # pragma: no cover
            raise NotFound
        return MfaStatusOut(
            enabled=user.totp_enabled_at is not None,
            recovery_codes_left=len(user.totp_recovery or []),
        )

    async def setup(self, current: CurrentUser) -> MfaSetupOut:
        now = await self._now()
        if not has_fresh_reauth(current, now):
            raise ReauthRequired
        user = await self._user(current)
        if user.totp_enabled_at is not None:
            raise InvalidState("Two-step verification is already on. Turn it off first.")
        secret = new_secret()
        wrapped, key_id = await self.services.vault.kms.wrap(secret, user_id=user.id)
        user.totp_secret_wrapped = wrapped
        user.totp_key_id = key_id
        user.totp_last_step = None
        user.totp_recovery = None
        user.updated_at = now
        await self.session.commit()
        return MfaSetupOut(secret=b32(secret), otpauth_uri=otpauth_uri(secret, user.email))

    async def _secret(self, user: User) -> bytes:
        if user.totp_secret_wrapped is None or user.totp_key_id is None:
            raise InvalidState("Start the setup first.")
        return await self.services.vault.kms.unwrap(
            bytes(user.totp_secret_wrapped), user_id=user.id, key_id=user.totp_key_id
        )

    async def enable(self, current: CurrentUser, code: str) -> MfaEnabledOut:
        now = await self._now()
        user = await self._user(current)
        if user.totp_enabled_at is not None:
            raise InvalidState("Two-step verification is already on.")
        step = matching_step(await self._secret(user), code, now)
        if step is None:
            raise InvalidOtp
        codes = new_recovery_codes()
        user.totp_enabled_at = now
        user.totp_last_step = step
        user.totp_recovery = [self._digest(user, c) for c in codes]
        user.updated_at = now
        await self.services.audit.record(
            self.session,
            self._event(audit.MFA_ENABLED, now, user.id, resource_type="user", resource_id=user.id),
        )
        await self.session.commit()
        return MfaEnabledOut(recovery_codes=codes)

    async def disable(self, current: CurrentUser, code: str) -> None:
        now = await self._now()
        if not has_fresh_reauth(current, now):
            raise ReauthRequired
        user = await self._user(current)
        if user.totp_enabled_at is None:
            await self.session.commit()
            return
        if not await self.check(user, code, now):
            raise InvalidOtp
        user.totp_secret_wrapped = None
        user.totp_key_id = None
        user.totp_enabled_at = None
        user.totp_last_step = None
        user.totp_recovery = None
        user.updated_at = now
        await self.services.audit.record(
            self.session,
            self._event(
                audit.MFA_DISABLED, now, user.id, resource_type="user", resource_id=user.id
            ),
        )
        await self.session.commit()

    def _digest(self, user: User, code: str) -> str:
        return self.services.pepper.hmac(
            RECOVERY_CONTEXT, str(user.id), normal_recovery(code)
        ).hex()

    async def check(self, user: User, code: str, now: datetime) -> bool:
        """Accept a current TOTP code (never the same step twice) or an unused recovery code
        (which is then spent). The caller holds the user row lock and commits."""
        if user.totp_enabled_at is None:
            return True
        if looks_like_recovery_code(code):
            stored = list(user.totp_recovery or [])
            normal = normal_recovery(code)
            for digest in stored:
                if self.services.pepper.verify(
                    bytes.fromhex(digest), RECOVERY_CONTEXT, str(user.id), normal
                ):
                    stored.remove(digest)
                    user.totp_recovery = stored
                    return True
            return False
        step = matching_step(await self._secret(user), code, now, after_step=user.totp_last_step)
        if step is None:
            return False
        user.totp_last_step = step
        return True
