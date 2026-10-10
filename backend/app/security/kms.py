"""Key wrapping (SECURITY §6.2): the interface to a KMS and the development provider.

The key-encryption key (KEK) never leaves the KMS in production; the application only asks it to
wrap and unwrap a per-user data-encryption key (DEK), passing the user's ID as additional
authenticated data so a wrapped DEK cannot be moved to another account.

``LocalKms`` keeps the KEK in the process environment. It exists for development and tests and
is **refused in staging and production** (``Settings``); a cloud KMS provider implements the
same two methods and is a deployment item (ROADMAP Phase 10-12).
"""

from __future__ import annotations

import hashlib
import uuid
from typing import Protocol

from app.security import envelope


class KmsError(Exception):
    """The KMS could not wrap or unwrap a key."""


class KmsProvider(Protocol):
    @property
    def active_key_id(self) -> str:
        """Identifies the KEK (version) new DEKs are wrapped with; stored beside them."""
        ...

    async def wrap(self, dek: bytes, *, user_id: uuid.UUID) -> tuple[bytes, str]:
        """Returns ``(wrapped DEK, key id)``."""
        ...

    async def unwrap(self, wrapped: bytes, *, user_id: uuid.UUID, key_id: str) -> bytes: ...


def local_key_id(key: bytes) -> str:
    """A self-describing, non-reversible name for a development KEK."""
    return "local-" + hashlib.sha256(b"afterme/kek-id|" + key).hexdigest()[:12]


class LocalKms:
    def __init__(self, active: bytes, previous: bytes | None = None) -> None:
        for key in (active, previous):
            if key is not None and len(key) != envelope.KEY_BYTES:
                msg = "a local KEK must be 32 bytes"
                raise ValueError(msg)
        self._active_id = local_key_id(active)
        self._keys = {self._active_id: active}
        if previous is not None:
            self._keys[local_key_id(previous)] = previous

    @property
    def active_key_id(self) -> str:
        return self._active_id

    async def wrap(self, dek: bytes, *, user_id: uuid.UUID) -> tuple[bytes, str]:
        key_id = self._active_id
        aad = envelope.dek_aad(user_id, key_id)
        return envelope.encrypt(self._keys[key_id], dek, aad=aad), key_id

    async def unwrap(self, wrapped: bytes, *, user_id: uuid.UUID, key_id: str) -> bytes:
        key = self._keys.get(key_id)
        if key is None:
            raise KmsError
        try:
            return envelope.decrypt(key, wrapped, aad=envelope.dek_aad(user_id, key_id))
        except envelope.DecryptionError:
            raise KmsError from None
