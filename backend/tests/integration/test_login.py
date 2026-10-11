"""Login (API_SPEC §2.3; SECURITY §7 lockout; T4, T18)."""

from __future__ import annotations

import asyncio
from datetime import timedelta
from typing import Any

import psycopg
import pytest
from argon2 import PasswordHasher as RawArgon2

from tests.support import NEW_PASSWORD, PASSWORD, Harness, bearer, problem

Db = psycopg.Connection[dict[str, Any]]


def _user(db: Db, email: str) -> dict[str, Any]:
    row = db.execute("SELECT * FROM users WHERE email_normalized = %s", (email,)).fetchone()
    assert row is not None
    return row


async def test_login_success_creates_device_and_session(h: Harness, owner_db: Db) -> None:
    await h.signup("login@example.com")
    h.clock.advance(hours=1)
    response = await h.login("LOGIN@example.com")
    assert response.status_code == 200
    body = response.json()
    assert body["user"]["email"] == "login@example.com"
    user = _user(owner_db, "login@example.com")
    assert user["last_login_at"] == h.clock.current
    assert user["failed_login_count"] == 0
    devices = owner_db.execute("SELECT count(*) AS n FROM devices").fetchone()
    assert devices == {"n": 2}  # signup device + a new one (no device id sent)
    me = await h.client.get("/v1/me", headers=bearer(body))
    assert me.status_code == 200


async def test_login_reuses_own_device_but_not_someone_elses(h: Harness, owner_db: Db) -> None:
    mine = await h.signup("mine@example.com")
    other = await h.signup("other@example.com")
    reuse = await h.login("mine@example.com", device_id=mine["device_id"])
    assert reuse.json()["device_id"] == mine["device_id"]
    foreign = await h.login("mine@example.com", device_id=other["device_id"])
    assert foreign.status_code == 200
    assert foreign.json()["device_id"] not in (mine["device_id"], other["device_id"])
    owners = owner_db.execute(
        "SELECT user_id FROM devices WHERE id = %s", (other["device_id"],)
    ).fetchone()
    assert owners is not None
    other_user = _user(owner_db, "other@example.com")
    assert owners["user_id"] == other_user["id"]


async def test_wrong_password_and_unknown_email_look_the_same(h: Harness, owner_db: Db) -> None:
    await h.signup("real@example.com")
    wrong = await h.login("real@example.com", "not the right password")
    unknown = await h.login("ghost@example.com", "not the right password")
    assert wrong.status_code == unknown.status_code == 401
    wrong_body, unknown_body = problem(wrong), problem(unknown)
    assert wrong_body["code"] == unknown_body["code"] == "invalid_credentials"
    assert {k: v for k, v in wrong_body.items() if k != "request_id"} == {
        k: v for k, v in unknown_body.items() if k != "request_id"
    }
    reasons = [
        r["metadata"]["reason"]
        for r in owner_db.execute(
            "SELECT metadata FROM audit_logs WHERE action = 'auth.login_failed' ORDER BY id"
        ).fetchall()
    ]
    assert reasons == ["bad_password", "unknown_account"]


async def test_failure_counters_persist_despite_error_responses(h: Harness, owner_db: Db) -> None:
    await h.signup("count@example.com")
    for _ in range(3):
        assert (await h.login("count@example.com", "bad password guess")).status_code == 401
    assert _user(owner_db, "count@example.com")["failed_login_count"] == 3
    counters = owner_db.execute(
        "SELECT key, count FROM rate_limit_counters WHERE key LIKE 'login_account_net:%'"
    ).fetchall()
    assert [c["count"] for c in counters] == [3]  # one budget: this account on this network
    failures = owner_db.execute(
        "SELECT count(*) AS n FROM audit_logs WHERE action = 'auth.login_failed'"
    ).fetchone()
    assert failures == {"n": 3}
    assert (await h.login("count@example.com")).status_code == 200
    assert _user(owner_db, "count@example.com")["failed_login_count"] == 0


@pytest.mark.no_rate_limit
async def test_lockout_after_ten_failures_and_unlock_after_fifteen_minutes(
    h: Harness, owner_db: Db
) -> None:
    tokens = await h.signup("lock@example.com")
    h.mail.clear()
    for attempt in range(1, 11):
        response = await h.login("lock@example.com", "wrong password attempt")
        assert response.status_code == 401, attempt
    user = _user(owner_db, "lock@example.com")
    assert user["locked_until"] == h.clock.current + timedelta(minutes=15)
    assert [m.template for m in h.mail.to("lock@example.com")] == ["account_locked"]
    locked_audit = owner_db.execute(
        "SELECT metadata FROM audit_logs WHERE action = 'auth.locked'"
    ).fetchall()
    assert locked_audit == [{"metadata": {"reason": "too_many_failures", "lock_minutes": 15}}]

    # While locked, the right password from somewhere the account does not know is answered
    # exactly like a wrong one (Phase 9, F13): same status, same body, no Retry-After, nothing
    # that says the address exists or that it is locked. The owner has the email.
    h.clock.advance(minutes=14, seconds=59)
    locked = await h.login("lock@example.com")
    wrong = await h.login("lock@example.com", "another wrong password")
    unknown = await h.login("nobody-here@example.com", "another wrong password")
    for response in (locked, wrong, unknown):
        assert response.status_code == 401
        assert problem(response)["code"] == "invalid_credentials"
        assert "retry-after" not in response.headers
    assert _user(owner_db, "lock@example.com")["locked_until"] is not None

    # ...but the phone the account already knows is not bound by the lock: a stranger's failures
    # must not be able to keep the person out of their own account (Phase 9, F1).
    known = await h.login("lock@example.com", device_id=tokens["device_id"])
    assert known.status_code == 200
    assert _user(owner_db, "lock@example.com")["locked_until"] is None


@pytest.mark.no_rate_limit
async def test_a_lock_that_nobody_cleared_ends_after_fifteen_minutes(
    h: Harness, owner_db: Db
) -> None:
    await h.signup("expiry@example.com")
    for _ in range(10):
        await h.login("expiry@example.com", "wrong password attempt")
    assert _user(owner_db, "expiry@example.com")["locked_until"] is not None
    h.clock.advance(minutes=15)
    assert (await h.login("expiry@example.com")).status_code == 200
    assert _user(owner_db, "expiry@example.com")["locked_until"] is None


async def test_lockout_is_reached_under_real_rate_limits(h: Harness, owner_db: Db) -> None:
    """With rate limiting on, 10 consecutive failures span two windows. A rate-limited attempt
    must neither count as a failure nor reset the counter."""
    await h.signup("limited@example.com")
    h.mail.clear()
    for _ in range(5):
        assert (await h.login("limited@example.com", "wrong password attempt")).status_code == 401
    limited = await h.login("limited@example.com", "wrong password attempt")
    assert limited.status_code == 429
    assert problem(limited)["code"] == "rate_limited"
    assert limited.headers["ratelimit-remaining"] == "0"
    assert _user(owner_db, "limited@example.com")["failed_login_count"] == 5
    assert _user(owner_db, "limited@example.com")["locked_until"] is None

    h.clock.advance(minutes=15)
    for attempt in range(5):
        response = await h.login("limited@example.com", "wrong password attempt")
        assert response.status_code == 401, attempt
    user = _user(owner_db, "limited@example.com")
    assert user["failed_login_count"] == 0  # the locking failure restarts the count
    assert user["locked_until"] == h.clock.current + timedelta(minutes=15)
    assert [m.template for m in h.mail.to("limited@example.com")] == ["account_locked"]
    assert owner_db.execute(
        "SELECT count(*) AS n FROM audit_logs WHERE action = 'auth.locked'"
    ).fetchone() == {"n": 1}
    assert owner_db.execute(
        "SELECT count(*) AS n FROM audit_logs WHERE action = 'auth.login_failed'"
    ).fetchone() == {"n": 10}  # the 429 attempt wrote no failure record


async def test_successful_logins_do_not_use_the_per_account_budget(h: Harness) -> None:
    await h.signup("many@example.com")
    for _ in range(7):  # more than the 5/15 min failure budget
        response = await h.login("many@example.com")
        assert response.status_code == 200
    # ...and the budget is still intact for a mistyped password afterwards.
    assert (await h.login("many@example.com", "mistyped password")).status_code == 401


async def test_new_device_login_sends_a_security_email_but_a_known_device_does_not(
    h: Harness,
) -> None:
    tokens = await h.signup("device@example.com")
    h.mail.clear()
    known = await h.login("device@example.com", device_id=tokens["device_id"])
    assert known.status_code == 200
    assert h.mail.to("device@example.com") == []

    new = await h.login("device@example.com")
    assert new.status_code == 200
    notices = h.mail.to("device@example.com", "new_device_login")
    assert len(notices) == 1
    assert "android" in notices[0].text
    assert "1.0.0+12" in notices[0].text
    # A failing mail provider never fails the login.
    h.mail.fail_next = True
    assert (await h.login("device@example.com")).status_code == 200


async def test_unverified_login_gets_403_and_a_fresh_code(h: Harness, owner_db: Db) -> None:
    await h.register("unverified@example.com")
    first = h.code_for("unverified@example.com")
    h.clock.advance(seconds=61)
    response = await h.login("unverified@example.com")
    assert response.status_code == 403
    assert problem(response)["code"] == "email_unverified"
    codes = h.mail.to("unverified@example.com", "signup_code")
    assert len(codes) == 2
    second = h.code_for("unverified@example.com")
    if first != second:
        assert (await h.verify("unverified@example.com", first)).status_code == 400
    assert (await h.verify("unverified@example.com", second)).status_code == 201
    assert owner_db.execute("SELECT count(*) AS n FROM sessions").fetchone() == {"n": 1}


async def test_unverified_login_cannot_be_used_to_mail_codes_faster_than_resend(
    h: Harness,
) -> None:
    await h.register("throttle@example.com")
    for _ in range(3):
        h.clock.advance(seconds=10)
        response = await h.login("throttle@example.com")
        assert response.status_code == 403
    assert len(h.mail.to("throttle@example.com", "signup_code")) == 1
    h.clock.advance(seconds=61)
    assert (await h.login("throttle@example.com")).status_code == 403
    assert len(h.mail.to("throttle@example.com", "signup_code")) == 2


async def test_unverified_with_wrong_password_is_plain_401(h: Harness) -> None:
    await h.register("unverified2@example.com")
    response = await h.login("unverified2@example.com", "wrong password here")
    assert response.status_code == 401
    assert len(h.mail.to("unverified2@example.com", "signup_code")) == 1


async def test_suspended_account_cannot_log_in(h: Harness, owner_db: Db) -> None:
    await h.signup("suspended@example.com")
    owner_db.execute(
        "UPDATE users SET status = 'suspended' WHERE email_normalized = 'suspended@example.com'"
    )
    response = await h.login("suspended@example.com")
    assert response.status_code == 401
    assert problem(response)["code"] == "invalid_credentials"


async def test_password_is_rehashed_when_parameters_change(h: Harness, owner_db: Db) -> None:
    await h.signup("rehash@example.com")
    weaker = RawArgon2(time_cost=1, memory_cost=512, parallelism=1).hash(PASSWORD)
    owner_db.execute(
        "UPDATE users SET password_hash = %s WHERE email_normalized = 'rehash@example.com'",
        (weaker,),
    )
    assert (await h.login("rehash@example.com")).status_code == 200
    new_hash = _user(owner_db, "rehash@example.com")["password_hash"]
    assert new_hash != weaker
    assert "m=1024,t=1,p=1" in new_hash
    assert (await h.login("rehash@example.com")).status_code == 200


@pytest.mark.no_rate_limit
@pytest.mark.settings(db_pool_size=1, db_max_overflow=0)
async def test_bookkeeping_does_not_starve_when_the_request_pool_is_exhausted(
    h: Harness, owner_db: Db
) -> None:
    """A request holds a pooled connection while its bookkeeping write runs; the two must not
    compete for the same pool, or concurrent failed logins would wait on each other."""
    await h.signup("pool@example.com")
    attempts = 4
    responses = await asyncio.wait_for(
        asyncio.gather(
            *(h.login("pool@example.com", "wrong password guess") for _ in range(attempts))
        ),
        timeout=20,
    )
    assert [r.status_code for r in responses] == [401] * attempts
    assert _user(owner_db, "pool@example.com")["failed_login_count"] == attempts


async def test_login_racing_a_password_reset_cannot_open_a_session(
    h: Harness, owner_db: Db, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The reset lands between the password check and the session insert: the login must fail
    and no live session may survive the reset's 'revoke everything'."""
    await h.signup("race@example.com")
    await h.forgot("race@example.com")
    token = h.reset_token_for("race@example.com")
    passwords = h.app.state.services.passwords
    real_verify = passwords.verify
    ran: list[bool] = []

    async def verify_then_reset(stored_hash: str, password: str) -> bool:
        ok = await real_verify(stored_hash, password)
        if not ran:
            ran.append(True)
            assert (await h.web_reset(token, NEW_PASSWORD)).status_code == 200
        return bool(ok)

    monkeypatch.setattr(passwords, "verify", verify_then_reset)
    response = await h.login("race@example.com")
    assert response.status_code == 401
    assert problem(response)["code"] == "invalid_credentials"
    monkeypatch.undo()

    live = owner_db.execute("SELECT count(*) AS n FROM sessions WHERE revoked_at IS NULL")
    assert live.fetchone() == {"n": 0}
    assert (await h.login("race@example.com", PASSWORD)).status_code == 401
    assert (await h.login("race@example.com", NEW_PASSWORD)).status_code == 200
