"""Signup: start, verify, resend (API_SPEC §2.1-2.2; TEST_PLAN AUTH-01..)."""

from __future__ import annotations

import uuid
from datetime import timedelta
from typing import Any

import psycopg
import pytest

from app.auth.codes import hash_code
from app.security.hashing import Pepper
from tests.support import PASSWORD, TEST_PEPPER, Harness, bearer, problem

Db = psycopg.Connection[dict[str, Any]]


def _user(db: Db, email: str) -> dict[str, Any] | None:
    return db.execute(
        "SELECT * FROM users WHERE email_normalized = %s", (email.lower(),)
    ).fetchone()


async def test_start_creates_unverified_user_profile_and_code(h: Harness, owner_db: Db) -> None:
    response = await h.register("  New.User@Example.com ", country_code="in", locale="en-IN")
    assert response.status_code == 202
    assert response.json() == {"status": "code_sent", "resend_after_seconds": 60}

    user = _user(owner_db, "new.user@example.com")
    assert user is not None
    assert user["email"] == "New.User@Example.com"
    assert user["email_verified_at"] is None
    assert user["password_hash"].startswith("$argon2id$")
    assert PASSWORD not in user["password_hash"]
    profile = owner_db.execute(
        "SELECT * FROM user_profiles WHERE user_id = %s", (user["id"],)
    ).fetchone()
    assert profile is not None
    assert (profile["display_name"], profile["timezone"], profile["locale"]) == (
        "Test User",
        "Asia/Kolkata",
        "en-IN",
    )
    assert profile["country_code"] == "IN"

    token = owner_db.execute(
        "SELECT * FROM auth_tokens WHERE user_id = %s", (user["id"],)
    ).fetchone()
    assert token is not None
    assert (token["purpose"], token["kind"], token["attempts"]) == ("signup_verify", "code", 0)
    assert token["expires_at"] - token["created_at"] == timedelta(minutes=15)
    code = h.code_for("new.user@example.com")
    expected = hash_code(
        Pepper(TEST_PEPPER), user_id=user["id"], purpose="signup_verify", code=code
    )
    assert bytes(token["secret_hash"]) == expected  # HMAC, never the code itself
    assert code.encode() not in bytes(token["secret_hash"])
    assert owner_db.execute("SELECT count(*) AS n FROM checkin_configurations").fetchone() == {
        "n": 0
    }


async def test_start_responses_are_identical_for_all_three_branches(
    h: Harness, owner_db: Db
) -> None:
    await h.signup("verified@example.com")
    await h.register("pending@example.com")
    h.mail.clear()

    new = await h.register("brand-new@example.com", display_name="Someone")
    pending = await h.register("pending@example.com", password="another long passphrase")
    verified = await h.register("verified@example.com", password="another long passphrase")

    assert new.status_code == pending.status_code == verified.status_code == 202
    assert new.content == pending.content == verified.content
    skip = {"x-request-id", "date", "ratelimit-remaining", "ratelimit-reset"}
    headers = [
        {k: v for k, v in r.headers.items() if k not in skip} for r in (new, pending, verified)
    ]
    assert headers[0] == headers[1] == headers[2]

    assert [m.template for m in h.mail.to("brand-new@example.com")] == ["signup_code"]
    assert [m.template for m in h.mail.to("pending@example.com")] == ["signup_code"]
    assert [m.template for m in h.mail.to("verified@example.com")] == ["account_exists"]
    exists = h.mail.to("verified@example.com")[0]
    assert "sign in or reset your password" in exists.text
    assert not any(ch.isdigit() for ch in exists.text.split("AfterMe")[0])


async def test_start_for_pending_signup_replaces_password_and_profile(
    h: Harness, owner_db: Db
) -> None:
    await h.register("pending@example.com", display_name="First Name")
    first_code = h.code_for("pending@example.com")
    h.clock.advance(seconds=5)
    await h.register(
        "Pending@Example.com", password="a different long passphrase", display_name="Second"
    )
    user = _user(owner_db, "pending@example.com")
    assert user is not None
    assert user["email"] == "Pending@Example.com"
    profile = owner_db.execute(
        "SELECT display_name FROM user_profiles WHERE user_id = %s", (user["id"],)
    ).fetchone()
    assert profile == {"display_name": "Second"}

    # The first code was superseded by the second.
    stale = await h.verify("pending@example.com", first_code, "a different long passphrase")
    assert stale.status_code == 400
    assert problem(stale)["code"] == "invalid_code"
    fresh = await h.verify(
        "pending@example.com", h.code_for("pending@example.com"), "a different long passphrase"
    )
    assert fresh.status_code == 201
    old_password = await h.login("pending@example.com", PASSWORD)
    assert old_password.status_code == 401
    assert (await h.login("pending@example.com", "a different long passphrase")).status_code == 200


async def test_start_for_verified_account_changes_nothing(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("taken@example.com")
    user_id = tokens["user"]["id"]

    def snapshot() -> tuple[Any, Any, Any]:
        profile = owner_db.execute(
            "SELECT * FROM user_profiles WHERE user_id = %s", (user_id,)
        ).fetchone()
        codes = owner_db.execute(
            "SELECT count(*) AS n FROM auth_tokens WHERE user_id = %s", (user_id,)
        ).fetchone()
        return _user(owner_db, "taken@example.com"), profile, codes

    before = snapshot()
    h.mail.clear()
    # Every profile field differs, so an overwrite could not go unnoticed.
    response = await h.register(
        "taken@example.com",
        password="attacker chosen password",
        display_name="Attacker",
        timezone="America/New_York",
        locale="fr",
        country_code="US",
    )
    assert response.status_code == 202
    assert snapshot() == before
    assert [m.template for m in h.mail.to("taken@example.com")] == ["account_exists"]
    me = (await h.client.get("/v1/me", headers=bearer(tokens))).json()
    assert me["profile"]["display_name"] == "Test User"
    assert me["profile"]["timezone"] == "Asia/Kolkata"
    assert (await h.login("taken@example.com")).status_code == 200


async def test_verify_success(h: Harness, owner_db: Db) -> None:
    await h.register("verify@example.com")
    h.clock.advance(minutes=3)
    response = await h.verify("Verify@Example.com", h.code_for("verify@example.com"))
    assert response.status_code == 201
    body = response.json()
    assert set(body) == {
        "access_token",
        "access_token_expires_at",
        "refresh_token",
        "session_id",
        "device_id",
        "user",
    }
    assert body["refresh_token"].startswith("rt_")
    assert body["user"]["email"] == "verify@example.com"
    assert body["user"]["tier"] == "free"
    assert body["access_token_expires_at"] == "2026-10-08T09:18:00Z"  # T0 + 3 min + 15 min

    user = _user(owner_db, "verify@example.com")
    assert user is not None
    assert user["email_verified_at"] == h.clock.current
    config = owner_db.execute(
        "SELECT status, interval_days FROM checkin_configurations WHERE user_id = %s",
        (user["id"],),
    ).fetchone()
    assert config == {"status": "inactive", "interval_days": 1}
    session = owner_db.execute(
        "SELECT * FROM sessions WHERE id = %s", (body["session_id"],)
    ).fetchone()
    assert session is not None
    assert session["kind"] == "app"
    assert session["device_id"] == uuid.UUID(body["device_id"])
    assert session["idle_expires_at"] == h.clock.current + timedelta(days=60)
    assert session["absolute_expires_at"] == h.clock.current + timedelta(days=365)
    assert session["ip_hash"] is not None
    device = owner_db.execute(
        "SELECT platform, app_version, os_version, locale FROM devices WHERE id = %s",
        (body["device_id"],),
    ).fetchone()
    assert device == {
        "platform": "android",
        "app_version": "1.0.0+12",
        "os_version": "15",
        "locale": "en-IN",
    }

    me = await h.client.get("/v1/me", headers=bearer(body))
    assert me.status_code == 200

    # The code is single-use.
    again = await h.verify("verify@example.com", h.code_for("verify@example.com"))
    assert again.status_code == 400


async def test_verify_wrong_code(h: Harness) -> None:
    await h.register("wrong@example.com")
    code = h.code_for("wrong@example.com")
    wrong = "000000" if code != "000000" else "111111"
    response = await h.verify("wrong@example.com", wrong)
    assert response.status_code == 400
    body = problem(response)
    assert body["code"] == "invalid_code"
    assert (await h.verify("wrong@example.com", code)).status_code == 201


async def test_verify_unknown_email_is_the_same_generic_error(h: Harness) -> None:
    response = await h.verify("nobody@example.com", "123456")
    assert response.status_code == 400
    assert problem(response)["code"] == "invalid_code"


async def test_verify_expired_code(h: Harness) -> None:
    await h.register("late@example.com")
    code = h.code_for("late@example.com")
    h.clock.advance(minutes=15)
    response = await h.verify("late@example.com", code)
    assert response.status_code == 400
    assert problem(response)["code"] == "invalid_code"


async def test_verify_just_before_expiry(h: Harness) -> None:
    await h.register("ontime@example.com")
    code = h.code_for("ontime@example.com")
    h.clock.advance(minutes=14, seconds=59)
    assert (await h.verify("ontime@example.com", code)).status_code == 201


@pytest.mark.no_rate_limit
async def test_sixth_attempt_is_rejected_even_with_the_right_code(h: Harness, owner_db: Db) -> None:
    await h.register("brute@example.com")
    code = h.code_for("brute@example.com")
    wrong = "000000" if code != "000000" else "111111"
    for _ in range(5):
        assert (await h.verify("brute@example.com", wrong)).status_code == 400
    attempts = owner_db.execute("SELECT attempts FROM auth_tokens WHERE used_at IS NULL").fetchone()
    assert attempts == {"attempts": 5}  # persisted although every response was an error
    sixth = await h.verify("brute@example.com", code)
    assert sixth.status_code == 400
    assert problem(sixth)["code"] == "invalid_code"


async def test_verified_account_cannot_verify_again(h: Harness) -> None:
    await h.signup("done@example.com")
    response = await h.verify("done@example.com", h.code_for("done@example.com"))
    assert response.status_code == 400


async def test_resend_is_throttled_to_one_code_per_minute(h: Harness) -> None:
    await h.register("resend@example.com")
    first = h.code_for("resend@example.com")

    too_soon = await h.client.post("/v1/auth/register/resend", json={"email": "resend@example.com"})
    assert too_soon.status_code == 202
    assert too_soon.json() == {"status": "code_sent", "resend_after_seconds": 60}
    assert len(h.mail.to("resend@example.com", "signup_code")) == 1

    h.clock.advance(seconds=60)
    later = await h.client.post("/v1/auth/register/resend", json={"email": "resend@example.com"})
    assert later.status_code == 202
    assert len(h.mail.to("resend@example.com", "signup_code")) == 2
    second = h.code_for("resend@example.com")
    assert "Hi Test User" in h.mail.to("resend@example.com")[-1].text

    # Only the newest code works.
    if first != second:
        assert (await h.verify("resend@example.com", first)).status_code == 400
    assert (await h.verify("resend@example.com", second)).status_code == 201


async def test_resend_is_silent_for_unknown_and_verified(h: Harness) -> None:
    await h.signup("verified2@example.com")
    h.mail.clear()
    for email in ("unknown@example.com", "verified2@example.com"):
        response = await h.client.post("/v1/auth/register/resend", json={"email": email})
        assert response.status_code == 202
        assert response.json() == {"status": "code_sent", "resend_after_seconds": 60}
    assert h.mail.messages == []


@pytest.mark.no_rate_limit
async def test_start_rejects_weak_or_invalid_input(h: Harness, owner_db: Db) -> None:
    cases: list[dict[str, Any]] = [
        {"password": "1234567890"},
        {"password": "weak"},
        {"display_name": "AfterMe Support"},
        {"display_name": "click http://x.example"},
        {"timezone": "Not/AZone"},
        {"status": "active"},
    ]
    for extra in cases:
        response = await h.register("val@example.com", **extra)
        assert response.status_code == 422, extra
        assert problem(response)["code"] == "validation_failed"
    assert _user(owner_db, "val@example.com") is None
    assert h.mail.messages == []


async def test_pre_hijack_attempt_cannot_activate_an_account_with_the_attackers_password(
    h: Harness, owner_db: Db
) -> None:
    """An attacker starts a signup for the victim's address with their own password. The
    victim then types the code from the email they receive. Without the password check that
    would activate an account the attacker can log in to."""
    victim, attacker_password = "victim@example.com", "attacker chosen password 1"
    assert (await h.register(victim, attacker_password)).status_code == 202
    attacker_code = h.code_for(victim)

    # The victim, believing the email is theirs, enters the code with their own password.
    response = await h.verify(victim, attacker_code, "victims own password 99")
    assert response.status_code == 400
    assert problem(response)["code"] == "invalid_code"
    user = owner_db.execute(
        "SELECT email_verified_at FROM users WHERE email_normalized = %s", (victim,)
    ).fetchone()
    assert user is not None
    assert user["email_verified_at"] is None

    # The victim starts their own signup; it replaces the attacker's password, and only the
    # victim's password now verifies the new code.
    assert (await h.register(victim, "victims own password 99")).status_code == 202
    victim_code = h.code_for(victim)
    assert (await h.verify(victim, victim_code, attacker_password)).status_code == 400
    assert (await h.verify(victim, victim_code, "victims own password 99")).status_code == 201
    assert (await h.login(victim, attacker_password)).status_code == 401
    assert (await h.login(victim, "victims own password 99")).status_code == 200
