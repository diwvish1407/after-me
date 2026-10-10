from __future__ import annotations

import pytest
from argon2 import PasswordHasher as RawArgon2

from app.security.passwords import (
    PasswordHasher,
    PasswordPolicyError,
    check_password_policy,
    common_passwords,
    normalize_password,
)

pytestmark = pytest.mark.no_db


def _code(password: str, email: str | None = "diwakar@example.com") -> str:
    with pytest.raises(PasswordPolicyError) as excinfo:
        check_password_policy(password, email=email)
    return excinfo.value.code


def test_accepts_long_unique_passwords() -> None:
    assert check_password_policy("correct horse battery staple") == "correct horse battery staple"
    assert check_password_policy("ünïcödé pässwörd ✓") == "ünïcödé pässwörd ✓"


def test_length_limits_apply_after_nfkc() -> None:
    assert _code("short") == "too_short"
    assert _code("123456789") == "too_short"
    assert _code("a" * 129) == "too_long"
    assert _code("x" * 2000) == "too_long"
    # U+FB01 (fi ligature) normalises to two characters.
    assert len(normalize_password("ﬁ" * 5)) == 10
    assert check_password_policy("ﬁ" * 5, email=None) == "fi" * 5
    # A full-width password is the same password as its ASCII form.
    assert normalize_password("ｃｏｒｒｅｃｔ") == "correct"


def test_rejects_email_and_local_part() -> None:
    assert _code("Diwakar@Example.com") == "password_matches_email"
    assert _code("DIWAKAR@example.com", email="diwakar@example.com") == "password_matches_email"
    assert _code("diwakar.longname", email="diwakar.longname@example.com") == (
        "password_matches_email"
    )


def test_rejects_common_passwords_case_insensitively() -> None:
    blocklist = common_passwords()
    assert len(blocklist) > 1000
    assert all(len(p) >= 10 for p in blocklist)
    assert _code("1234567890") == "password_too_common"
    assert _code("QWERTYUIOP") == "password_too_common"


async def test_hash_and_verify() -> None:
    hasher = PasswordHasher(time_cost=1, memory_cost_kib=1024, parallelism=1)
    hashed = await hasher.hash("correct horse battery staple")
    assert hashed.startswith("$argon2id$")
    assert await hasher.verify(hashed, "correct horse battery staple")
    assert not await hasher.verify(hashed, "wrong horse battery staple")
    assert not await hasher.verify("not-a-hash", "correct horse battery staple")
    assert not hasher.needs_rehash(hashed)
    await hasher.dummy_verify("anything at all")


async def test_verify_uses_nfkc() -> None:
    hasher = PasswordHasher(time_cost=1, memory_cost_kib=1024, parallelism=1)
    hashed = await hasher.hash("ｃｏｒｒｅｃｔ horse battery")
    assert await hasher.verify(hashed, "correct horse battery")


def test_needs_rehash_when_parameters_change() -> None:
    old = RawArgon2(time_cost=1, memory_cost=1024, parallelism=1).hash("pw-pw-pw-pw")
    stronger = PasswordHasher(time_cost=2, memory_cost_kib=2048, parallelism=1)
    assert stronger.needs_rehash(old)
    assert stronger.needs_rehash("garbage")
