"""Sealing and opening instruction content with the user's wrapped key (SECURITY §6.2).

``seal`` and ``open`` run inside the caller's transaction and session. A DEK is created on a
user's first instruction (wrapped by the KMS, stored in ``user_keys``) and unwrapped DEKs are
cached in process memory for at most ``ttl`` seconds: never logged, never persisted.
"""

from __future__ import annotations

import json
import time
import uuid
from collections.abc import Callable
from contextlib import AbstractAsyncContextManager
from dataclasses import dataclass
from typing import Final

from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.security import envelope
from app.security.envelope import DecryptionError
from app.security.kms import KmsError, KmsProvider
from app.security.models import UserKey

CACHE_TTL_SECONDS: Final = 300
CACHE_MAX_ENTRIES: Final = 1_024


class VaultUnavailableError(Exception):
    """No usable key for this user (the wrapped key is missing or the KMS refused it)."""


@dataclass(frozen=True)
class _Cached:
    dek: bytes
    version: int
    expires: float


IndependentSession = Callable[[], AbstractAsyncContextManager[AsyncSession]]


class InstructionVault:
    """``independent_session`` opens a separate connection whose transaction commits on its own
    (``Database.independent_session``). The key row is created there: a key must be durable
    *before* anything is sealed with it, or a rollback of the request that created it would
    leave content encrypted under a key that no longer exists (and, if it were cached, a later
    request would seal more under it)."""

    def __init__(
        self,
        kms: KmsProvider,
        *,
        independent_session: IndependentSession | None = None,
        ttl_seconds: float = CACHE_TTL_SECONDS,
        max_entries: int = CACHE_MAX_ENTRIES,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self._kms = kms
        self._independent = independent_session
        self._ttl = ttl_seconds
        self._max = max_entries
        self._monotonic = monotonic
        self._cache: dict[uuid.UUID, _Cached] = {}

    # ------------------------------------------------------------------ keys

    def forget(self, user_id: uuid.UUID) -> None:
        self._cache.pop(user_id, None)

    async def _key(
        self, session: AsyncSession, user_id: uuid.UUID, *, create: bool
    ) -> tuple[bytes, int]:
        now = self._monotonic()
        cached = self._cache.get(user_id)
        if cached is not None and cached.expires > now:
            return cached.dek, cached.version
        row = await self._row(session, user_id)
        if row is None:
            if not create:
                raise VaultUnavailableError
            row = await self._create(session, user_id)
        try:
            dek = await self._kms.unwrap(row.wrapped_dek, user_id=user_id, key_id=row.kek_id)
        except KmsError:
            raise VaultUnavailableError from None
        if len(self._cache) >= self._max:
            self._cache.clear()  # simple and safe: a cache miss only costs one unwrap
        self._cache[user_id] = _Cached(dek, row.dek_version, now + self._ttl)
        return dek, row.dek_version

    async def _create(self, session: AsyncSession, user_id: uuid.UUID) -> UserKey:
        dek = envelope.new_key()
        wrapped, key_id = await self._kms.wrap(dek, user_id=user_id)
        statement = (
            insert(UserKey)
            .values(user_id=user_id, wrapped_dek=wrapped, kek_id=key_id)
            .on_conflict_do_nothing(index_elements=[UserKey.user_id])
        )
        if self._independent is None:  # tests that have no second connection
            await session.execute(statement)
            row = await self._row(session, user_id)
        else:
            async with self._independent() as other:
                await other.execute(statement)
                row = await self._row(other, user_id)  # ours, or the winner's if we raced
        if row is None:  # pragma: no cover - we just inserted or lost to an insert
            raise VaultUnavailableError
        # Detached from the short transaction: the caller only needs the values.
        return UserKey(
            user_id=row.user_id,
            wrapped_dek=row.wrapped_dek,
            kek_id=row.kek_id,
            dek_version=row.dek_version,
        )

    @staticmethod
    async def _row(session: AsyncSession, user_id: uuid.UUID) -> UserKey | None:
        stmt = select(UserKey).where(UserKey.user_id == user_id)
        return (await session.execute(stmt)).scalar_one_or_none()

    async def destroy(self, session: AsyncSession, *, user_id: uuid.UUID) -> bool:
        """Delete the user's wrapped key (account deletion). Whatever was sealed with it, in a
        backup or anywhere else, can no longer be opened by anyone. Returns whether a key row
        existed."""
        self.forget(user_id)
        result = await session.execute(
            delete(UserKey).where(UserKey.user_id == user_id).returning(UserKey.user_id)
        )
        return result.first() is not None

    # ------------------------------------------------------------------ content

    async def seal(
        self,
        session: AsyncSession,
        *,
        user_id: uuid.UUID,
        instruction_id: uuid.UUID,
        title: str,
        body: str,
    ) -> tuple[bytes, int]:
        """Returns ``(ciphertext, key_version)``."""
        dek, version = await self._key(session, user_id, create=True)
        plaintext = json.dumps(
            {"title": title, "body": body}, ensure_ascii=False, separators=(",", ":")
        ).encode()
        aad = envelope.instruction_aad(user_id, instruction_id, version)
        return envelope.encrypt(dek, plaintext, aad=aad), version

    async def open(
        self,
        session: AsyncSession,
        *,
        user_id: uuid.UUID,
        instruction_id: uuid.UUID,
        ciphertext: bytes,
        key_version: int,
    ) -> tuple[str, str]:
        """Returns ``(title, body)``. Raises :class:`DecryptionError` for a ciphertext that was
        changed or does not belong to this user, row and key version."""
        dek, version = await self._key(session, user_id, create=False)
        if key_version != version:
            raise DecryptionError
        aad = envelope.instruction_aad(user_id, instruction_id, key_version)
        try:
            content = json.loads(envelope.decrypt(dek, ciphertext, aad=aad))
            return str(content["title"]), str(content["body"])
        except (ValueError, KeyError, TypeError):
            raise DecryptionError from None
