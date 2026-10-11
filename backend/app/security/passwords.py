"""Password policy and Argon2id hashing (SECURITY §6.3, §7; PRD FR-AUTH-01).

Policy: 10-128 characters after NFKC normalisation, any Unicode, no composition rules; rejected
when equal to the email address or its local part, or when on the common-password blocklist.

Hashing runs in a worker thread so the event loop keeps serving other requests.
"""

from __future__ import annotations

import asyncio
import os
import secrets
import unicodedata
from functools import cache
from pathlib import Path
from typing import Final

from argon2 import PasswordHasher as _Argon2Hasher
from argon2 import Type
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

MIN_LENGTH: Final = 10
MAX_LENGTH: Final = 128
MAX_RAW_LENGTH: Final = 1024  # reject absurd input before normalising it

_BLOCKLIST_PATH: Final = Path(__file__).with_name("common_passwords.txt")


class PasswordPolicyError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(code)
        self.code = code
        self.message = message


def normalize_password(password: str) -> str:
    return unicodedata.normalize("NFKC", password)


@cache
def common_passwords() -> frozenset[str]:
    lines = _BLOCKLIST_PATH.read_text(encoding="utf-8").splitlines()
    return frozenset(line for line in lines if line and not line.startswith("#"))


def check_password_policy(password: str, *, email: str | None = None) -> str:
    """Validate ``password`` and return its NFKC-normalised form.

    Raises :class:`PasswordPolicyError` with a stable ``code`` for the API error list.
    """
    if len(password) > MAX_RAW_LENGTH:
        raise PasswordPolicyError("too_long", f"Use at most {MAX_LENGTH} characters.")
    normalized = normalize_password(password)
    if len(normalized) < MIN_LENGTH:
        raise PasswordPolicyError("too_short", f"Use at least {MIN_LENGTH} characters.")
    if len(normalized) > MAX_LENGTH:
        raise PasswordPolicyError("too_long", f"Use at most {MAX_LENGTH} characters.")
    folded = normalized.casefold()
    if email:
        email_folded = email.strip().casefold()
        local_part = email_folded.split("@", 1)[0]
        if folded in (email_folded, local_part):
            raise PasswordPolicyError(
                "password_matches_email", "Don't use your email address as your password."
            )
    blocklist = common_passwords()
    if folded in blocklist or normalized.lower() in blocklist:
        raise PasswordPolicyError(
            "password_too_common", "This password is too common. Choose a less predictable one."
        )
    return normalized


class PasswordHasher:
    """Argon2id hashing with parameters from configuration."""

    def __init__(
        self,
        *,
        time_cost: int,
        memory_cost_kib: int,
        parallelism: int,
        max_concurrent: int | None = None,
    ) -> None:
        # Every sign-in attempt, including for an address that does not exist, runs one Argon2
        # (64 MiB by default). Unbounded, a burst spread over many addresses is an out-of-memory
        # kill and so an outage during which nobody can check in (Phase 9, F11): at most this
        # many run at once, the rest wait their turn.
        self._gate = asyncio.Semaphore(max_concurrent or max(2, os.cpu_count() or 2))
        self._hasher = _Argon2Hasher(
            time_cost=time_cost,
            memory_cost=memory_cost_kib,
            parallelism=parallelism,
            hash_len=32,
            salt_len=16,
            type=Type.ID,
        )
        # Verified against unknown accounts so their timing matches real accounts.
        self._dummy_hash = self._hasher.hash(secrets.token_urlsafe(24))

    async def hash(self, password: str) -> str:
        normalized = normalize_password(password)
        async with self._gate:
            return await asyncio.to_thread(self._hasher.hash, normalized)

    def _verify_sync(self, password_hash: str, password: str) -> bool:
        try:
            return self._hasher.verify(password_hash, normalize_password(password))
        except (VerifyMismatchError, VerificationError, InvalidHashError):
            return False

    async def verify(self, password_hash: str, password: str) -> bool:
        async with self._gate:
            return await asyncio.to_thread(self._verify_sync, password_hash, password)

    async def dummy_verify(self, password: str) -> None:
        async with self._gate:
            await asyncio.to_thread(self._verify_sync, self._dummy_hash, password)

    def needs_rehash(self, password_hash: str) -> bool:
        try:
            return self._hasher.check_needs_rehash(password_hash)
        except InvalidHashError:
            return True
