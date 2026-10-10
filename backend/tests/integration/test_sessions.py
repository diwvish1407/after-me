"""Session checks, logout, logout-all, reauth, sessions list/revoke, /me."""

from __future__ import annotations

import uuid
from datetime import timedelta
from typing import Any

import psycopg

from tests.support import Harness, bearer, problem

Db = psycopg.Connection[dict[str, Any]]


async def test_me(h: Harness) -> None:
    tokens = await h.signup("me@example.com")
    response = await h.client.get("/v1/me", headers=bearer(tokens))
    assert response.status_code == 200
    assert response.json() == {
        "id": tokens["user"]["id"],
        "email": "me@example.com",
        "tier": "free",
        "status": "active",
        "profile": {
            "display_name": "Test User",
            "phone_e164": None,
            "country_code": None,
            "timezone": "Asia/Kolkata",
            "locale": "en",
        },
        "created_at": "2026-10-08T09:00:00Z",
    }


async def test_expired_access_token_is_token_expired(h: Harness) -> None:
    tokens = await h.signup("expiry@example.com")
    h.clock.advance(seconds=899)
    assert (await h.client.get("/v1/me", headers=bearer(tokens))).status_code == 200
    h.clock.advance(seconds=1)
    response = await h.client.get("/v1/me", headers=bearer(tokens))
    assert response.status_code == 401
    assert problem(response)["code"] == "token_expired"
    assert response.headers["www-authenticate"] == "Bearer"


async def test_missing_and_malformed_authorization(h: Harness) -> None:
    tokens = await h.signup("hdr@example.com")
    for headers in (
        {},
        {"Authorization": ""},
        {"Authorization": "Basic abc"},
        {"Authorization": "Bearer"},
        {"Authorization": "Bearer not-a-jwt"},
        {"Authorization": "Bearer " + "x" * 5000},
        {"Authorization": tokens["access_token"]},
    ):
        response = await h.client.get("/v1/me", headers=headers)
        assert response.status_code == 401, headers
        assert problem(response)["code"] == "unauthenticated"
    lower = await h.client.get(
        "/v1/me", headers={"Authorization": f"bearer {tokens['access_token']}"}
    )
    assert lower.status_code == 200


async def test_session_must_belong_to_the_token_subject(h: Harness, owner_db: Db) -> None:
    a = await h.signup("a@example.com")
    b = await h.signup("b@example.com")
    # Point A's session at B: the token's (sub, sid) pair no longer matches any session.
    owner_db.execute(
        "UPDATE sessions SET user_id = %s WHERE id = %s", (b["user"]["id"], a["session_id"])
    )
    response = await h.client.get("/v1/me", headers=bearer(a))
    assert response.status_code == 401
    assert problem(response)["code"] == "session_revoked"


async def test_last_used_at_updates_at_most_every_five_minutes(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("touch@example.com")
    created = h.clock.current

    def last_used() -> Any:
        row = owner_db.execute(
            "SELECT last_used_at FROM sessions WHERE id = %s", (tokens["session_id"],)
        ).fetchone()
        assert row is not None
        return row["last_used_at"]

    h.clock.advance(minutes=4, seconds=59)
    await h.client.get("/v1/me", headers=bearer(tokens))
    assert last_used() == created
    h.clock.advance(seconds=1)
    await h.client.get("/v1/me", headers=bearer(tokens))
    assert last_used() == created + timedelta(minutes=5)


async def test_logout_revokes_this_session_and_clears_push_token(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("logout@example.com")
    other = (await h.login("logout@example.com")).json()
    owner_db.execute(
        "UPDATE devices SET push_token = 'fcm-token-1' WHERE id = %s", (tokens["device_id"],)
    )
    response = await h.client.post("/v1/auth/logout", headers=bearer(tokens))
    assert response.status_code == 204
    assert response.content == b""

    session = owner_db.execute(
        "SELECT revoke_reason FROM sessions WHERE id = %s", (tokens["session_id"],)
    ).fetchone()
    assert session == {"revoke_reason": "logout"}
    device = owner_db.execute(
        "SELECT push_token, push_token_updated_at FROM devices WHERE id = %s",
        (tokens["device_id"],),
    ).fetchone()
    assert device == {"push_token": None, "push_token_updated_at": h.clock.current}
    assert (await h.client.get("/v1/me", headers=bearer(tokens))).status_code == 401
    assert (await h.client.get("/v1/me", headers=bearer(other))).status_code == 200


async def test_logout_all_revokes_every_session(h: Harness, owner_db: Db) -> None:
    first = await h.signup("all@example.com")
    second = (await h.login("all@example.com")).json()
    third = (await h.login("all@example.com")).json()
    owner_db.execute("UPDATE devices SET push_token = 'tok-' || id::text")
    response = await h.client.post("/v1/auth/logout-all", headers=bearer(second))
    assert response.status_code == 204
    for tokens in (first, second, third):
        assert (await h.client.get("/v1/me", headers=bearer(tokens))).status_code == 401
        assert (await h.refresh(tokens["refresh_token"])).status_code == 401
    reasons = owner_db.execute("SELECT DISTINCT revoke_reason FROM sessions").fetchall()
    assert reasons == [{"revoke_reason": "logout_all"}]
    assert owner_db.execute(
        "SELECT count(*) AS n FROM devices WHERE push_token IS NOT NULL"
    ).fetchone() == {"n": 0}
    audit = owner_db.execute(
        "SELECT user_visible, metadata FROM audit_logs WHERE action = 'auth.logout_all'"
    ).fetchall()
    assert audit == [{"user_visible": True, "metadata": {"sessions_revoked": 3}}]
    notices = h.mail.to("all@example.com", "sessions_revoked")
    assert len(notices) == 1
    assert "3 in total" in notices[0].text
    # Logging out of one session is the user's own routine action: no security email.
    other = await h.signup("single@example.com")
    assert (await h.client.post("/v1/auth/logout", headers=bearer(other))).status_code == 204
    assert h.mail.to("single@example.com", "sessions_revoked") == []


async def test_reauth_window(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("reauth@example.com")
    protected = "/v1/_test/reauth"

    before = await h.client.get(protected, headers=bearer(tokens))
    assert before.status_code == 403
    assert problem(before)["code"] == "reauth_required"

    assert (await h.reauth(tokens)).status_code == 204
    session = owner_db.execute(
        "SELECT reauthenticated_at FROM sessions WHERE id = %s", (tokens["session_id"],)
    ).fetchone()
    assert session == {"reauthenticated_at": h.clock.current}

    h.clock.advance(minutes=4, seconds=59)
    assert (await h.client.get(protected, headers=bearer(tokens))).status_code == 204
    h.clock.advance(seconds=1)  # exactly 5:00 is still inside the window
    assert (await h.client.get(protected, headers=bearer(tokens))).status_code == 204

    h.clock.advance(seconds=1)  # 5:01
    late = await h.client.get(protected, headers=bearer(tokens))
    assert late.status_code == 403
    assert problem(late)["code"] == "reauth_required"


async def test_reauth_is_per_session(h: Harness) -> None:
    first = await h.signup("per@example.com")
    second = (await h.login("per@example.com")).json()
    assert (await h.reauth(first)).status_code == 204
    assert (await h.client.get("/v1/_test/reauth", headers=bearer(first))).status_code == 204
    assert (await h.client.get("/v1/_test/reauth", headers=bearer(second))).status_code == 403


async def test_reauth_wrong_password_is_rejected_and_audited(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("badre@example.com")
    response = await h.reauth(tokens, "not my password at all")
    assert response.status_code == 401
    assert problem(response)["code"] == "invalid_credentials"
    assert (await h.client.get("/v1/_test/reauth", headers=bearer(tokens))).status_code == 403
    audit = owner_db.execute(
        "SELECT metadata FROM audit_logs WHERE action = 'auth.reauth_failed'"
    ).fetchall()
    assert audit == [{"metadata": {"reason": "bad_password"}}]


async def test_sessions_list_marks_current(h: Harness) -> None:
    first = await h.signup("list@example.com")
    h.clock.advance(minutes=10)
    second = (await h.login("list@example.com")).json()
    response = await h.client.get("/v1/auth/sessions", headers=bearer(second))
    assert response.status_code == 200
    items = response.json()["items"]
    assert [i["id"] for i in items] == [second["session_id"], first["session_id"]]
    assert [i["current"] for i in items] == [True, False]
    assert items[0]["device"] == {"platform": "android", "app_version": "1.0.0+12"}
    assert items[0]["kind"] == "app"
    assert items[1]["created_at"] == "2026-10-08T09:00:00Z"


async def test_revoke_own_session(h: Harness, owner_db: Db) -> None:
    first = await h.signup("rev@example.com")
    second = (await h.login("rev@example.com")).json()
    response = await h.client.delete(
        f"/v1/auth/sessions/{first['session_id']}", headers=bearer(second)
    )
    assert response.status_code == 204
    assert (await h.client.get("/v1/me", headers=bearer(first))).status_code == 401
    listed = await h.client.get("/v1/auth/sessions", headers=bearer(second))
    assert [i["id"] for i in listed.json()["items"]] == [second["session_id"]]
    again = await h.client.delete(
        f"/v1/auth/sessions/{first['session_id']}", headers=bearer(second)
    )
    assert again.status_code == 404
    audit = owner_db.execute(
        "SELECT resource_id::text AS rid FROM audit_logs WHERE action = 'session.revoked'"
    ).fetchall()
    assert audit == [{"rid": first["session_id"]}]


async def test_revoke_other_users_or_unknown_session_is_404(h: Harness, owner_db: Db) -> None:
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    for target in (alice["session_id"], str(uuid.uuid4())):
        response = await h.client.delete(f"/v1/auth/sessions/{target}", headers=bearer(bob))
        assert response.status_code == 404
        assert problem(response)["code"] == "not_found"
    assert (await h.client.get("/v1/me", headers=bearer(alice))).status_code == 200
    malformed = await h.client.delete("/v1/auth/sessions/not-a-uuid", headers=bearer(bob))
    assert malformed.status_code == 422
