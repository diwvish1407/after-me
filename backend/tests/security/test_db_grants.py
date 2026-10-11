"""Database role privileges (DATABASE §6; TEST_PLAN SEC-18).

The API connects as ``afterme_api``. It must not be able to rewrite history (UPDATE/DELETE/
TRUNCATE on ``audit_logs``) or change the schema (no DDL, no temporary tables).
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import psycopg
import pytest

from app.models import PHASE1_TABLES
from tests.support import API_PASSWORD, WORKER_PASSWORD, connect

Conn = psycopg.Connection[dict[str, Any]]


@pytest.fixture
def api(migrated_database: str) -> Iterator[Conn]:
    with connect("afterme_api", API_PASSWORD, migrated_database) as conn:
        yield conn


@pytest.fixture
def worker(migrated_database: str) -> Iterator[Conn]:
    with connect("afterme_worker", WORKER_PASSWORD, migrated_database) as conn:
        yield conn


def _denied(conn: Conn, statement: str) -> None:
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        conn.execute(statement)


INSERT_AUDIT = "INSERT INTO audit_logs (actor_type, action) VALUES ('system', 'auth.logout')"


@pytest.mark.parametrize("role", ["api", "worker"])
def test_audit_logs_are_append_only(role: str, request: pytest.FixtureRequest) -> None:
    conn: Conn = request.getfixturevalue(role)
    conn.execute(INSERT_AUDIT)
    assert conn.execute("SELECT count(*) AS n FROM audit_logs").fetchone() == {"n": 1}
    _denied(conn, "UPDATE audit_logs SET action = 'tampered'")
    _denied(conn, "DELETE FROM audit_logs")
    _denied(conn, "TRUNCATE audit_logs")


@pytest.mark.parametrize("role", ["api", "worker"])
def test_no_ddl_rights(role: str, request: pytest.FixtureRequest) -> None:
    conn: Conn = request.getfixturevalue(role)
    _denied(conn, "CREATE TABLE public.sneaky (id int)")
    _denied(conn, "CREATE TEMPORARY TABLE sneaky_tmp (id int)")
    _denied(conn, "CREATE SCHEMA sneaky")
    _denied(conn, "ALTER TABLE users ADD COLUMN sneaky text")
    _denied(conn, "DROP TABLE rate_limit_counters")
    _denied(conn, "CREATE INDEX sneaky_ix ON users (email)")
    _denied(conn, "TRUNCATE users")


def test_api_has_dml_on_phase1_tables(api: Conn) -> None:
    for table in PHASE1_TABLES:
        privileges = {
            p: api.execute(
                "SELECT has_table_privilege(current_user, %s, %s) AS ok", (table, p)
            ).fetchone()["ok"]  # type: ignore[index]
            for p in ("SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER")
        }
        expected_dml = table != "audit_logs"
        assert privileges["SELECT"], table
        assert privileges["INSERT"], table
        assert privileges["UPDATE"] is expected_dml, table
        assert privileges["DELETE"] is expected_dml, table
        assert not privileges["TRUNCATE"], table
        assert not privileges["REFERENCES"], table
        assert not privileges["TRIGGER"], table


def test_api_can_read_the_migration_version(api: Conn) -> None:
    assert api.execute("SELECT count(*) AS n FROM alembic_version").fetchone() == {"n": 1}
    _denied(api, "UPDATE alembic_version SET version_num = 'x'")


def test_maintenance_role_may_purge_audit_logs(owner_db: Conn) -> None:
    def privilege(table: str, kind: str) -> bool:
        row = owner_db.execute(
            "SELECT has_table_privilege('afterme_maintenance', %s, %s) AS ok", (table, kind)
        ).fetchone()
        assert row is not None
        return bool(row["ok"])

    assert privilege("audit_logs", "DELETE")
    assert not privilege("audit_logs", "UPDATE")
    # Phase 7: it may append (``account.purged``), never rewrite.
    assert privilege("audit_logs", "INSERT")
    column = owner_db.execute(
        "SELECT has_column_privilege('afterme_maintenance', 'audit_logs', 'occurred_at', "
        "'SELECT') AS ok"
    ).fetchone()
    assert column == {"ok": True}
    metadata = owner_db.execute(
        "SELECT has_column_privilege('afterme_maintenance', 'audit_logs', 'metadata', "
        "'SELECT') AS ok"
    ).fetchone()
    assert metadata == {"ok": False}


def test_runtime_roles_are_not_superusers(owner_db: Conn) -> None:
    rows = owner_db.execute(
        "SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolbypassrls, rolcanlogin "
        "FROM pg_roles WHERE rolname LIKE 'afterme_%' ORDER BY rolname"
    ).fetchall()
    by_name = {r["rolname"]: r for r in rows}
    for name in ("afterme_api", "afterme_worker"):
        role = by_name[name]
        assert role["rolcanlogin"]
        assert not role["rolsuper"]
        assert not role["rolcreaterole"]
        assert not role["rolcreatedb"]
        assert not role["rolbypassrls"]
    for name in ("afterme_maintenance", "afterme_readonly"):
        assert not by_name[name]["rolcanlogin"]


@pytest.mark.parametrize("role", ["api", "worker"])
def test_contacts_are_never_hard_deleted_and_suppressions_are_append_only(
    role: str, request: pytest.FixtureRequest, owner_db: Conn
) -> None:
    conn: Conn = request.getfixturevalue(role)

    def privileges(table: str) -> dict[str, bool]:
        return {
            p: conn.execute(
                "SELECT has_table_privilege(current_user, %s, %s) AS ok", (table, p)
            ).fetchone()["ok"]  # type: ignore[index]
            for p in ("SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER")
        }

    for table in ("trusted_contacts", "contact_verifications"):
        assert privileges(table) == {
            "SELECT": True,
            "INSERT": True,
            "UPDATE": True,
            "DELETE": False,
            "TRUNCATE": False,
            "REFERENCES": False,
            "TRIGGER": False,
        }, table
    assert privileges("email_suppressions") == {
        "SELECT": True,
        "INSERT": True,
        "UPDATE": False,
        "DELETE": False,
        "TRUNCATE": False,
        "REFERENCES": False,
        "TRIGGER": False,
    }

    user_id = owner_db.execute(
        "INSERT INTO users (email, email_normalized, password_hash) "
        "VALUES ('grant@example.com', 'grant@example.com', 'x') RETURNING id"
    ).fetchone()["id"]  # type: ignore[index]
    contact_id = conn.execute(
        "INSERT INTO trusted_contacts (user_id, display_name, relationship, email, "
        "email_normalized) VALUES (%s, 'Mom', 'mother', 'mom@example.com', 'mom@example.com') "
        "RETURNING id",
        (user_id,),
    ).fetchone()["id"]  # type: ignore[index]
    _denied(conn, f"DELETE FROM trusted_contacts WHERE id = '{contact_id}'")  # noqa: S608
    _denied(conn, "DELETE FROM contact_verifications")
    _denied(conn, "DELETE FROM email_suppressions")
    _denied(conn, "UPDATE email_suppressions SET reason = 'complaint'")
    _denied(conn, "TRUNCATE trusted_contacts")
    _denied(conn, "DROP TABLE email_suppressions")
    conn.execute(
        "UPDATE trusted_contacts SET deleted_at = now(), email = NULL, "
        "email_normalized = NULL WHERE id = %s",
        (contact_id,),
    )


def test_maintenance_role_may_purge_expired_invitations_only(owner_db: Conn) -> None:
    def privilege(table: str, kind: str) -> bool:
        row = owner_db.execute(
            "SELECT has_table_privilege('afterme_maintenance', %s, %s) AS ok", (table, kind)
        ).fetchone()
        assert row is not None
        return bool(row["ok"])

    assert privilege("contact_verifications", "DELETE")
    assert not privilege("contact_verifications", "UPDATE")
    assert not privilege("trusted_contacts", "DELETE")
    assert not privilege("email_suppressions", "DELETE")
    token_hash = owner_db.execute(
        "SELECT has_column_privilege('afterme_maintenance', 'contact_verifications', "
        "'token_hash', 'SELECT') AS ok"
    ).fetchone()
    assert token_hash == {"ok": False}


@pytest.mark.parametrize("role", ["api", "worker"])
def test_checkin_history_is_append_only(
    role: str, request: pytest.FixtureRequest, owner_db: Conn
) -> None:
    conn: Conn = request.getfixturevalue(role)
    privileges = {
        p: conn.execute(
            "SELECT has_table_privilege(current_user, 'checkin_events', %s) AS ok", (p,)
        ).fetchone()["ok"]  # type: ignore[index]
        for p in ("SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER")
    }
    assert privileges == {
        "SELECT": True,
        "INSERT": True,
        "UPDATE": False,
        "DELETE": False,
        "TRUNCATE": False,
        "REFERENCES": False,
        "TRIGGER": False,
    }
    user_id = owner_db.execute(
        "INSERT INTO users (email, email_normalized, password_hash) "
        "VALUES ('history@example.com', 'history@example.com', 'x') RETURNING id"
    ).fetchone()["id"]  # type: ignore[index]
    conn.execute(
        "INSERT INTO checkin_events (user_id, kind, source, received_at, idempotency_key, "
        "response_snapshot) VALUES (%s, 'ok', 'app', now(), 'grant-test-key-0001', '{}')",
        (user_id,),
    )
    _denied(conn, "UPDATE checkin_events SET kind = 'safe'")
    _denied(conn, "DELETE FROM checkin_events")
    _denied(conn, "TRUNCATE checkin_events")


def test_maintenance_role_may_purge_old_checkin_events_only(owner_db: Conn) -> None:
    def privilege(table: str, kind: str) -> bool:
        row = owner_db.execute(
            "SELECT has_table_privilege('afterme_maintenance', %s, %s) AS ok", (table, kind)
        ).fetchone()
        assert row is not None
        return bool(row["ok"])

    assert privilege("checkin_events", "DELETE")
    assert not privilege("checkin_events", "UPDATE")
    assert not privilege("checkin_events", "INSERT")

    def column(name: str) -> bool:
        row = owner_db.execute(
            "SELECT has_column_privilege('afterme_maintenance', 'checkin_events', %s, "
            "'SELECT') AS ok",
            (name,),
        ).fetchone()
        assert row is not None
        return bool(row["ok"])

    assert column("received_at")
    assert not column("response_snapshot")
    assert not column("idempotency_key")


def test_checkin_events_enforce_their_own_invariants(owner_db: Conn) -> None:
    user_id = owner_db.execute(
        "INSERT INTO users (email, email_normalized, password_hash) "
        "VALUES ('inv@example.com', 'inv@example.com', 'x') RETURNING id"
    ).fetchone()["id"]  # type: ignore[index]
    insert = (
        "INSERT INTO checkin_events (user_id, kind, source, received_at, idempotency_key, "
        "response_snapshot) VALUES (%s, %s, %s, now(), %s, '{}')"
    )
    owner_db.execute(insert, (user_id, "ok", "app", "invariant-key-00001"))
    for params in (
        (user_id, "ok", "app", "invariant-key-00001"),  # same key twice
        (user_id, "nope", "app", "invariant-key-00002"),  # unknown kind
        (user_id, "ok", "sms", "invariant-key-00003"),  # unknown source
        (user_id, "ok", "app", "too-short"),  # key below 16 characters
        (user_id, "ok", "app", "k" * 65),  # key above 64 characters
    ):
        with pytest.raises((psycopg.errors.UniqueViolation, psycopg.errors.CheckViolation)):
            owner_db.execute(insert, params)


# --- Phase 5: INV-1 as a property of the database (ESCALATION_ENGINE §2; TEST_PLAN ENG-INV-1) ---


def _table_privilege(conn: Conn, table: str, kind: str) -> bool:
    row = conn.execute(
        "SELECT has_table_privilege(current_user, %s, %s) AS ok", (table, kind)
    ).fetchone()
    assert row is not None
    return bool(row["ok"])


def _column_privilege(conn: Conn, table: str, column: str, kind: str) -> bool:
    row = conn.execute(
        "SELECT has_column_privilege(current_user, %s, %s, %s) AS ok", (table, column, kind)
    ).fetchone()
    assert row is not None
    return bool(row["ok"])


@pytest.mark.parametrize("table", ["escalation_incidents", "incident_actions"])
def test_the_api_role_can_never_create_incidents_or_actions(api: Conn, table: str) -> None:
    assert _table_privilege(api, table, "SELECT")
    for kind in ("INSERT", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER"):
        assert not _table_privilege(api, table, kind), (table, kind)
    assert not _table_privilege(api, table, "UPDATE")  # only specific columns, below
    _denied(
        api,
        f"INSERT INTO {table} DEFAULT VALUES",
    )


def test_the_api_role_can_only_stop_an_incident(api: Conn) -> None:
    allowed = {"status", "closed_at", "closed_by", "updated_at"}
    for column in (
        "id",
        "user_id",
        "plan_snapshot",
        "missed_due_at",
        "opened_at",
        "anchor_at",
        "grace_ends_at",
        "contacts_messaged_at",  # only the dispatcher says contacts were messaged (§4.2)
        "plan_id",
        "plan_version",
    ):
        assert not _column_privilege(api, "escalation_incidents", column, "UPDATE"), column
    for column in allowed:
        assert _column_privilege(api, "escalation_incidents", column, "UPDATE"), column


def test_the_api_role_can_only_cancel_an_action(api: Conn) -> None:
    for column in ("scheduled_for", "original_scheduled_for", "kind", "dedupe_key", "outcome"):
        assert not _column_privilege(api, "incident_actions", column, "UPDATE"), column
    for column in ("status", "updated_at"):
        assert _column_privilege(api, "incident_actions", column, "UPDATE"), column


def test_the_api_role_cannot_rewrite_or_resend_a_notification(api: Conn) -> None:
    assert _table_privilege(api, "notifications", "SELECT")
    assert _table_privilege(api, "notifications", "INSERT")
    assert not _table_privilege(api, "notifications", "DELETE")
    for column in (
        "template_key",
        "params",
        "send_after",
        "contact_id",
        "incident_id",
        "action_id",
    ):
        assert not _column_privilege(api, "notifications", column, "UPDATE"), column
    for column in ("status", "cancelled_reason", "updated_at"):
        assert _column_privilege(api, "notifications", column, "UPDATE"), column
    # Phase 8: the API receives provider webhooks and writes delivery events to the log, once
    # each; it still cannot rewrite or delete a log row.
    assert _table_privilege(api, "notification_logs", "INSERT")
    for kind in ("UPDATE", "DELETE"):
        assert not _table_privilege(api, "notification_logs", kind), kind


def test_the_api_role_cannot_touch_hold_or_heartbeats(api: Conn) -> None:
    assert _table_privilege(api, "system_holds", "SELECT")
    for kind in ("INSERT", "UPDATE", "DELETE"):
        assert not _table_privilege(api, "system_holds", kind), kind
    for kind in ("SELECT", "INSERT", "UPDATE", "DELETE"):
        assert not _table_privilege(api, "service_heartbeats", kind), kind
    assert _table_privilege(api, "ingestion_probes", "INSERT")
    assert not _table_privilege(api, "ingestion_probes", "UPDATE")
    assert not _table_privilege(api, "ingestion_probes", "DELETE")


def test_the_worker_owns_the_engine_tables_but_not_the_audit_trail(worker: Conn) -> None:
    for table in ("escalation_incidents", "incident_actions", "notifications", "system_holds"):
        for kind in ("SELECT", "INSERT", "UPDATE"):
            assert _table_privilege(worker, table, kind), (table, kind)
        assert not _table_privilege(worker, table, "TRUNCATE"), table
    assert _table_privilege(worker, "service_heartbeats", "UPDATE")
    assert _table_privilege(worker, "notification_logs", "INSERT")
    assert not _table_privilege(worker, "notification_logs", "UPDATE")
    assert not _table_privilege(worker, "notification_logs", "DELETE")
    assert not _table_privilege(worker, "audit_logs", "UPDATE")
    assert not _table_privilege(worker, "audit_logs", "DELETE")
    # The worker reads check-ins; it never writes them (a check-in is the user's act).
    assert not _table_privilege(worker, "checkin_events", "UPDATE")
    assert not _table_privilege(worker, "checkin_events", "DELETE")


def test_the_maintenance_role_purges_old_probes_and_notifications_only(owner_db: Conn) -> None:
    def privilege(table: str, kind: str) -> bool:
        row = owner_db.execute(
            "SELECT has_table_privilege('afterme_maintenance', %s, %s) AS ok", (table, kind)
        ).fetchone()
        assert row is not None
        return bool(row["ok"])

    for table in ("ingestion_probes", "notifications", "notification_logs"):
        assert privilege(table, "DELETE"), table
        assert not privilege(table, "UPDATE"), table
        assert not privilege(table, "INSERT"), table
    assert not privilege("escalation_incidents", "DELETE")
    assert not privilege("incident_actions", "DELETE")
    params = owner_db.execute(
        "SELECT has_column_privilege('afterme_maintenance', 'notifications', 'params', 'SELECT') "
        "AS ok"
    ).fetchone()
    assert params == {"ok": False}


def test_the_maintenance_role_removes_deleted_accounts_and_nothing_it_can_read(
    owner_db: Conn,
) -> None:
    """Phase 7 (DATABASE §4, §6): it hard-deletes ``pending_deletion`` users (the foreign keys
    cascade) and scrubs the contacts of such an account. It cannot read credentials, addresses
    or content, and it cannot rewrite a user."""

    def table_privilege(table: str, kind: str) -> bool:
        row = owner_db.execute(
            "SELECT has_table_privilege('afterme_maintenance', %s, %s) AS ok", (table, kind)
        ).fetchone()
        assert row is not None
        return bool(row["ok"])

    def column_privilege(table: str, column: str, kind: str) -> bool:
        row = owner_db.execute(
            "SELECT has_column_privilege('afterme_maintenance', %s, %s, %s) AS ok",
            (table, column, kind),
        ).fetchone()
        assert row is not None
        return bool(row["ok"])

    assert table_privilege("users", "DELETE")
    assert not table_privilege("users", "UPDATE")
    assert not table_privilege("users", "INSERT")
    for column in ("id", "status", "deletion_requested_at"):
        assert column_privilege("users", column, "SELECT"), column
    for column in ("email", "email_normalized", "password_hash"):
        assert not column_privilege("users", column, "SELECT"), column

    assert not table_privilege("trusted_contacts", "DELETE")
    assert not table_privilege("trusted_contacts", "INSERT")
    assert column_privilege("trusted_contacts", "email", "UPDATE")
    assert not column_privilege("trusted_contacts", "email", "SELECT")
    assert not column_privilege("trusted_contacts", "user_id", "UPDATE")
    assert not column_privilege("notifications", "params", "SELECT")

    assert not table_privilege("user_keys", "SELECT")
    assert not table_privilege("instructions", "SELECT")
    assert not table_privilege("instructions", "UPDATE")
    assert not table_privilege("audit_logs", "UPDATE")


def test_the_api_may_delete_a_wrapped_key_but_not_rewrite_it(api: Conn) -> None:
    assert _table_privilege(api, "user_keys", "DELETE")
    assert not _table_privilege(api, "user_keys", "UPDATE")


def test_the_api_role_cannot_write_the_dispatchers_attempt_log(api: Conn, owner_db: Conn) -> None:
    """Webhook events carry a provider event id; an attempt (which the 24-hour give-up reads) is
    the worker's, and a forged or back-dated one would end a message early or never."""
    owner_db.execute(
        "INSERT INTO users (email, email_normalized, password_hash, email_verified_at) "
        "VALUES ('log@example.com', 'log@example.com', 'x', now())"
    )
    user = owner_db.execute("SELECT id FROM users WHERE email = 'log@example.com'").fetchone()
    assert user is not None
    owner_db.execute(
        "INSERT INTO notifications (user_id, audience, category, channel, template_key, "
        "send_after, dedupe_key) VALUES (%s, 'user', 'user', 'email', 'incident_missed', now(), "
        "'log-guard-1')",
        (user["id"],),
    )
    note = owner_db.execute(
        "SELECT id FROM notifications WHERE dedupe_key = 'log-guard-1'"
    ).fetchone()
    assert note is not None
    _denied(
        api,
        f"INSERT INTO notification_logs (notification_id, provider, outcome) "  # noqa: S608
        f"VALUES ('{note['id']}', 'resend', 'accepted')",
    )
    api.execute(
        f"INSERT INTO notification_logs (notification_id, provider, outcome, provider_event_id) "  # noqa: S608
        f"VALUES ('{note['id']}', 'resend', 'delivered', 'evt-1')"
    )
    _denied(api, "UPDATE notification_logs SET outcome = 'bounced'")
    _denied(api, "DELETE FROM notification_logs")
