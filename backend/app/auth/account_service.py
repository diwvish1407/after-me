"""Password and email lifecycle (API_SPEC §2.4; SECURITY §7; PRD FR-AUTH-04 to FR-AUTH-09).

Same transaction discipline as :class:`app.auth.service.AuthService`: bookkeeping that must
survive an error response (rate-limit counters, code attempts, failure audit records) commits in
independent transactions *before* the request transaction locks or writes the same rows, and
emails are sent only after the request transaction has committed.

Enumeration safety (T18): ``forgot_password`` and ``email_change_start`` answer identically for
every input. Both do the same work in every branch (token generation and hashing, email
rendering, the same statements apart from the final insert) and return their emails to the
caller, which sends them *after* the response, so delivery time cannot tell the branches apart.
"""

from __future__ import annotations

import uuid
from typing import Final

from sqlalchemy.exc import IntegrityError

from app.api.deps import CurrentUser
from app.audit import writer as audit
from app.auth.base import AuthServiceBase
from app.auth.codes import (
    CODE_MAX_ATTEMPTS,
    CODE_TTL,
    code_matches,
    generate_code,
    hash_code,
)
from app.auth.links import (
    RESET_LINK_TTL,
    RESET_PURPOSE,
    hash_link_token,
    looks_like_reset_token,
    new_reset_token,
    reset_link,
)
from app.auth.models import User
from app.auth.repository import AuthTokenRepository
from app.auth.schemas import (
    EmailChangeStartRequest,
    EmailChangeVerifyRequest,
    ForgotPasswordRequest,
    PasswordChangeRequest,
)
from app.core.errors import InvalidCode, InvalidCredentials, SessionRevoked, ValidationFailed
from app.core.validation import normalize_email
from app.notifications.email import EmailMessage
from app.notifications.mailer import EmailTemplate, mask_email
from app.security.passwords import PasswordPolicyError, check_password_policy, normalize_password
from app.security.rate_limit import (
    EMAIL_CHANGE_PER_USER,
    FORGOT_PER_EMAIL,
    REAUTH_PER_SESSION,
)

EMAIL_CHANGE_PURPOSE: Final = "email_change"
_NO_USER: Final = uuid.UUID(int=0)


class ResetLinkInvalid(Exception):  # noqa: N818 - domain signal, rendered as a generic page
    """The reset token is malformed, unknown, used, expired, or its account is unusable."""


def _policy_error(exc: PasswordPolicyError) -> ValidationFailed:
    return ValidationFailed([{"field": "new_password", "code": exc.code, "message": exc.message}])


class AccountService(AuthServiceBase):
    # ------------------------------------------------------------------ forgot / reset

    async def forgot_password(self, body: ForgotPasswordRequest) -> list[EmailMessage]:
        """Always succeeds for the caller. Only a verified, active account gets a link."""
        now = await self._now()
        email_norm = body.email_normalized
        await self._limit(FORGOT_PER_EMAIL, email_norm, now)

        user = await self.users.get_by_email(email_norm, for_update=True)
        eligible = (
            user is not None and user.email_verified_at is not None and user.status == "active"
        )

        # The decoy and the real branch run the same steps; only the final insert differs.
        token = new_reset_token()
        secret_hash = hash_link_token(token)
        message = self.services.mailer.render(
            EmailTemplate.PASSWORD_RESET_LINK,
            to=body.email if user is None else user.email,
            link=reset_link(self.settings.public_base_url, token),
            expires_minutes=int(RESET_LINK_TTL.total_seconds() // 60),
        )
        owner_id = user.id if user is not None and eligible else _NO_USER
        await self.codes.invalidate_unused(owner_id=owner_id, purpose=RESET_PURPOSE, now=now)
        outbox: list[EmailMessage] = []
        expires_at = now + RESET_LINK_TTL
        if user is not None and eligible:
            await self.codes.create_link(
                owner_id=owner_id,
                purpose=RESET_PURPOSE,
                secret_hash=secret_hash,
                expires_at=expires_at,
                now=now,
            )
            outbox.append(message)
            outcome = "link_sent"
        else:
            await self.codes.decoy_insert(
                kind="link",
                owner_id=owner_id,
                purpose=RESET_PURPOSE,
                secret_hash=secret_hash,
                expires_at=expires_at,
                now=now,
            )
            outcome = "unknown_account" if user is None else "not_eligible"
        await self.services.audit.record(
            self.session,
            self._event(
                audit.PASSWORD_RESET_REQUESTED,
                now,
                user.id if user is not None else None,
                unauthenticated=True,
                outcome=outcome,
            ),
        )
        await self.session.commit()
        return outbox

    async def reset_password(self, *, token: str, new_password: str) -> None:
        """Consume a reset link and set the new password (the web form, ``POST /a/reset``).

        Raises :class:`ResetLinkInvalid` for any unusable link and
        :class:`PasswordPolicyError` for a rejected password; the link stays valid in the latter
        case so the person can choose another password.
        """
        now = await self._now()
        if not looks_like_reset_token(token):
            raise ResetLinkInvalid
        link = await self.codes.find_link(secret_hash=hash_link_token(token), purpose=RESET_PURPOSE)
        if link is None or link.used_at is not None or link.expires_at <= now:
            raise ResetLinkInvalid
        found = await self.users.get(link.user_id)
        if found is None or found.status != "active" or found.email_verified_at is None:
            raise ResetLinkInvalid

        check_password_policy(new_password, email=found.email)
        password_hash = await self.services.passwords.hash(new_password)

        user = await self.users.get(found.id, for_update=True)
        if (
            user is None
            or user.status != "active"
            or not await self.codes.mark_used(owner_id=user.id, token_id=link.id, now=now)
        ):
            raise ResetLinkInvalid
        user.password_hash = password_hash
        user.password_changed_at = now
        user.failed_login_count = 0
        user.locked_until = None
        user.updated_at = now
        # Whoever holds the mailbox may now own the account: end every session, drop every
        # outstanding link and pending email change, and stop pushes to signed-out devices.
        revoked = await self.sessions.revoke_all(owner_id=user.id, reason="password_reset", now=now)
        await self.devices.clear_all_push_tokens(owner_id=user.id, now=now)
        await self.codes.invalidate_unused(owner_id=user.id, purpose=RESET_PURPOSE, now=now)
        await self.codes.invalidate_unused(owner_id=user.id, purpose=EMAIL_CHANGE_PURPOSE, now=now)
        await self.services.audit.record(
            self.session,
            self._event(
                audit.PASSWORD_RESET_COMPLETED,
                now,
                user.id,
                user_visible=True,
                sessions_revoked=revoked,
            ),
        )
        await self._commit_and_send(
            [self.services.mailer.render(EmailTemplate.PASSWORD_RESET_COMPLETED, to=user.email)]
        )

    # ------------------------------------------------------------------ change password

    async def change_password(self, current: CurrentUser, body: PasswordChangeRequest) -> None:
        now = await self._now()
        user = await self.users.get(current.user_id)
        if user is None:  # pragma: no cover - the session check already loaded this user
            raise InvalidCredentials
        try:
            check_password_policy(body.new_password, email=user.email)
        except PasswordPolicyError as exc:
            raise _policy_error(exc) from None

        # Shares the budget of /auth/reauth: both are password-guessing oracles for a stolen
        # access token (5 per 15 minutes per session).
        await self._limit(REAUTH_PER_SESSION, str(current.session_id), now)
        verified_hash = user.password_hash
        if not await self.services.passwords.verify(verified_hash, body.current_password):
            await self.services.audit.record_independent(
                self._event(
                    audit.REAUTH_FAILED,
                    now,
                    current.user_id,
                    resource_type="session",
                    resource_id=current.session_id,
                    reason="change_password",
                )
            )
            raise InvalidCredentials
        if normalize_password(body.new_password) == normalize_password(body.current_password):
            raise ValidationFailed(
                [
                    {
                        "field": "new_password",
                        "code": "password_unchanged",
                        "message": "Choose a password different from your current one.",
                    }
                ]
            )

        password_hash = await self.services.passwords.hash(body.new_password)
        # The slow hashing above ran without a lock. Re-check under the lock that the password we
        # verified is still the current one and that this session has not been revoked meanwhile
        # (a concurrent change, reset or sign-out): otherwise we would overwrite their result.
        locked = await self.users.get(current.user_id, for_update=True)
        if locked is None or locked.password_hash != verified_hash:
            raise InvalidCredentials
        live = await self.sessions.get(
            owner_id=current.user_id, session_id=current.session_id, for_update=True
        )
        if live is None or live.revoked_at is not None:
            raise SessionRevoked
        locked.password_hash = password_hash
        locked.password_changed_at = now
        locked.updated_at = now
        revoked_devices = await self.sessions.revoke_all_except(
            owner_id=current.user_id,
            keep_session_id=current.session_id,
            reason="password_changed",
            now=now,
        )
        # Push tokens belong to devices: keep the one the current session runs on.
        await self.devices.clear_push_tokens(
            owner_id=current.user_id,
            device_ids=[d for d in revoked_devices if d is not None and d != current.device_id],
            now=now,
        )
        await self.codes.invalidate_unused(owner_id=current.user_id, purpose=RESET_PURPOSE, now=now)
        await self.services.audit.record(
            self.session,
            self._event(
                audit.PASSWORD_CHANGED,
                now,
                current.user_id,
                resource_type="session",
                resource_id=current.session_id,
                user_visible=True,
                sessions_revoked=len(revoked_devices),
            ),
        )
        await self._commit_and_send(
            [self.services.mailer.render(EmailTemplate.PASSWORD_CHANGED, to=locked.email)]
        )

    # ------------------------------------------------------------------ change email

    async def email_change_start(
        self, current: CurrentUser, body: EmailChangeStartRequest
    ) -> list[EmailMessage]:
        """Always the same outcome for the caller. A code goes to the new address and a notice to
        the old one; an address that already belongs to a verified account gets the
        ``account_exists`` notice instead; the current address does nothing."""
        now = await self._now()
        await self._limit(EMAIL_CHANGE_PER_USER, str(current.user_id), now)
        user = await self.users.get(current.user_id)
        if user is None:  # pragma: no cover - the session check already loaded this user
            raise InvalidCredentials
        new_norm = body.email_normalized

        # Decoy work shared by every branch (see the module docstring).
        code = generate_code()
        code_hash = hash_code(
            self.services.pepper, user_id=user.id, purpose=EMAIL_CHANGE_PURPOSE, code=code
        )
        code_message = self.services.mailer.render(
            EmailTemplate.EMAIL_CHANGE_CODE,
            to=body.new_email,
            code=code,
            expires_minutes=int(CODE_TTL.total_seconds() // 60),
        )

        outbox: list[EmailMessage] = []
        owner = await self.users.get_by_email(new_norm)
        expires_at = now + CODE_TTL
        # Every start supersedes the caller's earlier pending code, whatever the address is: if
        # that only happened for a free address, redeeming the old code would reveal it.
        await self.codes.invalidate_unused(owner_id=user.id, purpose=EMAIL_CHANGE_PURPOSE, now=now)
        if new_norm == user.email_normalized:
            outcome = "same_address"
        elif owner is not None and owner.email_verified_at is not None:
            outcome = "address_in_use"
            outbox.append(self.services.mailer.render(EmailTemplate.ACCOUNT_EXISTS, to=owner.email))
        else:
            outcome = "code_sent"
        if outcome == "code_sent":
            await self.codes.create_code(
                owner_id=user.id,
                purpose=EMAIL_CHANGE_PURPOSE,
                secret_hash=code_hash,
                expires_at=expires_at,
                now=now,
                payload={"email": body.new_email, "email_normalized": new_norm},
            )
            # Notice first, code last: in development the newest file in .dev_mail is the code.
            outbox.append(
                self.services.mailer.render(
                    EmailTemplate.EMAIL_CHANGE_REQUESTED,
                    to=user.email,
                    new_email_masked=mask_email(body.new_email),
                )
            )
            outbox.append(code_message)
        else:
            # Same statements as above, touching nothing (see the module docstring).
            await self.codes.decoy_insert(
                kind="code",
                owner_id=_NO_USER,
                purpose=EMAIL_CHANGE_PURPOSE,
                secret_hash=code_hash,
                expires_at=expires_at,
                now=now,
            )
        await self.services.audit.record(
            self.session,
            self._event(
                audit.EMAIL_CHANGE_REQUESTED,
                now,
                user.id,
                resource_type="user",
                resource_id=user.id,
                outcome=outcome,
            ),
        )
        await self.session.commit()
        return outbox

    async def email_change_verify(
        self, current: CurrentUser, body: EmailChangeVerifyRequest
    ) -> None:
        now = await self._now()
        user = await self.users.get(current.user_id)
        if user is None:  # pragma: no cover - the session check already loaded this user
            raise InvalidCode
        token = await self.codes.latest_unused(owner_id=user.id, purpose=EMAIL_CHANGE_PURPOSE)
        if token is None or token.expires_at <= now:
            raise InvalidCode

        # Count the attempt first, in its own committed transaction (as for signup codes).
        async with self.services.db.independent_session() as bookkeeping:
            attempts = await AuthTokenRepository(bookkeeping).consume_attempt(
                owner_id=user.id, token_id=token.id, max_attempts=CODE_MAX_ATTEMPTS, now=now
            )
        if attempts is None or not code_matches(
            self.services.pepper,
            token.secret_hash,
            user_id=user.id,
            purpose=EMAIL_CHANGE_PURPOSE,
            code=body.code,
        ):
            raise InvalidCode
        new_email, new_norm = self._payload_email(token.payload)

        locked = await self.users.get(user.id, for_update=True)
        if locked is None:  # pragma: no cover - the account cannot vanish mid-request
            raise InvalidCode
        old_email = locked.email
        await self._release_address(locked, new_norm)
        if not await self.codes.mark_used(owner_id=user.id, token_id=token.id, now=now):
            raise InvalidCode
        locked.email = new_email
        locked.email_normalized = new_norm
        locked.updated_at = now
        try:
            await self.session.flush()
        except IntegrityError:
            # Lost a race for the address (uniqueness is the final arbiter): same answer as a
            # wrong code, so nothing about the other account is revealed.
            await self.session.rollback()
            raise InvalidCode from None
        # Links emailed to the old address must not outlive the change.
        await self.codes.invalidate_unused(owner_id=user.id, purpose=RESET_PURPOSE, now=now)
        await self.services.audit.record(
            self.session,
            self._event(
                audit.EMAIL_CHANGED,
                now,
                user.id,
                resource_type="user",
                resource_id=user.id,
                user_visible=True,
            ),
        )
        await self._commit_and_send(
            [
                self.services.mailer.render(
                    EmailTemplate.EMAIL_CHANGED,
                    to=old_email,
                    new_email_masked=mask_email(new_email),
                )
            ]
        )

    @staticmethod
    def _payload_email(payload: dict[str, object] | None) -> tuple[str, str]:
        email = payload.get("email") if payload else None
        normalized = payload.get("email_normalized") if payload else None
        if not isinstance(email, str) or not isinstance(normalized, str):
            raise InvalidCode  # a code row without its payload can never be redeemed
        return email, normalize_email(normalized)

    async def _release_address(self, user: User, new_norm: str) -> None:
        """Make ``new_norm`` free for ``user``: another verified account holding it is a lost
        race (``InvalidCode``); an unverified signup is superseded, because the code just
        verified proves that *this* person controls the mailbox."""
        holder = await self.users.get_by_email(new_norm, for_update=True)
        if holder is None or holder.id == user.id:
            return
        if holder.email_verified_at is not None:
            raise InvalidCode
        await self.users.delete_unverified(owner_id=holder.id)
