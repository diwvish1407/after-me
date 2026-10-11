"""Anti-enumeration timing parity (SECURITY T18).

Response bodies already match across branches; what keeps the *timing* the same is that every
branch does the same Argon2 work. Wall-clock timing is too noisy to assert on, so these tests
count the Argon2 operations each branch performs and require the counts to be identical.
"""

from __future__ import annotations

from typing import Any, cast

import pytest

from tests.support import Harness


class Argon2Spy:
    def __init__(self) -> None:
        self.hash = 0
        self.verify = 0

    def reset(self) -> None:
        self.hash = self.verify = 0

    @property
    def counts(self) -> tuple[int, int]:
        return self.hash, self.verify


class _CountingArgon2:
    """Stands in for argon2.PasswordHasher (whose methods are read-only slots)."""

    def __init__(self, inner: Any, spy: Argon2Spy) -> None:
        self._inner = inner
        self._spy = spy

    def hash(self, password: str) -> str:
        self._spy.hash += 1
        return cast("str", self._inner.hash(password))

    def verify(self, password_hash: str, password: str) -> bool:
        self._spy.verify += 1
        return cast("bool", self._inner.verify(password_hash, password))

    def check_needs_rehash(self, password_hash: str) -> bool:
        return cast("bool", self._inner.check_needs_rehash(password_hash))


@pytest.fixture
def argon2(h: Harness, monkeypatch: pytest.MonkeyPatch) -> Argon2Spy:
    """Count the real Argon2 operations behind PasswordHasher.hash / verify / dummy_verify."""
    passwords = h.app.state.services.passwords
    spy = Argon2Spy()
    monkeypatch.setattr(passwords, "_hasher", _CountingArgon2(passwords._hasher, spy))
    return spy


async def test_register_start_hashes_exactly_once_in_every_branch(
    h: Harness, argon2: Argon2Spy
) -> None:
    observed: dict[str, tuple[int, int]] = {}

    assert (await h.register("branch@example.com")).status_code == 202
    observed["new"] = argon2.counts
    argon2.reset()

    h.clock.advance(seconds=5)
    again = await h.register("branch@example.com", password="another long passphrase")
    assert again.status_code == 202
    observed["pending"] = argon2.counts
    argon2.reset()

    await h.signup("verified@example.com")
    argon2.reset()
    assert (await h.register("verified@example.com")).status_code == 202
    observed["verified"] = argon2.counts

    assert observed == {"new": (1, 0), "pending": (1, 0), "verified": (1, 0)}


async def test_unknown_email_login_does_the_same_argon2_work_as_a_wrong_password(
    h: Harness, argon2: Argon2Spy
) -> None:
    await h.signup("known@example.com")
    argon2.reset()

    assert (await h.login("known@example.com", "wrong password here")).status_code == 401
    wrong_password = argon2.counts
    argon2.reset()

    assert (await h.login("ghost@example.com", "wrong password here")).status_code == 401
    unknown_email = argon2.counts

    assert wrong_password == unknown_email == (0, 1)


async def test_correct_login_verifies_once(h: Harness, argon2: Argon2Spy) -> None:
    await h.signup("once@example.com")
    argon2.reset()
    assert (await h.login("once@example.com")).status_code == 200
    assert argon2.counts == (0, 1)


@pytest.mark.no_rate_limit
async def test_a_locked_account_does_the_same_work_and_gets_the_same_answer_as_an_unknown_one(
    h: Harness, argon2: Argon2Spy
) -> None:
    """Phase 9 (F13): a lock that answered ``429`` without an Argon2 told a stranger, for the
    cost of ten requests, that an address has an account. A locked account now does the same
    work and returns the same ``401`` as an address nobody registered."""
    from tests.support import problem

    await h.signup("locked-parity@example.com")
    for _ in range(10):
        await h.login("locked-parity@example.com", "wrong password here")
    argon2.reset()

    locked = await h.login("locked-parity@example.com")  # the right password, a device unknown
    locked_counts = argon2.counts
    argon2.reset()
    unknown = await h.login("nobody-registered@example.com")
    unknown_counts = argon2.counts

    assert locked.status_code == unknown.status_code == 401
    assert locked_counts == unknown_counts == (0, 1)
    assert {k: v for k, v in problem(locked).items() if k != "request_id"} == {
        k: v for k, v in problem(unknown).items() if k != "request_id"
    }
    assert "retry-after" not in locked.headers
