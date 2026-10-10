"""Forgot password and the web reset page (API_SPEC §2.4, §13.2; SECURITY §12; TEST_PLAN AUTH-*)."""

from __future__ import annotations

import hashlib
import re
from datetime import timedelta
from typing import Any

import httpx
import psycopg
import pytest
from sqlalchemy import event

from app.audit import writer as audit
from tests.support import NEW_PASSWORD, PASSWORD, Harness, asgi_post_events, bearer

Db = psycopg.Connection[dict[str, Any]]

NOISE_HEADERS = {
    "x-request-id",
    "ratelimit-limit",
    "ratelimit-remaining",
    "ratelimit-reset",
    "date",
}


def _stable(response: httpx.Response) -> tuple[int, tuple[tuple[str, str], ...], str]:
    headers = tuple(sorted((k, v) for k, v in response.headers.items() if k not in NOISE_HEADERS))
    return response.status_code, headers, response.text


def _snapshot(owner_db: Db) -> dict[str, list[dict[str, Any]]]:
    tables = ("users", "user_profiles", "sessions", "refresh_tokens", "auth_tokens", "audit_logs")
    return {
        t: owner_db.execute(f"SELECT * FROM {t} ORDER BY 1").fetchall()  # noqa: S608
        for t in tables
    }


# --- POST /v1/auth/password/forgot ------------------------------------------------------------


async def test_forgot_answers_identically_for_every_kind_of_address(h: Harness) -> None:
    await h.signup("known@example.com")
    assert (await h.register("pending@example.com")).status_code == 202  # never verified
    h.mail.clear()

    responses = {
        "verified": await h.forgot("known@example.com"),
        "verified_other_case": await h.forgot("  Known@Example.com "),
        "pending": await h.forgot("pending@example.com"),
        "unknown": await h.forgot("nobody@example.com"),
    }
    for name, response in responses.items():
        assert response.status_code == 202, name
        assert response.json() == {"status": "email_sent"}, name
        assert response.headers["content-type"] == "application/json", name
    # Same bytes, same headers (apart from per-request noise), whatever the address.
    assert len({_stable(r) for r in responses.values()}) == 1

    # Only the verified account gets mail, and the mail goes to its own address.
    assert [m.to for m in h.mail.messages] == ["known@example.com", "known@example.com"]
    assert {m.template for m in h.mail.messages} == {"password_reset_link"}


async def test_forgot_email_carries_a_fragment_link_and_stores_only_a_hash(
    h: Harness, owner_db: Db
) -> None:
    await h.signup("link@example.com")
    assert (await h.forgot("link@example.com")).status_code == 202

    message = h.mail.to("link@example.com", "password_reset_link")[0]
    token = h.reset_token_for("link@example.com")
    assert f"https://afterme.test/a/reset#{token}" in message.text
    assert re.fullmatch(r"pr_[A-Za-z0-9_-]{43}", token)  # 256 bits, URL-safe
    assert "30 minutes" in message.text

    rows = owner_db.execute(
        "SELECT purpose, kind, secret_hash, payload, attempts, expires_at, used_at, created_at "
        "FROM auth_tokens WHERE purpose = 'password_reset'"
    ).fetchall()
    assert len(rows) == 1
    row = rows[0]
    assert (row["kind"], row["used_at"], row["payload"]) == ("link", None, None)
    assert bytes(row["secret_hash"]) == hashlib.sha256(token.encode()).digest()
    assert token.encode() not in bytes(row["secret_hash"])
    assert row["expires_at"] - row["created_at"] == timedelta(minutes=30)
    assert row["created_at"] == h.clock.current


async def test_forgot_does_the_same_work_for_known_and_unknown_accounts(
    h: Harness, owner_db: Db, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Wall-clock timing is too noisy to assert on; instead every branch must generate and hash
    exactly one token, render exactly one email, and run the same statements."""
    await h.signup("work@example.com")
    assert (await h.register("half@example.com")).status_code == 202
    h.mail.clear()

    generated: list[str] = []
    rendered: list[str] = []
    from app.auth import account_service

    real_token = account_service.new_reset_token

    def spy_token() -> str:
        token = real_token()
        generated.append(token)
        return token

    monkeypatch.setattr(account_service, "new_reset_token", spy_token)
    mailer = h.app.state.services.mailer
    real_render = mailer.render

    def spy_render(template: Any, **kwargs: Any) -> Any:
        rendered.append(template.value)
        return real_render(template, **kwargs)

    monkeypatch.setattr(mailer, "render", spy_render)

    statements: list[str] = []

    @event.listens_for(h.app.state.services.db.engine.sync_engine, "before_cursor_execute")
    def record(_c: Any, _cur: Any, statement: str, *_a: Any) -> None:
        table = re.search(r"(?:FROM|INTO|UPDATE)\s+(\w+)", statement)
        statements.append(f"{statement.split(maxsplit=1)[0].upper()} {table[1] if table else '?'}")

    work: dict[str, tuple[int, list[str], list[str]]] = {}
    for name, address in (
        ("known", "work@example.com"),
        ("unknown", "nobody@example.com"),
        ("pending", "half@example.com"),
    ):
        generated.clear()
        rendered.clear()
        statements.clear()
        assert (await h.forgot(address)).status_code == 202
        work[name] = (len(generated), list(rendered), list(statements))

    assert work["known"][0] == 1
    assert work["known"][1] == ["password_reset_link"]
    assert work["unknown"] == work["known"]
    assert work["pending"] == work["known"]
    # Only the known account left a token behind; the decoys inserted nothing.
    assert owner_db.execute(
        "SELECT count(*) AS n FROM auth_tokens WHERE kind='link'"
    ).fetchone() == {"n": 1}


async def test_forgot_audit_is_system_observed_and_holds_no_email(h: Harness, owner_db: Db) -> None:
    await h.signup("audit-forgot@example.com")
    await h.forgot("audit-forgot@example.com")
    await h.forgot("ghost@example.com")
    rows = owner_db.execute(
        "SELECT actor_type, subject_user_id, metadata, user_visible FROM audit_logs "
        "WHERE action = %s ORDER BY id",
        (audit.PASSWORD_RESET_REQUESTED,),
    ).fetchall()
    assert [r["metadata"] for r in rows] == [
        {"outcome": "link_sent"},
        {"outcome": "unknown_account"},
    ]
    assert {r["actor_type"] for r in rows} == {"system"}
    assert rows[0]["subject_user_id"] is not None
    assert rows[1]["subject_user_id"] is None
    assert not any(r["user_visible"] for r in rows)


async def test_forgot_rate_limit_per_email(h: Harness) -> None:
    for _ in range(3):
        assert (await h.forgot("limited@example.com")).status_code == 202
    blocked = await h.forgot("LIMITED@example.com")  # same address, different casing
    assert blocked.status_code == 429
    assert blocked.json()["code"] == "rate_limited"
    assert int(blocked.headers["retry-after"]) >= 1
    assert (await h.forgot("someone-else@example.com")).status_code == 202
    h.clock.advance(hours=1)
    assert (await h.forgot("limited@example.com")).status_code == 202


async def test_forgot_rate_limit_per_ip(h: Harness) -> None:
    for i in range(10):
        assert (await h.forgot(f"person{i}@example.com")).status_code == 202
    blocked = await h.forgot("person10@example.com")
    assert blocked.status_code == 429
    assert blocked.json()["code"] == "rate_limited"


@pytest.mark.no_rate_limit
@pytest.mark.parametrize(
    "body", [{}, {"email": "not an email"}, {"email": "a@example.com", "x": 1}]
)
async def test_forgot_validates_the_request(h: Harness, body: dict[str, Any]) -> None:
    response = await h.client.post("/v1/auth/password/forgot", json=body)
    assert response.status_code == 422
    assert response.json()["code"] == "validation_failed"


async def test_forgot_for_a_suspended_account_sends_nothing(h: Harness, owner_db: Db) -> None:
    await h.signup("suspended@example.com")
    owner_db.execute("UPDATE users SET status = 'suspended'")
    h.mail.clear()
    assert (await h.forgot("suspended@example.com")).status_code == 202
    assert h.mail.messages == []


async def test_a_new_link_invalidates_the_older_ones(h: Harness, owner_db: Db) -> None:
    await h.signup("twice@example.com")
    await h.forgot("twice@example.com")
    first = h.reset_token_for("twice@example.com")
    await h.forgot("twice@example.com")
    second = h.reset_token_for("twice@example.com")
    assert first != second

    stale = await h.web_reset(first, NEW_PASSWORD)
    assert stale.status_code == 400
    unused = owner_db.execute(
        "SELECT count(*) AS n FROM auth_tokens WHERE purpose='password_reset' AND used_at IS NULL"
    ).fetchone()
    assert unused == {"n": 1}
    assert (await h.web_reset(second, NEW_PASSWORD)).status_code == 200


async def test_link_expires_after_thirty_minutes(h: Harness) -> None:
    await h.signup("expiry@example.com")
    await h.forgot("expiry@example.com")
    token = h.reset_token_for("expiry@example.com")
    h.clock.advance(minutes=30)  # exactly the expiry instant: no longer valid
    assert (await h.web_reset(token, NEW_PASSWORD)).status_code == 400
    assert (await h.login("expiry@example.com", PASSWORD)).status_code == 200

    await h.forgot("expiry@example.com")
    fresh = h.reset_token_for("expiry@example.com")
    h.clock.advance(minutes=29, seconds=59)
    assert (await h.web_reset(fresh, NEW_PASSWORD)).status_code == 200


async def test_link_is_single_use(h: Harness, owner_db: Db) -> None:
    await h.signup("single@example.com")
    await h.forgot("single@example.com")
    token = h.reset_token_for("single@example.com")
    assert (await h.web_reset(token, NEW_PASSWORD)).status_code == 200
    again = await h.web_reset(token, "yet another passphrase 88")
    assert again.status_code == 400
    assert (await h.login("single@example.com", NEW_PASSWORD)).status_code == 200
    assert (await h.login("single@example.com", "yet another passphrase 88")).status_code == 401


# --- GET /a/reset -----------------------------------------------------------------------------


async def test_get_reset_renders_the_form_and_changes_nothing(h: Harness, owner_db: Db) -> None:
    await h.signup("getter@example.com")
    await h.forgot("getter@example.com")
    token = h.reset_token_for("getter@example.com")
    before = _snapshot(owner_db)

    plain = await h.client.get("/a/reset")
    with_query = await h.client.get("/a/reset", params={"token": token, "new_password": "x"})
    assert plain.status_code == with_query.status_code == 200
    assert plain.headers["content-type"].startswith("text/html")
    assert _snapshot(owner_db) == before  # a mail scanner opening the link changes nothing
    assert token not in plain.text
    assert token not in with_query.text  # a query string is never trusted or echoed

    # The form: POST to /a/reset, token field filled by the script from the fragment.
    assert '<form method="post" action="/a/reset"' in plain.text
    assert 'name="token"' in plain.text
    assert 'name="new_password"' in plain.text
    assert "location.hash" in plain.text or "window.location.hash" in plain.text
    assert "replaceState" in plain.text


async def test_get_reset_headers_and_cookie(h: Harness) -> None:
    first = await h.client.get("/a/reset")
    headers = first.headers
    csp = headers["content-security-policy"]
    nonce = re.search(r"script-src 'nonce-([A-Za-z0-9_-]{16,})'", csp)
    assert nonce is not None
    assert f'<script nonce="{nonce[1]}">' in first.text
    for directive in (
        "default-src 'none'",
        "style-src 'self'",
        "img-src 'self'",
        "form-action 'self'",
        "frame-ancestors 'none'",
        "base-uri 'none'",
    ):
        assert directive in csp
    assert "unsafe-inline" not in csp
    assert "unsafe-eval" not in csp
    assert headers["referrer-policy"] == "no-referrer"
    assert headers["cache-control"] == "no-store"
    assert headers["x-robots-tag"] == "noindex, nofollow"
    assert headers["x-content-type-options"] == "nosniff"
    assert headers["x-frame-options"] == "DENY"
    assert "permissions-policy" in headers

    # The nonce changes on every response.
    second = await h.client.get("/a/reset")
    other = re.search(r"'nonce-([^']+)'", second.headers["content-security-policy"])
    assert other is not None
    assert other[1] != nonce[1]

    cookie = first.headers["set-cookie"]
    assert cookie.startswith("__Host-afterme_csrf=")
    lowered = cookie.lower()
    assert "secure" in lowered
    assert "httponly" in lowered
    assert "samesite=strict" in lowered
    assert "path=/" in lowered
    assert "domain" not in lowered
    value = cookie.split(";")[0].split("=", 1)[1]
    assert f'name="csrf" value="{value}"' in first.text
    assert len(value) >= 32

    # No third-party anything: the only URL on the page is our own stylesheet and the form.
    assert not re.search(r"https?://", first.text)
    assert re.findall(r'(?:src|href|action)="([^"]*)"', first.text) == [
        "/a/assets/web.css",
        "/a/reset",
    ]
    assert "style=" not in first.text


async def test_reset_stylesheet_is_served(h: Harness) -> None:
    response = await h.client.get("/a/assets/web.css")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/css")
    assert "color-scheme" in response.text


# --- POST /a/reset ----------------------------------------------------------------------------


async def _prepare(h: Harness, email: str) -> tuple[dict[str, Any], str]:
    tokens = await h.signup(email)
    await h.forgot(email)
    return tokens, h.reset_token_for(email)


async def test_reset_success_changes_the_password_and_ends_every_session(
    h: Harness, owner_db: Db
) -> None:
    first, token = await _prepare(h, "reset@example.com")
    second = (await h.login("reset@example.com")).json()
    bystander = await h.signup("bystander@example.com")
    h.mail.clear()

    csrf = await h.web_form()
    response = await h.client.post(
        "/a/reset", data={"token": token, "new_password": NEW_PASSWORD, "csrf": csrf}
    )
    assert response.status_code == 200
    assert "password was changed" in response.text
    assert "sign in" in response.text.lower()
    assert NEW_PASSWORD not in response.text
    assert token not in response.text
    assert "max-age=0" in response.headers["set-cookie"].lower()  # CSRF cookie cleared

    # New password works, old one does not.
    assert (await h.login("reset@example.com", NEW_PASSWORD)).status_code == 200
    assert (await h.login("reset@example.com", PASSWORD)).status_code == 401
    # Every earlier session is gone; the refresh tokens too.
    for tokens in (first, second):
        gone = await h.client.get("/v1/me", headers=bearer(tokens))
        assert gone.status_code == 401
        assert gone.json()["code"] == "session_revoked"
        assert (await h.refresh(tokens["refresh_token"])).status_code == 401
    reasons = owner_db.execute(
        "SELECT revoke_reason, count(*) AS n FROM sessions WHERE user_id = %s::uuid "
        "GROUP BY revoke_reason ORDER BY 1 NULLS LAST",
        (first["user"]["id"],),
    ).fetchall()
    assert reasons == [{"revoke_reason": "password_reset", "n": 2}, {"revoke_reason": None, "n": 1}]
    # Somebody else's session is untouched.
    assert (await h.client.get("/v1/me", headers=bearer(bystander))).status_code == 200

    # Token consumed, mail sent, audit written and visible.
    used = owner_db.execute(
        "SELECT used_at FROM auth_tokens WHERE purpose='password_reset'"
    ).fetchone()
    assert used is not None
    assert used["used_at"] is not None
    completed = h.mail.to("reset@example.com", "password_reset_completed")
    assert len(completed) == 1
    assert "signed out" in completed[0].text
    assert NEW_PASSWORD not in completed[0].text
    row = owner_db.execute(
        "SELECT actor_type, user_visible, metadata FROM audit_logs WHERE action = %s",
        (audit.PASSWORD_RESET_COMPLETED,),
    ).fetchone()
    assert row == {"actor_type": "user", "user_visible": True, "metadata": {"sessions_revoked": 2}}


async def test_reset_clears_a_lockout_and_push_tokens(h: Harness, owner_db: Db) -> None:
    tokens, token = await _prepare(h, "locked@example.com")
    owner_db.execute(
        "UPDATE users SET failed_login_count = 4, locked_until = %s",
        (h.clock.current + timedelta(minutes=10),),
    )
    owner_db.execute("UPDATE devices SET push_token = 'fcm-token-1'")
    assert (await h.web_reset(token, NEW_PASSWORD)).status_code == 200
    user = owner_db.execute("SELECT failed_login_count, locked_until FROM users").fetchone()
    assert user == {"failed_login_count": 0, "locked_until": None}
    device = owner_db.execute(
        "SELECT push_token FROM devices WHERE id = %s::uuid", (tokens["device_id"],)
    ).fetchone()
    assert device == {"push_token": None}
    assert (await h.login("locked@example.com", NEW_PASSWORD)).status_code == 200


@pytest.mark.parametrize("variant", ["no_cookie", "wrong_field", "missing_field", "other_cookie"])
async def test_reset_csrf_failures_give_a_403_page_and_change_nothing(
    h: Harness, owner_db: Db, variant: str
) -> None:
    _, token = await _prepare(h, "csrf@example.com")
    csrf = await h.web_form()
    form = {"token": token, "new_password": NEW_PASSWORD, "csrf": csrf}
    if variant == "no_cookie":
        h.client.cookies.clear()
    elif variant == "wrong_field":
        form["csrf"] = csrf[::-1]
    elif variant == "missing_field":
        del form["csrf"]
    else:  # a cookie of the right shape that does not match the field
        h.client.cookies.clear()
        h.client.cookies.set("__Host-afterme_csrf", "x" * 43, domain="api.afterme.test")
    before = _snapshot(owner_db)

    response = await h.client.post("/a/reset", data=form)
    assert response.status_code == 403
    assert response.headers["content-type"].startswith("text/html")
    assert response.headers["cache-control"] == "no-store"
    assert "content-security-policy" in response.headers
    assert NEW_PASSWORD not in response.text
    assert token not in response.text
    assert _snapshot(owner_db) == before
    assert (await h.login("csrf@example.com", PASSWORD)).status_code == 200


async def test_reset_rejects_a_json_body_as_csrf_failure(h: Harness) -> None:
    _, token = await _prepare(h, "jsonbody@example.com")
    csrf = await h.web_form()
    response = await h.client.post(
        "/a/reset", json={"token": token, "new_password": NEW_PASSWORD, "csrf": csrf}
    )
    assert response.status_code == 403
    assert (await h.login("jsonbody@example.com", PASSWORD)).status_code == 200


async def test_reset_takes_the_token_from_the_body_never_the_url(h: Harness) -> None:
    _, token = await _prepare(h, "bodyonly@example.com")
    csrf = await h.web_form()
    response = await h.client.post(
        f"/a/reset?token={token}", data={"new_password": NEW_PASSWORD, "csrf": csrf}
    )
    assert response.status_code == 400
    assert (await h.login("bodyonly@example.com", PASSWORD)).status_code == 200


@pytest.mark.parametrize(
    ("password", "message"),
    [
        ("short", "at least 10"),
        ("x" * 129, "at most 128"),
        ("password123", "too common"),
        ("policy@example.com", "email address"),
        ("policy", "at least 10"),
    ],
)
async def test_reset_policy_failures_reshow_the_form_and_keep_the_link(
    h: Harness, password: str, message: str
) -> None:
    await h.signup("policy@example.com")
    await h.forgot("policy@example.com")
    token = h.reset_token_for("policy@example.com")

    response = await h.web_reset(token, password)
    assert response.status_code == 422
    assert message in response.text
    assert 'name="new_password"' in response.text
    assert f'name="token" id="token" value="{token}"' in response.text  # form is reusable
    assert password not in response.text or password == "policy"  # the password is not echoed
    assert (await h.login("policy@example.com", PASSWORD)).status_code == 200  # unchanged
    # The same link still works with an acceptable password.
    assert (await h.web_reset(token, NEW_PASSWORD)).status_code == 200


async def test_reset_with_the_local_part_of_the_email_is_rejected(h: Harness) -> None:
    await h.signup("localpartuser@example.com")
    await h.forgot("localpartuser@example.com")
    token = h.reset_token_for("localpartuser@example.com")
    response = await h.web_reset(token, "localpartuser")
    assert response.status_code == 422


async def test_reset_invalid_tokens_all_look_the_same(h: Harness, owner_db: Db) -> None:
    await h.signup("generic@example.com")
    await h.forgot("generic@example.com")
    expired = h.reset_token_for("generic@example.com")
    h.clock.advance(minutes=31)
    await h.forgot("generic@example.com")
    used = h.reset_token_for("generic@example.com")
    assert (await h.web_reset(used, NEW_PASSWORD)).status_code == 200

    candidates = {
        "expired": expired,
        "used": used,
        "unknown": "pr_" + "A" * 43,
        "malformed": "not-a-token",
        "empty": "",
        "oversized": "pr_" + "A" * 5000,
    }
    pages: dict[str, httpx.Response] = {}
    for name, value in candidates.items():
        pages[name] = await h.web_reset(value, NEW_PASSWORD)
        assert pages[name].status_code == 400, name
    assert len({r.text for r in pages.values()}) == 1  # nothing distinguishes the causes
    page = pages["unknown"]
    assert "get a new link" in page.text
    assert "Forgot password" in page.text
    assert "generic@example.com" not in page.text
    assert "AfterMe app" in page.text
    # And an address that never had an account cannot be probed this way either.
    assert "exist" not in page.text.lower().replace("nothing has changed", "")


async def test_reset_for_a_deleted_or_suspended_account_is_the_generic_page(
    h: Harness, owner_db: Db
) -> None:
    _, token = await _prepare(h, "gone@example.com")
    owner_db.execute("UPDATE users SET status = 'suspended'")
    response = await h.web_reset(token, NEW_PASSWORD)
    assert response.status_code == 400
    assert owner_db.execute(
        "SELECT used_at FROM auth_tokens WHERE purpose = 'password_reset'"
    ).fetchone() == {"used_at": None}


async def test_reset_rate_limit_per_ip(h: Harness) -> None:
    csrf = await h.web_form()
    for _ in range(10):
        response = await h.client.post(
            "/a/reset", data={"token": "pr_" + "B" * 43, "new_password": NEW_PASSWORD, "csrf": csrf}
        )
        assert response.status_code == 400
    blocked = await h.client.post(
        "/a/reset", data={"token": "pr_" + "B" * 43, "new_password": NEW_PASSWORD, "csrf": csrf}
    )
    assert blocked.status_code == 429
    assert int(blocked.headers["retry-after"]) >= 1
    assert blocked.headers["content-type"].startswith("text/html")
    assert "content-security-policy" in blocked.headers
    h.clock.advance(hours=1)
    assert (
        await h.client.post(
            "/a/reset", data={"token": "pr_" + "B" * 43, "new_password": NEW_PASSWORD, "csrf": csrf}
        )
    ).status_code == 400


async def test_reset_of_the_other_users_link_cannot_touch_this_account(h: Harness) -> None:
    await h.signup("victim@example.com")
    await h.signup("attacker@example.com")
    await h.forgot("attacker@example.com")
    token = h.reset_token_for("attacker@example.com")
    assert (await h.web_reset(token, NEW_PASSWORD)).status_code == 200
    assert (await h.login("victim@example.com", PASSWORD)).status_code == 200
    assert (await h.login("attacker@example.com", NEW_PASSWORD)).status_code == 200


async def test_concurrent_resets_with_one_link_succeed_exactly_once(h: Harness) -> None:
    import asyncio

    await h.signup("race-reset@example.com")
    await h.forgot("race-reset@example.com")
    token = h.reset_token_for("race-reset@example.com")
    csrf = await h.web_form()
    results = await asyncio.gather(
        h.web_reset(token, NEW_PASSWORD, csrf), h.web_reset(token, "a rival passphrase 91", csrf)
    )
    assert sorted(r.status_code for r in results) == [200, 400]
    winner = NEW_PASSWORD if results[0].status_code == 200 else "a rival passphrase 91"
    assert (await h.login("race-reset@example.com", winner)).status_code == 200


async def test_reset_with_an_undecodable_body_is_a_csrf_failure(h: Harness) -> None:
    await h.web_form()
    response = await h.client.post(
        "/a/reset",
        content=b"token=\xff\xfe&new_password=\xff",
        headers={"content-type": "application/x-www-form-urlencoded"},
    )
    assert response.status_code == 403


async def test_forgot_sends_its_mail_only_after_the_response_has_been_produced(
    h: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    await h.signup("after-response-reset@example.com")
    events = await asgi_post_events(
        h,
        monkeypatch,
        "/v1/auth/password/forgot",
        {"email": "after-response-reset@example.com"},
        {},
    )
    assert events.index("deliver") > events.index("response_end")


async def test_reset_invalidates_a_pending_email_change_code(h: Harness) -> None:
    tokens, link = await _prepare(h, "pending-change@example.com")
    assert (await h.reauth(tokens)).status_code == 204
    started = await h.client.post(
        "/v1/auth/email/change/start",
        json={"new_email": "pending-change-new@example.com"},
        headers=bearer(tokens),
    )
    assert started.status_code == 202
    messages = h.mail.to("pending-change-new@example.com", "email_change_code")
    code = re.search(r"\b(\d{6})\b", messages[-1].text)
    assert code is not None

    assert (await h.web_reset(link, NEW_PASSWORD)).status_code == 200
    fresh = (await h.login("pending-change@example.com", NEW_PASSWORD)).json()
    verify = await h.client.post(
        "/v1/auth/email/change/verify", json={"code": code[1]}, headers=bearer(fresh)
    )
    assert verify.status_code == 400
    assert verify.json()["code"] == "invalid_code"
    me = (await h.client.get("/v1/me", headers=bearer(fresh))).json()
    assert me["email"] == "pending-change@example.com"


async def test_a_failing_email_provider_does_not_fail_forgot_or_reset(h: Harness) -> None:
    await h.signup("mailfail-reset@example.com")
    h.mail.fail_next = True
    assert (await h.forgot("mailfail-reset@example.com")).status_code == 202
    assert h.mail.messages == [] or all(
        m.template != "password_reset_link" for m in h.mail.messages
    )

    # The first link never went out; ask again and reset while the completion mail fails.
    assert (await h.forgot("mailfail-reset@example.com")).status_code == 202
    token = h.reset_token_for("mailfail-reset@example.com")
    h.mail.fail_next = True
    response = await h.web_reset(token, NEW_PASSWORD)
    assert response.status_code == 200
    assert "password was changed" in response.text
    assert (await h.login("mailfail-reset@example.com", NEW_PASSWORD)).status_code == 200
