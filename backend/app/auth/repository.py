"""SQL for the auth module.

Ownership rule (ARCHITECTURE §4.3): every method on user-owned rows takes a keyword-only
``owner_id`` and filters by it; there is no unscoped get-by-id for owned rows. Two deliberate
exceptions, both enforced by ``tests/security/test_repository_ownership.py``:

* :class:`UserRepository` works on the owner rows themselves (finding an account by email is how
  sign-in starts).
* :class:`RefreshTokenRepository` finds a token by the SHA-256 of the presented secret
  (possession of the token is the credential), or by a session ID the caller has already
  resolved through an owner-scoped query.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from sqlalchemy import case, delete, false, literal, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.models import AuthSession, AuthToken, Device, RefreshToken, User
from app.checkins.models import CheckinConfiguration


@dataclass(frozen=True)
class FailedLoginOutcome:
    failed_login_count: int
    locked_until: datetime | None
    locked_now: bool


class UserRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, user_id: uuid.UUID, *, for_update: bool = False) -> User | None:
        if for_update:
            return await self._session.get(
                User, user_id, with_for_update=True, populate_existing=True
            )
        return await self._session.get(User, user_id)

    async def get_by_email(self, email_normalized: str, *, for_update: bool = False) -> User | None:
        stmt = select(User).where(User.email_normalized == email_normalized)
        if for_update:
            stmt = stmt.with_for_update().execution_options(populate_existing=True)
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def delete_unverified(self, *, owner_id: uuid.UUID) -> None:
        """Remove a signup that never completed verification (its rows cascade)."""
        await self._session.execute(
            delete(User).where(User.id == owner_id, User.email_verified_at.is_(None))
        )

    async def insert_if_absent(
        self, *, email: str, email_normalized: str, password_hash: str, now: datetime
    ) -> uuid.UUID | None:
        """Create an unverified user; ``None`` when the email is already registered."""
        stmt = (
            insert(User)
            .values(
                email=email,
                email_normalized=email_normalized,
                password_hash=password_hash,
                password_changed_at=now,
                created_at=now,
                updated_at=now,
            )
            .on_conflict_do_nothing(index_elements=[User.email_normalized])
            .returning(User.id)
        )
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def record_failed_login(
        self, user_id: uuid.UUID, *, now: datetime, threshold: int, lock_until: datetime
    ) -> FailedLoginOutcome:
        """Count one failure atomically. The failure that reaches ``threshold`` locks the account
        and restarts the count, so after the lock expires the next window starts fresh."""
        reaches_threshold = User.failed_login_count + 1 >= threshold
        stmt = (
            update(User)
            .where(User.id == user_id)
            .values(
                failed_login_count=case((reaches_threshold, 0), else_=User.failed_login_count + 1),
                locked_until=case((reaches_threshold, lock_until), else_=User.locked_until),
                updated_at=now,
            )
            .returning(User.failed_login_count, User.locked_until)
        )
        count, locked_until = (await self._session.execute(stmt)).one()
        # Only the locking branch can produce a count of 0 from an increment.
        return FailedLoginOutcome(
            failed_login_count=count, locked_until=locked_until, locked_now=count == 0
        )


class DeviceRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, *, owner_id: uuid.UUID, device_id: uuid.UUID) -> Device | None:
        stmt = select(Device).where(
            Device.id == device_id, Device.user_id == owner_id, Device.revoked_at.is_(None)
        )
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def create(
        self,
        *,
        owner_id: uuid.UUID,
        platform: str,
        app_version: str,
        os_version: str,
        locale: str,
        now: datetime,
    ) -> Device:
        device = Device(
            user_id=owner_id,
            platform=platform,
            app_version=app_version,
            os_version=os_version,
            locale=locale,
            created_at=now,
            last_seen_at=now,
        )
        self._session.add(device)
        await self._session.flush()
        return device

    async def update_info(
        self,
        *,
        owner_id: uuid.UUID,
        device_id: uuid.UUID,
        app_version: str,
        os_version: str,
        locale: str,
        now: datetime,
    ) -> None:
        await self._session.execute(
            update(Device)
            .where(Device.id == device_id, Device.user_id == owner_id)
            .values(app_version=app_version, os_version=os_version, locale=locale, last_seen_at=now)
        )

    async def set_push_token(
        self, *, owner_id: uuid.UUID, device_id: uuid.UUID, token: str, now: datetime
    ) -> None:
        await self._session.execute(
            update(Device)
            .where(Device.id == device_id, Device.user_id == owner_id, Device.revoked_at.is_(None))
            .values(push_token=token, push_token_updated_at=now)
        )

    async def detach_token_elsewhere(self, *, token: str, keep: uuid.UUID, now: datetime) -> None:
        """A registration token has one holder. The device that presents it now takes it from
        whoever had it (any account): the token is the credential, and a phone that changed
        hands must stop receiving the previous owner's pushes."""
        await self._session.execute(
            update(Device)
            .where(Device.push_token == token, Device.id != keep)
            .values(push_token=None, push_token_updated_at=now)
        )

    async def clear_push_token(
        self, *, owner_id: uuid.UUID, device_id: uuid.UUID, now: datetime
    ) -> None:
        await self._session.execute(
            update(Device)
            .where(
                Device.id == device_id, Device.user_id == owner_id, Device.push_token.is_not(None)
            )
            .values(push_token=None, push_token_updated_at=now)
        )

    async def clear_push_tokens(
        self, *, owner_id: uuid.UUID, device_ids: Sequence[uuid.UUID], now: datetime
    ) -> None:
        if not device_ids:
            return
        await self._session.execute(
            update(Device)
            .where(
                Device.user_id == owner_id,
                Device.id.in_(device_ids),
                Device.push_token.is_not(None),
            )
            .values(push_token=None, push_token_updated_at=now)
        )

    async def clear_all_push_tokens(self, *, owner_id: uuid.UUID, now: datetime) -> None:
        await self._session.execute(
            update(Device)
            .where(Device.user_id == owner_id, Device.push_token.is_not(None))
            .values(push_token=None, push_token_updated_at=now)
        )


class SessionRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(
        self, *, owner_id: uuid.UUID, session_id: uuid.UUID, for_update: bool = False
    ) -> AuthSession | None:
        stmt = select(AuthSession).where(
            AuthSession.id == session_id, AuthSession.user_id == owner_id
        )
        if for_update:
            stmt = stmt.with_for_update().execution_options(populate_existing=True)
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def get_with_user(
        self, *, owner_id: uuid.UUID, session_id: uuid.UUID
    ) -> tuple[AuthSession, User] | None:
        stmt = (
            select(AuthSession, User)
            .join(User, User.id == AuthSession.user_id)
            .where(AuthSession.id == session_id, AuthSession.user_id == owner_id)
        )
        row = (await self._session.execute(stmt)).one_or_none()
        return None if row is None else (row[0], row[1])

    async def get_by_web_token(self, token_hash: bytes) -> tuple[AuthSession, User] | None:
        """The ``web`` session whose cookie hashes to ``token_hash`` (the secret is the
        credential), with its user."""
        stmt = (
            select(AuthSession, User)
            .join(User, User.id == AuthSession.user_id)
            .where(AuthSession.web_token_hash == token_hash, AuthSession.kind == "web")
        )
        row = (await self._session.execute(stmt)).one_or_none()
        return None if row is None else (row[0], row[1])

    async def create(
        self,
        *,
        owner_id: uuid.UUID,
        device_id: uuid.UUID | None,
        ip_hash: bytes | None,
        user_agent: str | None,
        now: datetime,
        idle_expires_at: datetime,
        absolute_expires_at: datetime,
        kind: str = "app",
        web_token_hash: bytes | None = None,
        reauthenticated_at: datetime | None = None,
    ) -> AuthSession:
        auth_session = AuthSession(
            user_id=owner_id,
            kind=kind,
            web_token_hash=web_token_hash,
            reauthenticated_at=reauthenticated_at,
            device_id=device_id,
            auth_method="password",
            created_at=now,
            last_used_at=now,
            idle_expires_at=idle_expires_at,
            absolute_expires_at=absolute_expires_at,
            ip_hash=ip_hash,
            user_agent=user_agent,
        )
        self._session.add(auth_session)
        await self._session.flush()
        return auth_session

    async def list_active(
        self, *, owner_id: uuid.UUID, now: datetime
    ) -> list[tuple[AuthSession, Device | None]]:
        stmt = (
            select(AuthSession, Device)
            .outerjoin(Device, (Device.id == AuthSession.device_id) & (Device.user_id == owner_id))
            .where(
                AuthSession.user_id == owner_id,
                AuthSession.revoked_at.is_(None),
                AuthSession.idle_expires_at > now,
                AuthSession.absolute_expires_at > now,
            )
            .order_by(AuthSession.last_used_at.desc(), AuthSession.id)
        )
        return [(row[0], row[1]) for row in (await self._session.execute(stmt)).all()]

    async def revoke(
        self, *, owner_id: uuid.UUID, session_id: uuid.UUID, reason: str, now: datetime
    ) -> tuple[bool, uuid.UUID | None]:
        """Revoke one active session. Returns ``(revoked, device_id)``."""
        stmt = (
            update(AuthSession)
            .where(
                AuthSession.id == session_id,
                AuthSession.user_id == owner_id,
                AuthSession.revoked_at.is_(None),
            )
            .values(revoked_at=now, revoke_reason=reason)
            .returning(AuthSession.device_id)
        )
        row = (await self._session.execute(stmt)).one_or_none()
        return (False, None) if row is None else (True, row[0])

    async def revoke_all(self, *, owner_id: uuid.UUID, reason: str, now: datetime) -> int:
        stmt = (
            update(AuthSession)
            .where(AuthSession.user_id == owner_id, AuthSession.revoked_at.is_(None))
            .values(revoked_at=now, revoke_reason=reason)
            .returning(AuthSession.id)
        )
        return len((await self._session.execute(stmt)).all())

    async def revoke_all_except(
        self, *, owner_id: uuid.UUID, keep_session_id: uuid.UUID, reason: str, now: datetime
    ) -> list[uuid.UUID | None]:
        """Revoke every other active session; returns the device ID of each revoked session."""
        stmt = (
            update(AuthSession)
            .where(
                AuthSession.user_id == owner_id,
                AuthSession.id != keep_session_id,
                AuthSession.revoked_at.is_(None),
            )
            .values(revoked_at=now, revoke_reason=reason)
            .returning(AuthSession.device_id)
        )
        return [row[0] for row in (await self._session.execute(stmt)).all()]

    async def touch(self, *, owner_id: uuid.UUID, session_id: uuid.UUID, now: datetime) -> None:
        await self._session.execute(
            update(AuthSession)
            .where(AuthSession.id == session_id, AuthSession.user_id == owner_id)
            .values(last_used_at=now)
        )

    async def clear_reauthenticated(self, *, owner_id: uuid.UUID, session_id: uuid.UUID) -> None:
        """The confirmation was spent (an export): the next sensitive action asks again."""
        await self._session.execute(
            update(AuthSession)
            .where(AuthSession.id == session_id, AuthSession.user_id == owner_id)
            .values(reauthenticated_at=None)
        )

    async def set_reauthenticated(
        self, *, owner_id: uuid.UUID, session_id: uuid.UUID, now: datetime
    ) -> None:
        await self._session.execute(
            update(AuthSession)
            .where(AuthSession.id == session_id, AuthSession.user_id == owner_id)
            .values(reauthenticated_at=now, last_used_at=now)
        )


class RefreshTokenRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def find_owner(self, token_hash: bytes) -> tuple[uuid.UUID, uuid.UUID] | None:
        """``(session_id, user_id)`` for a presented token, without locking anything."""
        stmt = (
            select(RefreshToken.session_id, AuthSession.user_id)
            .join(AuthSession, AuthSession.id == RefreshToken.session_id)
            .where(RefreshToken.token_hash == token_hash)
        )
        row = (await self._session.execute(stmt)).one_or_none()
        return None if row is None else (row[0], row[1])

    async def lock_by_hash(
        self, *, session_id: uuid.UUID, token_hash: bytes
    ) -> RefreshToken | None:
        stmt = (
            select(RefreshToken)
            .where(RefreshToken.token_hash == token_hash, RefreshToken.session_id == session_id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def lock_in_session(
        self, *, session_id: uuid.UUID, token_id: uuid.UUID
    ) -> RefreshToken | None:
        stmt = (
            select(RefreshToken)
            .where(RefreshToken.id == token_id, RefreshToken.session_id == session_id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def create(
        self, *, session_id: uuid.UUID, token_hash: bytes, expires_at: datetime, now: datetime
    ) -> RefreshToken:
        token = RefreshToken(
            session_id=session_id, token_hash=token_hash, issued_at=now, expires_at=expires_at
        )
        self._session.add(token)
        await self._session.flush()
        return token


class AuthTokenRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def latest_unused(self, *, owner_id: uuid.UUID, purpose: str) -> AuthToken | None:
        stmt = (
            select(AuthToken)
            .where(
                AuthToken.user_id == owner_id,
                AuthToken.purpose == purpose,
                AuthToken.kind == "code",
                AuthToken.used_at.is_(None),
            )
            .order_by(AuthToken.created_at.desc(), AuthToken.id.desc())
            .limit(1)
        )
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def clear_payloads(self, *, owner_id: uuid.UUID) -> None:
        """Drop what a pending token carried (the new address of an email change): account
        deletion keeps no personal data that nothing needs."""
        await self._session.execute(
            update(AuthToken).where(AuthToken.user_id == owner_id).values(payload=None)
        )

    async def invalidate_unused(self, *, owner_id: uuid.UUID, purpose: str, now: datetime) -> None:
        """Supersede every unused code: only the newest code can ever be accepted."""
        await self._session.execute(
            update(AuthToken)
            .where(
                AuthToken.user_id == owner_id,
                AuthToken.purpose == purpose,
                AuthToken.used_at.is_(None),
            )
            .values(used_at=now)
        )

    async def create_code(
        self,
        *,
        owner_id: uuid.UUID,
        purpose: str,
        secret_hash: bytes,
        expires_at: datetime,
        now: datetime,
        payload: dict[str, Any] | None = None,
    ) -> AuthToken:
        return await self._create(
            owner_id=owner_id,
            purpose=purpose,
            kind="code",
            secret_hash=secret_hash,
            expires_at=expires_at,
            now=now,
            payload=payload,
        )

    async def create_link(
        self,
        *,
        owner_id: uuid.UUID,
        purpose: str,
        secret_hash: bytes,
        expires_at: datetime,
        now: datetime,
    ) -> AuthToken:
        return await self._create(
            owner_id=owner_id,
            purpose=purpose,
            kind="link",
            secret_hash=secret_hash,
            expires_at=expires_at,
            now=now,
            payload=None,
        )

    async def _create(
        self,
        *,
        owner_id: uuid.UUID,
        purpose: str,
        kind: str,
        secret_hash: bytes,
        expires_at: datetime,
        now: datetime,
        payload: dict[str, Any] | None,
    ) -> AuthToken:
        token = AuthToken(
            user_id=owner_id,
            purpose=purpose,
            kind=kind,
            secret_hash=secret_hash,
            payload=payload,
            expires_at=expires_at,
            created_at=now,
        )
        self._session.add(token)
        await self._session.flush()
        return token

    async def decoy_insert(
        self,
        *,
        kind: str,
        owner_id: uuid.UUID,
        purpose: str,
        secret_hash: bytes,
        expires_at: datetime,
        now: datetime,
    ) -> None:
        """Run the INSERT that :meth:`create_link` / :meth:`create_code` run, with ``WHERE false``
        so no row is written. Used where an unknown or ineligible input must cost the same
        database work as an eligible one (enumeration safety)."""
        columns = (
            AuthToken.user_id,
            AuthToken.purpose,
            AuthToken.kind,
            AuthToken.secret_hash,
            AuthToken.expires_at,
            AuthToken.created_at,
        )
        values = (owner_id, purpose, kind, secret_hash, expires_at, now)
        source = select(
            *(
                literal(value, type_=column.type)
                for value, column in zip(values, columns, strict=True)
            )
        ).where(false())
        await self._session.execute(insert(AuthToken).from_select([c.key for c in columns], source))

    async def find_link(self, *, secret_hash: bytes, purpose: str) -> AuthToken | None:
        """The link token with this SHA-256, whoever owns it: possession of the secret is the
        credential. Callers must check ``used_at`` and ``expires_at``."""
        stmt = select(AuthToken).where(
            AuthToken.secret_hash == secret_hash,
            AuthToken.kind == "link",
            AuthToken.purpose == purpose,
        )
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def consume_attempt(
        self, *, owner_id: uuid.UUID, token_id: uuid.UUID, max_attempts: int, now: datetime
    ) -> int | None:
        """Count an attempt before comparing, atomically: concurrent guesses can never exceed
        ``max_attempts``. ``None`` means the code is used, expired or exhausted."""
        stmt = (
            update(AuthToken)
            .where(
                AuthToken.id == token_id,
                AuthToken.user_id == owner_id,
                AuthToken.used_at.is_(None),
                AuthToken.expires_at > now,
                AuthToken.attempts < max_attempts,
            )
            .values(attempts=AuthToken.attempts + 1)
            .returning(AuthToken.attempts)
        )
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def mark_used(self, *, owner_id: uuid.UUID, token_id: uuid.UUID, now: datetime) -> bool:
        stmt = (
            update(AuthToken)
            .where(
                AuthToken.id == token_id,
                AuthToken.user_id == owner_id,
                AuthToken.used_at.is_(None),
            )
            .values(used_at=now)
            .returning(AuthToken.id)
        )
        return (await self._session.execute(stmt)).scalar_one_or_none() is not None


class CheckinBootstrapRepository:
    """Creates the user's (inactive) check-in configuration at signup verification."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def create_default(self, *, owner_id: uuid.UUID, now: datetime) -> None:
        await self._session.execute(
            insert(CheckinConfiguration)
            .values(user_id=owner_id, status="inactive", created_at=now, updated_at=now)
            .on_conflict_do_nothing(index_elements=[CheckinConfiguration.user_id])
        )
