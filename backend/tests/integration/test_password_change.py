"""Change password (API_SPEC §2.4; TEST_PLAN AUTH-*)."""

from __future__ import annotations

from typing import Any

import psycopg
import pytest

from app.audit import writer as audit
from tests.support import NEW_PASSWORD, PASSWORD, Harness, bearer, problem

Db = psycopg.Connection[dict[str, Any]]


async def _change(
    h: Harness, tokens: dict[str, Any], current: str = PASSWORD, new: str = NEW_PASSWORD
) -> Any:
    return await h.client.post(
        "/v1/auth/password/change",
        json={"current_password": current, "new_password": new},
        headers=bearer(tokens),
    )


async def test_change_password_keeps_this_session_and_ends_the_others(
    h: Harness, owner_db: Db
) -> None:
    current = await h.signup("change@example.com")
    other = (await h.login("change@example.com")).json()
    third = (await h.login("change@example.com")).json()
    bystander = await h.signup("by@example.com")
    owner_db.execute("UPDATE devices SET push_token = 'tok-' || id::text")
    h.mail.clear()

    response = await _change(h, current)
    assert response.status_code == 204
    assert response.content == b""

    # This session carries on, including its refresh token.
    assert (await h.client.get("/v1/me", headers=bearer(current))).status_code == 200
    assert (await h.refresh(current["refresh_token"])).status_code == 200
    # Every other session is gone.
    for tokens in (other, third):
        gone = await h.client.get("/v1/me", headers=bearer(tokens))
        assert gone.status_code == 401
        assert problem(gone)["code"] == "session_revoked"
        assert (await h.refresh(tokens["refresh_token"])).status_code == 401
    assert (await h.client.get("/v1/me", headers=bearer(bystander))).status_code == 200

    rows = owner_db.execute(
        "SELECT revoke_reason, count(*) AS n FROM sessions WHERE user_id = %s::uuid "
        "GROUP BY revoke_reason ORDER BY 1 NULLS LAST",
        (current["user"]["id"],),
    ).fetchall()
    assert rows == [{"revoke_reason": "password_changed", "n": 2}, {"revoke_reason": None, "n": 1}]

    # The password really changed.
    assert (await h.login("change@example.com", PASSWORD)).status_code == 401
    assert (await h.login("change@example.com", NEW_PASSWORD)).status_code == 200
    user = owner_db.execute(
        "SELECT password_changed_at, password_hash FROM users WHERE email = 'change@example.com'"
    ).fetchone()
    assert user is not None
    assert user["password_changed_at"] == h.clock.current
    assert NEW_PASSWORD not in user["password_hash"]
    assert user["password_hash"].startswith("$argon2id$")

    # Push tokens: the current device keeps its token, the signed-out devices lose theirs.
    tokens_by_device = {
        str(r["id"]): r["push_token"]
        for r in owner_db.execute("SELECT id, push_token FROM devices").fetchall()
    }
    assert tokens_by_device[current["device_id"]] is not None
    assert tokens_by_device[other["device_id"]] is None
    assert tokens_by_device[third["device_id"]] is None
    assert tokens_by_device[bystander["device_id"]] is not None

    # Security email and a user-visible audit record, with no secrets in either.
    notices = h.mail.to("change@example.com", "password_changed")
    assert len(notices) == 1
    assert NEW_PASSWORD not in notices[0].text
    assert PASSWORD not in notices[0].text
    audit_row = owner_db.execute(
        "SELECT actor_type, user_visible, metadata FROM audit_logs WHERE action = %s",
        (audit.PASSWORD_CHANGED,),
    ).fetchone()
    assert audit_row == {
        "actor_type": "user",
        "user_visible": True,
        "metadata": {"sessions_revoked": 2},
    }


async def test_wrong_current_password_is_a_401_that_keeps_the_session(
    h: Harness, owner_db: Db
) -> None:
    tokens = await h.signup("wrong@example.com")
    h.mail.clear()
    response = await _change(h, tokens, current="not my password at all")
    assert response.status_code == 401
    body = problem(response)
    assert body["code"] == "invalid_credentials"
    assert "not my password" not in response.text
    # Session still valid; nothing changed; no email.
    assert (await h.client.get("/v1/me", headers=bearer(tokens))).status_code == 200
    assert (await h.login("wrong@example.com", PASSWORD)).status_code == 200
    assert h.mail.messages == [] or {m.template for m in h.mail.messages} == {"new_device_login"}
    failure = owner_db.execute(
        "SELECT actor_type, metadata, user_visible FROM audit_logs WHERE action = %s",
        (audit.REAUTH_FAILED,),
    ).fetchone()
    assert failure == {
        "actor_type": "user",
        "metadata": {"reason": "change_password"},
        "user_visible": False,
    }


async def test_new_password_must_differ_from_the_current_one(h: Harness) -> None:
    tokens = await h.signup("same@example.com")
    response = await _change(h, tokens, current=PASSWORD, new=PASSWORD)
    assert response.status_code == 422
    body = problem(response)
    assert body["code"] == "validation_failed"
    assert body["errors"][0]["field"] == "new_password"
    assert body["errors"][0]["code"] == "password_unchanged"
    # NFKC-equivalent spellings count as the same password (full-width letters here).
    fullwidth = "ｃｏｒｒｅｃｔ horse battery staple"
    assert (
        await _change(h, tokens, current="correct horse battery staple", new=fullwidth)
    ).status_code == 422


async def test_new_password_policy_is_enforced_with_field_errors(h: Harness) -> None:
    tokens = await h.signup("policy-change@example.com")
    cases = {
        "short": "too_short",
        "x" * 129: "too_long",
        "password123": "password_too_common",
        "policy-change@example.com": "password_matches_email",
        "policy-change": "password_matches_email",
    }
    for password, code in cases.items():
        response = await _change(h, tokens, new=password)
        assert response.status_code == 422, password
        error = problem(response)["errors"][0]
        assert (error["field"], error["code"]) == ("new_password", code)
        assert password not in response.text or len(password) < 20  # never echoed


async def test_policy_failures_do_not_use_up_the_password_guessing_budget(h: Harness) -> None:
    tokens = await h.signup("budget@example.com")
    for _ in range(8):
        assert (await _change(h, tokens, new="short")).status_code == 422
    assert (await _change(h, tokens)).status_code == 204


async def test_change_password_shares_its_rate_limit_with_reauth(h: Harness) -> None:
    tokens = await h.signup("shared@example.com")
    assert (await h.reauth(tokens, "wrong one")).status_code == 401
    assert (await h.reauth(tokens, "wrong two")).status_code == 401
    assert (await _change(h, tokens, current="wrong three")).status_code == 401
    assert (await _change(h, tokens, current="wrong four")).status_code == 401
    assert (await h.reauth(tokens, "wrong five")).status_code == 401
    blocked = await _change(h, tokens)  # even the right password is refused now
    assert blocked.status_code == 429
    assert problem(blocked)["code"] == "rate_limited"
    assert int(blocked.headers["retry-after"]) >= 1
    assert (await h.reauth(tokens)).status_code == 429  # and the budget is shared both ways
    h.clock.advance(minutes=15)
    refreshed = (await h.refresh(tokens["refresh_token"])).json()  # the access token expired too
    assert (await _change(h, refreshed)).status_code == 204


async def test_change_password_budget_is_per_session(h: Harness) -> None:
    first = await h.signup("persession@example.com")
    second = (await h.login("persession@example.com")).json()
    for _ in range(5):
        assert (await _change(h, first, current="nope nope nope")).status_code == 401
    assert (await _change(h, first, current="nope nope nope")).status_code == 429
    assert (await _change(h, second)).status_code == 204


async def test_change_password_request_validation(h: Harness) -> None:
    tokens = await h.signup("shape@example.com")
    for body in (
        {},
        {"current_password": PASSWORD},
        {"new_password": NEW_PASSWORD},
        {"current_password": PASSWORD, "new_password": NEW_PASSWORD, "extra": 1},
        {"current_password": "", "new_password": NEW_PASSWORD},
        {"current_password": PASSWORD, "new_password": 12345},
    ):
        response = await h.client.post(
            "/v1/auth/password/change", json=body, headers=bearer(tokens)
        )
        assert response.status_code == 422, body
        assert problem(response)["code"] == "validation_failed"


async def test_change_password_invalidates_outstanding_reset_links(h: Harness) -> None:
    tokens = await h.signup("links@example.com")
    await h.forgot("links@example.com")
    link = h.reset_token_for("links@example.com")
    assert (await _change(h, tokens)).status_code == 204
    assert (await h.web_reset(link, "another long passphrase 99")).status_code == 400


async def test_a_change_that_lost_a_race_with_another_change_does_not_overwrite_it(
    h: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    tokens = await h.signup("race-change@example.com")
    passwords = h.app.state.services.passwords
    real_verify = passwords.verify
    ran: list[bool] = []

    async def verify_then_change(stored_hash: str, password: str) -> bool:
        ok = await real_verify(stored_hash, password)
        if not ran:
            ran.append(True)
            assert (await _change(h, tokens, new="the winning passphrase 11")).status_code == 204
        return bool(ok)

    monkeypatch.setattr(passwords, "verify", verify_then_change)
    losing = await _change(h, tokens, new=NEW_PASSWORD)
    monkeypatch.undo()
    assert losing.status_code == 401
    assert problem(losing)["code"] == "invalid_credentials"
    assert (
        await h.login("race-change@example.com", "the winning passphrase 11")
    ).status_code == 200
    assert (await h.login("race-change@example.com", NEW_PASSWORD)).status_code == 401


async def test_a_change_from_a_session_revoked_meanwhile_is_refused(
    h: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    tokens = await h.signup("race-revoked@example.com")
    passwords = h.app.state.services.passwords
    real_verify = passwords.verify
    ran: list[bool] = []

    async def verify_then_sign_out(stored_hash: str, password: str) -> bool:
        ok = await real_verify(stored_hash, password)
        if not ran:
            ran.append(True)
            out = await h.client.post("/v1/auth/logout-all", headers=bearer(tokens))
            assert out.status_code == 204
        return bool(ok)

    monkeypatch.setattr(passwords, "verify", verify_then_sign_out)
    refused = await _change(h, tokens)
    monkeypatch.undo()
    assert refused.status_code == 401
    assert problem(refused)["code"] == "session_revoked"
    assert (await h.login("race-revoked@example.com", PASSWORD)).status_code == 200
    assert (await h.login("race-revoked@example.com", NEW_PASSWORD)).status_code == 401


async def test_a_failing_email_provider_does_not_fail_a_password_change(h: Harness) -> None:
    tokens = await h.signup("mailfail-change@example.com")
    h.mail.fail_next = True
    assert (await _change(h, tokens)).status_code == 204
    assert (await h.login("mailfail-change@example.com", NEW_PASSWORD)).status_code == 200
