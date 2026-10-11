"""Change email (API_SPEC §2.4; FR-AUTH-09; SECURITY T18)."""

from __future__ import annotations

import re
from datetime import timedelta
from typing import Any

import httpx
import psycopg
import pytest

from app.audit import writer as audit
from app.auth.account_service import AccountService
from tests.support import PASSWORD, Harness, asgi_post_events, bearer, problem

Db = psycopg.Connection[dict[str, Any]]
CODE_RE = re.compile(r"\b(\d{6})\b")


async def _start(h: Harness, tokens: dict[str, Any], new_email: str) -> httpx.Response:
    return await h.client.post(
        "/v1/auth/email/change/start", json={"new_email": new_email}, headers=bearer(tokens)
    )


async def _verify(h: Harness, tokens: dict[str, Any], code: str) -> httpx.Response:
    return await h.client.post(
        "/v1/auth/email/change/verify", json={"code": code}, headers=bearer(tokens)
    )


def _code(h: Harness, address: str) -> str:
    messages = h.mail.to(address, "email_change_code")
    assert messages, f"no email-change code sent to {address}"
    match = CODE_RE.search(messages[-1].text)
    assert match is not None
    return match[1]


async def _signed_in(h: Harness, email: str) -> dict[str, Any]:
    tokens = await h.signup(email)
    assert (await h.reauth(tokens)).status_code == 204
    h.mail.clear()
    return tokens


def _wrong(code: str) -> str:
    return "000000" if code != "000000" else "111111"


# --- start ------------------------------------------------------------------------------------


async def test_start_requires_a_recent_reauth(h: Harness) -> None:
    tokens = await h.signup("needs-reauth@example.com")
    response = await _start(h, tokens, "new@example.com")
    assert response.status_code == 403
    assert problem(response)["code"] == "reauth_required"
    assert h.mail.messages == [] or all(m.template != "email_change_code" for m in h.mail.messages)

    assert (await h.reauth(tokens)).status_code == 204
    h.clock.advance(minutes=5, seconds=1)
    refreshed = (await h.refresh(tokens["refresh_token"])).json()
    stale = await _start(h, refreshed, "new@example.com")
    assert stale.status_code == 403
    assert problem(stale)["code"] == "reauth_required"


async def test_start_sends_a_code_to_the_new_address_and_a_notice_to_the_old_one(
    h: Harness, owner_db: Db
) -> None:
    tokens = await _signed_in(h, "old@example.com")
    response = await _start(h, tokens, "  New.Address@Example.com ")
    assert response.status_code == 202
    assert response.json() == {"status": "code_sent"}

    assert {(m.to, m.template) for m in h.mail.messages} == {
        ("New.Address@example.com", "email_change_code"),
        ("old@example.com", "email_change_requested"),
    }
    code = _code(h, "New.Address@example.com")
    notice = h.mail.to("old@example.com", "email_change_requested")[0]
    assert code not in notice.text  # the old mailbox never sees the code
    assert "New.Address@example.com" not in notice.text  # nor the whole new address
    assert "N***@example.com" in notice.text

    row = owner_db.execute(
        "SELECT kind, secret_hash, payload, attempts, expires_at, created_at FROM auth_tokens "
        "WHERE purpose = 'email_change'"
    ).fetchone()
    assert row is not None
    assert row["kind"] == "code"
    assert code.encode() not in bytes(row["secret_hash"])
    assert row["payload"] == {
        "email": "New.Address@example.com",
        "email_normalized": "new.address@example.com",
    }
    assert row["expires_at"] - row["created_at"] == timedelta(minutes=15)
    event = owner_db.execute(
        "SELECT actor_type, user_visible, metadata FROM audit_logs WHERE action = %s",
        (audit.EMAIL_CHANGE_REQUESTED,),
    ).fetchone()
    assert event == {
        "actor_type": "user",
        "user_visible": False,
        "metadata": {"outcome": "code_sent"},
    }
    # Nothing changed yet.
    me = (await h.client.get("/v1/me", headers=bearer(tokens))).json()
    assert me["email"] == "old@example.com"


async def test_start_answers_identically_whatever_the_new_address_is(
    h: Harness, owner_db: Db
) -> None:
    tokens = await _signed_in(h, "me@example.com")
    await h.signup("taken@example.com")
    assert (await h.register("pending@example.com")).status_code == 202
    h.mail.clear()
    assert (await h.reauth(tokens)).status_code == 204

    free = await _start(h, tokens, "free@example.com")
    h.mail.clear()
    taken = await _start(h, tokens, "Taken@Example.com")
    taken_mail = list(h.mail.messages)
    h.mail.clear()
    same = await _start(h, tokens, "  ME@example.com ")
    same_mail = list(h.mail.messages)

    noise = {"x-request-id", "ratelimit-limit", "ratelimit-remaining", "ratelimit-reset", "date"}
    seen = {
        name: (
            r.status_code,
            r.text,
            sorted((k, v) for k, v in r.headers.items() if k not in noise),
        )
        for name, r in {"free": free, "taken": taken, "same": same}.items()
    }
    assert seen["free"] == seen["taken"] == seen["same"]
    assert free.status_code == 202
    assert free.json() == {"status": "code_sent"}

    # The owner of the taken address gets the account_exists notice (no code); the current
    # address gets nothing at all; the signed-in user learns nothing from the response.
    assert [(m.to, m.template) for m in taken_mail] == [("taken@example.com", "account_exists")]
    assert same_mail == []
    # And no token was created for either of those two.
    assert owner_db.execute(
        "SELECT count(*) AS n FROM auth_tokens WHERE purpose='email_change'"
    ).fetchone() == {"n": 1}
    outcomes = [
        r["metadata"]["outcome"]
        for r in owner_db.execute(
            "SELECT metadata FROM audit_logs WHERE action = %s ORDER BY id",
            (audit.EMAIL_CHANGE_REQUESTED,),
        ).fetchall()
    ]
    assert outcomes == ["code_sent", "address_in_use", "same_address"]

    # An address held by a never-verified signup counts as free.
    pending = await _start(h, tokens, "pending@example.com")
    assert pending.status_code == 202
    assert h.mail.to("pending@example.com", "email_change_code")


async def test_start_does_the_same_database_work_in_every_branch(
    h: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    from sqlalchemy import event

    tokens = await _signed_in(h, "work-me@example.com")
    await h.signup("work-taken@example.com")
    await h.reauth(tokens)

    statements: list[str] = []

    @event.listens_for(h.app.state.services.db.engine.sync_engine, "before_cursor_execute")
    def record(_c: Any, _cur: Any, statement: str, *_a: Any) -> None:
        table = re.search(r"(?:FROM|INTO|UPDATE)\s+(\w+)", statement)
        statements.append(f"{statement.split(maxsplit=1)[0].upper()} {table[1] if table else '?'}")

    work: dict[str, list[str]] = {}
    for name, address in (
        ("free", "work-free@example.com"),
        ("taken", "work-taken@example.com"),
        ("same", "work-me@example.com"),
    ):
        statements.clear()
        assert (await _start(h, tokens, address)).status_code == 202
        # Authentication statements are identical by construction; compare what the service did.
        work[name] = [s for s in statements if "sessions" not in s and "devices" not in s]
    assert work["free"] == work["taken"] == work["same"]


async def test_start_rate_limit_is_five_per_hour_per_user(h: Harness) -> None:
    tokens = await _signed_in(h, "limited@example.com")
    for i in range(5):
        assert (await _start(h, tokens, f"n{i}@example.com")).status_code == 202
    blocked = await _start(h, tokens, "n9@example.com")
    assert blocked.status_code == 429
    assert problem(blocked)["code"] == "rate_limited"
    assert int(blocked.headers["retry-after"]) >= 1
    h.clock.advance(hours=1)
    refreshed = (await h.refresh(tokens["refresh_token"])).json()
    assert (await h.reauth(refreshed)).status_code == 204
    assert (await _start(h, refreshed, "n9@example.com")).status_code == 202


@pytest.mark.parametrize(
    "body", [{}, {"new_email": "nope"}, {"new_email": "a@example.com", "x": 1}, {"new_email": 5}]
)
async def test_start_validates_the_body(h: Harness, body: dict[str, Any]) -> None:
    tokens = await _signed_in(h, "shape-email@example.com")
    response = await h.client.post("/v1/auth/email/change/start", json=body, headers=bearer(tokens))
    assert response.status_code == 422
    assert problem(response)["code"] == "validation_failed"


async def test_a_new_start_supersedes_the_previous_code(h: Harness) -> None:
    tokens = await _signed_in(h, "supersede@example.com")
    await _start(h, tokens, "first@example.com")
    first_code = _code(h, "first@example.com")
    await _start(h, tokens, "second@example.com")
    second_code = _code(h, "second@example.com")
    assert (await _verify(h, tokens, first_code)).status_code == 400
    ok = await _verify(h, tokens, second_code)
    assert ok.status_code == 200
    assert ok.json()["email"] == "second@example.com"


# --- verify -----------------------------------------------------------------------------------


async def test_verify_changes_the_email_and_keeps_every_session(h: Harness, owner_db: Db) -> None:
    tokens = await _signed_in(h, "before@example.com")
    other = (await h.login("before@example.com")).json()
    await _start(h, tokens, "After@Example.com")
    code = _code(h, "After@Example.com")
    h.mail.clear()

    response = await _verify(h, tokens, code)
    assert response.status_code == 200
    me = await h.client.get("/v1/me", headers=bearer(tokens))
    assert response.json() == me.json()  # same body as GET /me
    # the local part keeps its casing; the domain is lower-cased (canonical spelling)
    assert me.json()["email"] == "After@example.com"

    row = owner_db.execute("SELECT email, email_normalized FROM users").fetchone()
    assert row == {"email": "After@example.com", "email_normalized": "after@example.com"}
    # Both sessions survive.
    assert (await h.client.get("/v1/me", headers=bearer(other))).status_code == 200
    # Sign-in works with the new address only.
    assert (await h.login("after@example.com")).status_code == 200
    assert (await h.login("before@example.com")).status_code == 401
    # The notice goes to the OLD address, not the new one.
    notices = h.mail.to("before@example.com", "email_changed")
    assert len(notices) == 1
    assert "A***@example.com" in notices[0].text
    assert h.mail.to("After@example.com", "email_changed") == []
    changed = owner_db.execute(
        "SELECT actor_type, user_visible, metadata FROM audit_logs WHERE action = %s",
        (audit.EMAIL_CHANGED,),
    ).fetchone()
    assert changed == {"actor_type": "user", "user_visible": True, "metadata": {}}
    # The code is single use.
    assert (await _verify(h, tokens, code)).status_code == 400


async def test_verify_without_a_pending_change_is_invalid_code(h: Harness) -> None:
    tokens = await h.signup("nothing-pending@example.com")
    response = await _verify(h, tokens, "123456")
    assert response.status_code == 400
    assert problem(response)["code"] == "invalid_code"


async def test_verify_allows_five_attempts_then_locks_the_code(h: Harness) -> None:
    tokens = await _signed_in(h, "attempts@example.com")
    await _start(h, tokens, "attempts-new@example.com")
    code = _code(h, "attempts-new@example.com")
    for _ in range(5):
        response = await _verify(h, tokens, _wrong(code))
        assert response.status_code == 400
        assert problem(response)["code"] == "invalid_code"
    exhausted = await _verify(h, tokens, code)  # even the right one is refused now
    assert exhausted.status_code == 400
    me = (await h.client.get("/v1/me", headers=bearer(tokens))).json()
    assert me["email"] == "attempts@example.com"


async def test_verify_rejects_an_expired_code(h: Harness) -> None:
    tokens = await _signed_in(h, "expiring@example.com")
    await _start(h, tokens, "expiring-new@example.com")
    code = _code(h, "expiring-new@example.com")
    h.clock.advance(minutes=15)
    refreshed = (await h.refresh(tokens["refresh_token"])).json()
    response = await _verify(h, refreshed, code)
    assert response.status_code == 400
    assert problem(response)["code"] == "invalid_code"


async def test_a_code_only_works_for_the_account_it_was_issued_to(h: Harness) -> None:
    alice = await _signed_in(h, "alice@example.com")
    bob = await h.signup("bob@example.com")
    await _start(h, alice, "alice-new@example.com")
    code = _code(h, "alice-new@example.com")
    assert (await _verify(h, bob, code)).status_code == 400
    assert (await _verify(h, alice, code)).status_code == 200


async def test_verify_loses_the_race_for_an_address_that_became_taken(
    h: Harness, owner_db: Db
) -> None:
    tokens = await _signed_in(h, "racer@example.com")
    await _start(h, tokens, "contested@example.com")
    code = _code(h, "contested@example.com")
    await h.signup("contested@example.com")  # somebody else registers it meanwhile

    response = await _verify(h, tokens, code)
    assert response.status_code == 400
    assert problem(response)["code"] == "invalid_code"
    emails = {r["email"] for r in owner_db.execute("SELECT email FROM users").fetchall()}
    assert emails == {"racer@example.com", "contested@example.com"}
    assert h.mail.to("racer@example.com", "email_changed") == []


async def test_verify_maps_a_database_uniqueness_violation_to_invalid_code(
    h: Harness, monkeypatch: pytest.MonkeyPatch, owner_db: Db
) -> None:
    """The explicit check can be raced; the unique index is the final arbiter."""
    tokens = await _signed_in(h, "db-racer@example.com")
    await _start(h, tokens, "db-contested@example.com")
    code = _code(h, "db-contested@example.com")
    await h.signup("db-contested@example.com")

    async def no_check(self: AccountService, user: Any, new_norm: str) -> None:
        return None

    monkeypatch.setattr(AccountService, "_release_address", no_check)
    response = await _verify(h, tokens, code)
    assert response.status_code == 400
    assert problem(response)["code"] == "invalid_code"
    assert owner_db.execute(
        "SELECT count(*) AS n FROM users WHERE email = 'db-racer@example.com'"
    ).fetchone() == {"n": 1}
    audit_rows = owner_db.execute(
        "SELECT count(*) AS n FROM audit_logs WHERE action = %s", (audit.EMAIL_CHANGED,)
    ).fetchone()
    assert audit_rows == {"n": 0}  # rolled back with the failed change


async def test_verify_supersedes_a_pending_unverified_signup_for_the_address(
    h: Harness, owner_db: Db
) -> None:
    tokens = await _signed_in(h, "winner@example.com")
    assert (await h.register("squatter@example.com")).status_code == 202
    await _start(h, tokens, "squatter@example.com")
    code = _code(h, "squatter@example.com")
    response = await _verify(h, tokens, code)
    assert response.status_code == 200
    assert response.json()["email"] == "squatter@example.com"
    assert owner_db.execute("SELECT count(*) AS n FROM users").fetchone() == {"n": 1}


async def test_changing_email_invalidates_reset_links_sent_to_the_old_address(h: Harness) -> None:
    tokens = await _signed_in(h, "oldbox@example.com")
    await h.forgot("oldbox@example.com")
    link = h.reset_token_for("oldbox@example.com")
    await _start(h, tokens, "newbox@example.com")
    assert (await _verify(h, tokens, _code(h, "newbox@example.com"))).status_code == 200
    assert (await h.web_reset(link, "a different passphrase 55")).status_code == 400
    assert (await h.login("newbox@example.com", PASSWORD)).status_code == 200


async def test_verify_validates_the_body(h: Harness) -> None:
    tokens = await h.signup("body-shape@example.com")
    for body in (
        {},
        {"code": "12345"},
        {"code": "abcdef"},
        {"code": "123456", "x": 1},
        {"code": 123456},
    ):
        response = await h.client.post(
            "/v1/auth/email/change/verify", json=body, headers=bearer(tokens)
        )
        assert response.status_code == 422, body


async def test_concurrent_verifications_of_one_code_change_the_email_once(h: Harness) -> None:
    import asyncio

    tokens = await _signed_in(h, "double@example.com")
    await _start(h, tokens, "double-new@example.com")
    code = _code(h, "double-new@example.com")
    results = await asyncio.gather(_verify(h, tokens, code), _verify(h, tokens, code))
    assert sorted(r.status_code for r in results) == [200, 400]
    assert len(h.mail.to("double@example.com", "email_changed")) == 1


async def test_a_code_row_without_its_payload_can_never_be_redeemed(
    h: Harness, owner_db: Db
) -> None:
    tokens = await _signed_in(h, "nopayload@example.com")
    await _start(h, tokens, "nopayload-new@example.com")
    code = _code(h, "nopayload-new@example.com")
    owner_db.execute("UPDATE auth_tokens SET payload = NULL WHERE purpose = 'email_change'")
    response = await _verify(h, tokens, code)
    assert response.status_code == 400
    assert problem(response)["code"] == "invalid_code"


@pytest.mark.parametrize(
    "probe", ["Taken@Example.com", "  ME-oracle@example.com ", "free2@example.com"]
)
async def test_start_supersedes_the_earlier_code_whatever_the_new_address_is(
    h: Harness, owner_db: Db, probe: str
) -> None:
    """No oracle: redeeming the earlier code fails the same way after a start for a free, a taken
    or the current address."""
    tokens = await _signed_in(h, "me-oracle@example.com")
    await h.signup("taken@example.com")
    assert (await h.reauth(tokens)).status_code == 204
    assert (await _start(h, tokens, "first-free@example.com")).status_code == 202
    first_code = _code(h, "first-free@example.com")

    assert (await _start(h, tokens, probe)).status_code == 202
    unused = owner_db.execute(
        "SELECT count(*) AS n FROM auth_tokens WHERE purpose='email_change' AND used_at IS NULL"
    ).fetchone()
    assert unused == {"n": 1 if probe == "free2@example.com" else 0}

    response = await _verify(h, tokens, first_code)
    assert response.status_code == 400
    assert problem(response)["code"] == "invalid_code"
    me = (await h.client.get("/v1/me", headers=bearer(tokens))).json()
    assert me["email"] == "me-oracle@example.com"


@pytest.mark.no_rate_limit
async def test_start_leaves_the_same_used_rows_in_every_branch(h: Harness, owner_db: Db) -> None:
    tokens = await _signed_in(h, "used-me@example.com")
    await h.signup("used-taken@example.com")
    counts: dict[str, int] = {}
    for name, address in (
        ("free", "used-free@example.com"),
        ("taken", "used-taken@example.com"),
        ("same", "used-me@example.com"),
    ):
        owner_db.execute("DELETE FROM auth_tokens WHERE purpose='email_change'")
        assert (await h.reauth(tokens)).status_code == 204
        assert (await _start(h, tokens, "seed-" + name + "@example.com")).status_code == 202
        before = owner_db.execute(
            "SELECT count(*) AS n FROM auth_tokens WHERE purpose='email_change' AND used_at IS NULL"
        ).fetchone()
        assert before == {"n": 1}
        assert (await _start(h, tokens, address)).status_code == 202
        row = owner_db.execute(
            "SELECT count(*) FILTER (WHERE used_at IS NOT NULL) AS used FROM auth_tokens "
            "WHERE purpose='email_change' AND payload->>'email' = %s",
            ("seed-" + name + "@example.com",),
        ).fetchone()
        assert row is not None
        counts[name] = row["used"]
        h.clock.advance(minutes=1)
    assert counts == {"free": 1, "taken": 1, "same": 1}


async def test_the_code_email_does_not_name_the_account_holder(h: Harness) -> None:
    tokens = await _signed_in(h, "private-name@example.com")
    assert (await _start(h, tokens, "stranger@example.com")).status_code == 202
    text = h.mail.to("stranger@example.com", "email_change_code")[0].text
    assert "Test User" not in text
    assert text.startswith("Hello,")


async def test_a_failing_email_provider_does_not_fail_email_change_verify(h: Harness) -> None:
    tokens = await _signed_in(h, "mailfail-email@example.com")
    assert (await _start(h, tokens, "mailfail-new@example.com")).status_code == 202
    code = _code(h, "mailfail-new@example.com")
    h.mail.fail_next = True
    assert (await _verify(h, tokens, code)).status_code == 200


async def test_start_sends_its_mail_only_after_the_response_has_been_produced(
    h: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    tokens = await _signed_in(h, "after-response@example.com")
    events = await asgi_post_events(
        h,
        monkeypatch,
        "/v1/auth/email/change/start",
        {"new_email": "after-response-new@example.com"},
        {"Authorization": f"Bearer {tokens['access_token']}"},
    )
    assert events.index("deliver") > events.index("response_end")
