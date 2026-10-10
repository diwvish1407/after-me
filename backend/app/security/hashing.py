"""Hashing helpers (SECURITY §6.3).

* Random, high-entropy secrets (refresh tokens, link tokens): plain SHA-256.
* Low-entropy values (6-digit codes, IP addresses, rate-limit subjects): HMAC-SHA256 with the
  server pepper, so a database dump alone cannot brute-force them.

Every HMAC input starts with a context label, so a value hashed for one purpose can never be
replayed for another. During pepper rotation, verification also accepts the previous pepper.
"""

from __future__ import annotations

import hashlib
import hmac

_SEPARATOR = "\x1f"  # ASCII unit separator: cannot appear in UUIDs, codes or IP addresses


def sha256(value: str | bytes) -> bytes:
    data = value.encode() if isinstance(value, str) else value
    return hashlib.sha256(data).digest()


class Pepper:
    def __init__(self, current: str, previous: str | None = None) -> None:
        self._current = current.encode()
        self._previous = previous.encode() if previous else None

    def _mac(self, key: bytes, context: str, parts: tuple[str, ...]) -> bytes:
        message = _SEPARATOR.join((context, *parts)).encode()
        return hmac.new(key, message, hashlib.sha256).digest()

    def hmac(self, context: str, *parts: str) -> bytes:
        """HMAC with the current pepper."""
        return self._mac(self._current, context, parts)

    def candidates(self, context: str, *parts: str) -> list[bytes]:
        """The HMAC under the current pepper and, during rotation, the previous one: for lookups
        of stored hashes that may have been written before the pepper changed."""
        keys = [self._current] if self._previous is None else [self._current, self._previous]
        return [self._mac(key, context, parts) for key in keys]

    def verify(self, expected: bytes, context: str, *parts: str) -> bool:
        """Constant-time check against the current and (during rotation) the previous pepper."""
        keys = [self._current] if self._previous is None else [self._current, self._previous]
        matched = False
        for key in keys:  # always compute every candidate; no early exit
            matched |= hmac.compare_digest(expected, self._mac(key, context, parts))
        return matched

    def ip_hash(self, ip: str) -> bytes:
        return self.hmac("ip", ip)

    def subject_key(self, context: str, subject: str) -> str:
        """A pseudonymous, stable key for counters (hex, 40 chars)."""
        return self.hmac(context, subject).hex()[:40]
