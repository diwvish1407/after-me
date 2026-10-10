"""Refresh-token rotation, retry grace and reuse detection (DATABASE §3.1; SEC-07)."""

from __future__ import annotations

from datetime import timedelta
from typing import Any

import psycopg

from tests.support import Harness, bearer, problem

Db = psycopg.Connection[dict[str, Any]]


async def test_rotation_issues_a_new_pair_and_slides_idle_expiry(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("rotate@example.com")
    h.clock.advance(days=10)
    response = await h.refresh(tokens["refresh_token"])
    assert response.status_code == 200
    body = response.json()
    assert set(body) == {"access_token", "access_token_expires_at", "refresh_token"}
    assert body["refresh_token"] != tokens["refresh_token"]
    assert body["access_token"] != tokens["access_token"]

    session = owner_db.execute(
        "SELECT * FROM sessions WHERE id = %s", (tokens["session_id"],)
    ).fetchone()
    assert session is not None
    assert session["idle_expires_at"] == h.clock.current + timedelta(days=60)
    assert session["last_used_at"] == h.clock.current
    rows = owner_db.execute(
        "SELECT id, used_at, replaced_by FROM refresh_tokens ORDER BY issued_at"
    ).fetchall()
    assert len(rows) == 2
    assert rows[0]["used_at"] == h.clock.current
    assert rows[0]["replaced_by"] == rows[1]["id"]
    assert rows[1]["used_at"] is None

    # The new access token works; the new refresh token rotates again.
    assert (await h.client.get("/v1/me", headers=bearer(body))).status_code == 200
    h.clock.advance(minutes=1)
    assert (await h.refresh(body["refresh_token"])).status_code == 200


async def test_idle_expiry_is_capped_by_absolute_expiry(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("cap@example.com")
    current = tokens["refresh_token"]
    for _ in range(6):  # 6 × 59 days = 354 days
        h.clock.advance(days=59)
        response = await h.refresh(current)
        assert response.status_code == 200
        current = response.json()["refresh_token"]
    session = owner_db.execute(
        "SELECT idle_expires_at, absolute_expires_at FROM sessions"
    ).fetchone()
    assert session is not None
    assert session["idle_expires_at"] == session["absolute_expires_at"]
    h.clock.advance(days=11)  # day 365: the absolute limit
    assert (await h.refresh(current)).status_code == 401


async def test_network_retry_within_grace_gets_a_fresh_successor(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("retry@example.com")
    first = await h.refresh(tokens["refresh_token"])
    assert first.status_code == 200
    lost_successor = first.json()["refresh_token"]

    h.clock.advance(seconds=30)
    retry = await h.refresh(tokens["refresh_token"])
    assert retry.status_code == 200
    new_successor = retry.json()["refresh_token"]
    assert new_successor not in (lost_successor, tokens["refresh_token"])

    # The lost successor was invalidated; the session is intact.
    assert (await h.refresh(lost_successor)).status_code == 401
    session = owner_db.execute(
        "SELECT revoked_at FROM sessions WHERE id = %s", (tokens["session_id"],)
    ).fetchone()
    assert session == {"revoked_at": None}
    assert (await h.refresh(new_successor)).status_code == 200
    assert owner_db.execute(
        "SELECT count(*) AS n FROM audit_logs WHERE action = 'auth.refresh_reuse_detected'"
    ).fetchone() == {"n": 0}
    assert h.mail.to("retry@example.com", "refresh_reuse_detected") == []  # a retry is not theft


async def test_reuse_after_grace_revokes_the_session(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("theft@example.com")
    rotated = await h.refresh(tokens["refresh_token"])
    assert rotated.status_code == 200

    h.clock.advance(seconds=31)
    stolen = await h.refresh(tokens["refresh_token"])
    assert stolen.status_code == 401
    assert problem(stolen)["code"] == "session_revoked"

    session = owner_db.execute(
        "SELECT revoked_at, revoke_reason FROM sessions WHERE id = %s", (tokens["session_id"],)
    ).fetchone()
    assert session == {"revoked_at": h.clock.current, "revoke_reason": "reuse_detected"}
    audit = owner_db.execute(
        "SELECT user_visible, resource_id::text AS rid FROM audit_logs "
        "WHERE action = 'auth.refresh_reuse_detected'"
    ).fetchall()
    assert audit == [{"user_visible": True, "rid": tokens["session_id"]}]

    # SEC-07: the owner is told out-of-band, once, and the email carries no token or address
    # beyond the recipient.
    alerts = h.mail.to("theft@example.com", "refresh_reuse_detected")
    assert len(alerts) == 1
    assert tokens["refresh_token"] not in alerts[0].text
    assert rotated.json()["refresh_token"] not in alerts[0].text
    assert (await h.refresh(tokens["refresh_token"])).status_code == 401
    assert len(h.mail.to("theft@example.com", "refresh_reuse_detected")) == 1  # not repeated

    # Everything from that session is dead now, including the legitimate successor.
    assert (await h.refresh(rotated.json()["refresh_token"])).status_code == 401
    me = await h.client.get("/v1/me", headers=bearer(rotated.json()))
    assert me.status_code == 401
    assert problem(me)["code"] == "session_revoked"


async def test_reuse_when_successor_already_used_revokes_even_within_grace(h: Harness) -> None:
    tokens = await h.signup("both@example.com")
    first = (await h.refresh(tokens["refresh_token"])).json()
    assert (await h.refresh(first["refresh_token"])).status_code == 200
    h.clock.advance(seconds=5)
    assert (await h.refresh(tokens["refresh_token"])).status_code == 401
    assert (await h.client.get("/v1/me", headers=bearer(first))).status_code == 401


async def test_unknown_or_malformed_refresh_tokens(h: Harness) -> None:
    await h.signup("unknown@example.com")
    for token in ("rt_doesnotexist0000000000000000000000000000", "garbage", "rt_"):
        response = await h.refresh(token)
        assert response.status_code == 401
        assert problem(response)["code"] == "session_revoked"


async def test_refresh_fails_for_revoked_or_idle_expired_sessions(h: Harness) -> None:
    logged_out = await h.signup("out@example.com")
    assert (await h.client.post("/v1/auth/logout", headers=bearer(logged_out))).status_code == 204
    assert (await h.refresh(logged_out["refresh_token"])).status_code == 401

    idle = await h.login("out@example.com")
    h.clock.advance(days=60)
    assert (await h.refresh(idle.json()["refresh_token"])).status_code == 401


async def test_refresh_fails_for_suspended_user(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("susp@example.com")
    owner_db.execute("UPDATE users SET status = 'suspended'")
    assert (await h.refresh(tokens["refresh_token"])).status_code == 401
