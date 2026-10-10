"""Audit trail (SECURITY §9; TEST_PLAN AUD-*)."""

from __future__ import annotations

import json
import uuid
from datetime import UTC, datetime
from typing import Any

import psycopg
import pytest

from app.audit.writer import AuditEvent, AuditMetadataError, validate_metadata
from tests.support import PASSWORD, Harness, bearer

Db = psycopg.Connection[dict[str, Any]]

FORBIDDEN_FRAGMENTS = ("password", "token", "code", "email", "@", "otp", "secret")


async def test_full_flow_writes_the_expected_trail(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("trail@example.com")
    await h.login("trail@example.com", "wrong password for audit")
    second = (await h.login("trail@example.com", device_id=tokens["device_id"])).json()
    third = (await h.login("trail@example.com")).json()
    await h.reauth(second, "wrong password for audit")
    await h.reauth(second)
    await h.client.delete(f"/v1/auth/sessions/{third['session_id']}", headers=bearer(second))
    await h.client.post("/v1/auth/logout", headers=bearer(second))
    fourth = (await h.login("trail@example.com")).json()
    await h.client.post("/v1/auth/logout-all", headers=bearer(fourth))

    rows = owner_db.execute(
        "SELECT action, user_visible, actor_type, metadata, request_id, ip_hash, "
        "subject_user_id::text AS subject FROM audit_logs ORDER BY id"
    ).fetchall()
    assert [(r["action"], r["user_visible"]) for r in rows] == [
        ("auth.signup_started", False),
        ("auth.signup_verified", False),
        ("auth.login_failed", False),
        ("auth.login_succeeded", False),  # known device
        ("auth.login_succeeded", True),  # new device is shown in the Activity feed
        ("auth.reauth_failed", False),
        ("auth.reauth_succeeded", False),
        ("session.revoked", False),
        ("auth.logout", False),
        ("auth.login_succeeded", True),
        ("auth.logout_all", True),
    ]
    user_id = tokens["user"]["id"]
    assert {r["subject"] for r in rows} == {user_id}
    # Callers who have not authenticated yet are never recorded as the account owner.
    unauthenticated = {"auth.signup_started", "auth.login_failed"}
    assert {r["action"] for r in rows if r["actor_type"] == "system"} == unauthenticated
    assert all(r["actor_type"] == "user" for r in rows if r["action"] not in unauthenticated)
    assert all(r["request_id"] and r["ip_hash"] for r in rows)
    for row in rows:
        text = json.dumps(row["metadata"]).lower()
        assert PASSWORD not in text
        assert "trail@example.com" not in text
        for key in row["metadata"]:
            assert not any(f in key for f in FORBIDDEN_FRAGMENTS), key


async def test_unknown_account_failure_has_no_subject(h: Harness, owner_db: Db) -> None:
    await h.login("ghost@example.com", "anything at all here")
    row = owner_db.execute("SELECT * FROM audit_logs").fetchone()
    assert row is not None
    assert row["subject_user_id"] is None
    assert row["actor_type"] == "system"
    assert row["actor_id"] is None
    assert row["metadata"] == {"reason": "unknown_account"}


async def test_failed_login_and_lockout_are_not_attributed_to_the_account_owner(
    h: Harness, owner_db: Db
) -> None:
    tokens = await h.signup("victim@example.com")
    for _ in range(10):
        h.clock.advance(minutes=15)  # keep clear of the per-account rate limit window
        assert (await h.login("victim@example.com", "attacker guess here")).status_code == 401
    rows = owner_db.execute(
        "SELECT action, actor_type, actor_id, subject_user_id::text AS subject FROM audit_logs "
        "WHERE action IN ('auth.login_failed', 'auth.locked')"
    ).fetchall()
    assert {r["action"] for r in rows} == {"auth.login_failed", "auth.locked"}
    for row in rows:
        assert row["actor_type"] == "system"
        assert row["actor_id"] is None
        assert row["subject"] == tokens["user"]["id"]  # the affected account stays the subject
    started = await h.register("victim@example.com")  # another person's signup attempt
    assert started.status_code == 202
    attempt = owner_db.execute(
        "SELECT actor_type, actor_id FROM audit_logs WHERE action = 'auth.signup_started' "
        "ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert attempt == {"actor_type": "system", "actor_id": None}


async def test_failed_attempt_audit_survives_the_error_response(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("survive@example.com")
    owner_db.execute("TRUNCATE audit_logs")
    assert (await h.reauth(tokens, "definitely wrong pw")).status_code == 401
    assert [r["action"] for r in owner_db.execute("SELECT action FROM audit_logs").fetchall()] == [
        "auth.reauth_failed"
    ]


def test_metadata_validation_rejects_sensitive_content() -> None:
    assert validate_metadata({"reason": "bad_password", "count": 3, "ok": True, "x": None}) == {
        "reason": "bad_password",
        "count": 3,
        "ok": True,
        "x": None,
    }
    ident = uuid.uuid4()
    assert validate_metadata({"device_id": ident}) == {"device_id": str(ident)}
    for bad in (
        {"email": "a@b.c"},
        {"user_email_hash": "x"},
        {"password": "x"},
        {"refresh_token": "x"},
        {"code": "123456"},
        {"display_name": "Bob"},
        {"ip": "1.2.3.4"},
        {"Reason": "x"},
        {"reason": "contains spaces and @"},
        {"reason": "x" * 65},
        {"nested": {"a": 1}},
        {"floaty": 1.5},
    ):
        with pytest.raises(AuditMetadataError):
            validate_metadata(bad)


def test_unknown_actions_are_rejected() -> None:
    event = AuditEvent(
        action="auth.something_new", occurred_at=datetime.now(UTC), subject_user_id=None
    )
    with pytest.raises(AuditMetadataError):
        event.to_row()
