"""Key wrapping (SECURITY §6.2): the interface to a KMS and the development provider.

The key-encryption key (KEK) never leaves the KMS in production; the application only asks it to
wrap and unwrap a per-user data-encryption key (DEK), passing the user's ID as additional
authenticated data so a wrapped DEK cannot be moved to another account.

``LocalKms`` keeps the KEK in the process environment. It exists for development and tests and
is **refused in staging and production** (``Settings``). ``GcpKms`` (``gcp_kms.py``) is the
production provider; ``UnavailableKms`` is what a process that must never decrypt content (the
escalation worker, BD-5) is given instead of either.
"""

from __future__ import annotations

import hashlib
import uuid
from dataclasses import dataclass
from typing import Protocol

from app.core.logging import get_logger
from app.security import envelope

_log = get_logger("afterme.kms")


class KmsError(Exception):
    """The KMS could not wrap or unwrap a key. ``code`` is a short, fixed, non-secret word
    (``timeout``, ``permission_denied``, ...): never a key name, a response body or key material,
    so it is safe to log and to print."""

    def __init__(self, code: str = "kms_error") -> None:
        super().__init__(code)
        self.code = code
        self.logged = False


def log_failure(exc: KmsError, operation: str) -> KmsError:
    """The one ``kms.call_failed`` event of a failure: the operation (``encrypt``/``decrypt``)
    and the short code, nothing else (no key name, no bytes). Called by the Cloud KMS adapter for
    every error it raises and by the vault for every error it meets, so a failure from any
    provider is logged, and logged once (the monitoring alert counts these lines)."""
    if not exc.logged:
        exc.logged = True
        _log.warning("kms.call_failed", operation=operation, failure=exc.code)
    return exc


@dataclass(frozen=True)
class Unwrapped:
    dek: bytes
    # Whether the key was wrapped with the KEK (version) that new wraps use now. ``False`` means
    # "still decrypts, but the re-wrap job should rewrite it" (``cli.admin kms rewrap``).
    current: bool


class KmsProvider(Protocol):
    @property
    def active_key_id(self) -> str:
        """Identifies the KEK (version) new DEKs are wrapped with; stored beside them."""
        ...

    async def wrap(self, dek: bytes, *, user_id: uuid.UUID) -> tuple[bytes, str]:
        """Returns ``(wrapped DEK, key id)``."""
        ...

    async def unwrap(self, wrapped: bytes, *, user_id: uuid.UUID, key_id: str) -> bytes: ...

    async def unwrap_status(self, wrapped: bytes, *, user_id: uuid.UUID, key_id: str) -> Unwrapped:
        """``unwrap`` that also says whether the wrapping is up to date (for the re-wrap job)."""
        ...


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
        return (await self.unwrap_status(wrapped, user_id=user_id, key_id=key_id)).dek

    async def unwrap_status(self, wrapped: bytes, *, user_id: uuid.UUID, key_id: str) -> Unwrapped:
        key = self._keys.get(key_id)
        if key is None:
            raise KmsError("unknown_key")
        try:
            dek = envelope.decrypt(key, wrapped, aad=envelope.dek_aad(user_id, key_id))
        except envelope.DecryptionError:
            raise KmsError("invalid_ciphertext") from None
        return Unwrapped(dek, current=key_id == self._active_id)


class UnavailableKms:
    """For a process that must never read content (the escalation worker): every call fails
    closed with the same error a KMS outage gives, and nothing is ever sent anywhere."""

    @property
    def active_key_id(self) -> str:
        return "unavailable"

    async def wrap(self, dek: bytes, *, user_id: uuid.UUID) -> tuple[bytes, str]:
        raise KmsError("not_configured")

    async def unwrap(self, wrapped: bytes, *, user_id: uuid.UUID, key_id: str) -> bytes:
        raise KmsError("not_configured")

    async def unwrap_status(self, wrapped: bytes, *, user_id: uuid.UUID, key_id: str) -> Unwrapped:
        raise KmsError("not_configured")
