"""Migrations: upgrade → downgrade → upgrade on an empty database, and no model/schema drift
(DATABASE §8 items 4; TEST_PLAN §10)."""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from alembic.script import ScriptDirectory
from psycopg import sql
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Connection, Engine

from app.models import (
    ALL_TABLES,
    PHASE1_TABLES,
    PHASE3_TABLES,
    PHASE4_TABLES,
    PHASE5_TABLES,
    metadata,
)
from tests.support import OWNER_PASSWORD, TEST_DB, alembic_config, connect, sqlalchemy_url

SCRATCH_DB = f"{TEST_DB}_migrations"


def _drop(name: str) -> None:
    with connect(database="postgres") as admin:
        admin.execute(
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
            "WHERE datname = %s AND pid <> pg_backend_pid() AND backend_type = 'client backend'",
            (name,),
        )
        admin.execute(sql.SQL("DROP DATABASE IF EXISTS {}").format(sql.Identifier(name)))


@pytest.fixture
def scratch_url() -> Iterator[str]:
    _drop(SCRATCH_DB)
    with connect(database="postgres") as admin:
        admin.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(SCRATCH_DB)))
    try:
        yield sqlalchemy_url("afterme_owner", OWNER_PASSWORD, SCRATCH_DB)
    finally:
        _drop(SCRATCH_DB)


@pytest.fixture
def engine(scratch_url: str) -> Iterator[Engine]:
    eng = create_engine(scratch_url)
    try:
        yield eng
    finally:
        eng.dispose()


def _tables(engine: Engine) -> set[str]:
    with engine.connect() as conn:
        rows = conn.execute(
            text("SELECT tablename FROM pg_tables WHERE schemaname = 'public'")
        ).all()
    return {r[0] for r in rows}


def _catalog(engine: Engine) -> dict[str, Any]:
    """Constraint and index definitions as PostgreSQL stores them."""
    with engine.connect() as conn:
        constraints = conn.execute(
            text(
                "SELECT conname, pg_get_constraintdef(c.oid) AS def FROM pg_constraint c "
                "JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = 'public' "
                "AND conrelid <> 0"
            )
        ).all()
        indexes = conn.execute(
            text(
                "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' "
                "AND tablename <> 'alembic_version'"
            )
        ).all()
        persistence = conn.execute(
            text(
                "SELECT relname, relpersistence FROM pg_class c JOIN pg_namespace n "
                "ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND relkind = 'r' "
                "AND relname <> 'alembic_version'"
            )
        ).all()
    return {
        "constraints": {r[0]: r[1] for r in constraints if not r[0].startswith("alembic_version")},
        "indexes": {r[0]: r[1] for r in indexes},
        "persistence": {r[0]: r[1] for r in persistence},
    }


_COLUMNS_SQL = (
    "SELECT table_name, column_name, column_default, is_nullable, data_type, "
    "character_maximum_length, numeric_precision, udt_name, is_identity, identity_generation "
    "FROM information_schema.columns WHERE table_schema = :schema "
    "AND table_name <> 'alembic_version'"
)


def _columns(conn: Connection, schema: str) -> dict[tuple[str, str], tuple[Any, ...]]:
    """Column definitions as PostgreSQL normalises them (defaults, nullability, types, identity),
    keyed by (table, column). Comparing PostgreSQL's own rendering of both sides avoids the false
    positives of Alembic's ``compare_server_default``."""
    rows = conn.execute(text(_COLUMNS_SQL), {"schema": schema}).all()
    return {(r[0], r[1]): tuple(r[2:]) for r in rows}


def test_single_linear_history() -> None:
    script = ScriptDirectory.from_config(alembic_config("postgresql+psycopg://unused/db"))
    heads = script.get_heads()
    assert len(heads) == 1
    revisions = list(script.walk_revisions())
    assert [r.revision for r in revisions] == [
        "0009",
        "0008",
        "0007",
        "0006",
        "0005",
        "0004",
        "0003",
        "0002",
        "0001",
    ]


def test_the_api_roles_notification_allow_list_matches_what_the_code_enqueues() -> None:
    """Migration 0009 lists the (category, template) pairs the API role may insert. A template
    the API process starts to enqueue without a line there would fail at run time, so the list
    is compared with the code (and the dispatcher's own list of contact-facing 'other' kinds)."""
    from importlib import util
    from pathlib import Path

    from app.engine.dispatcher import CONTACT_OTHER_TEMPLATES
    from app.notifications import outbox

    path = next(Path("migrations/versions").glob("*_0009_*.py"))
    spec = util.spec_from_file_location("migration_0009", path)
    assert spec is not None
    assert spec.loader is not None
    module = util.module_from_spec(spec)
    spec.loader.exec_module(module)

    assert set(module.API_CONTACT_TEMPLATES) == set(CONTACT_OTHER_TEMPLATES)
    assert set(module.API_USER_TEMPLATES) == {
        outbox.USER_ALL_CLEAR,
        outbox.USER_ALERT_WITHDRAWN,
        outbox.USER_HOLD_NOTICE,
        outbox.USER_CONTACT_UNREACHABLE,
    }
    assert set(module.API_USER_TEMPLATES) <= set(outbox.USER_CHANNELS)


def test_upgrade_downgrade_upgrade_and_no_drift(scratch_url: str, engine: Engine) -> None:
    cfg = alembic_config(scratch_url)

    command.upgrade(cfg, "head")
    assert _tables(engine) == {*ALL_TABLES, "alembic_version"}
    first = _catalog(engine)

    command.downgrade(cfg, "base")
    assert _tables(engine) == {"alembic_version"}

    command.upgrade(cfg, "head")
    assert _catalog(engine) == first  # the round trip recreates exactly the same schema

    # Model metadata vs the migrated schema: Alembic's comparison (tables, columns, types,
    # nullability, indexes, unique constraints, foreign keys)...
    with engine.connect() as conn:
        context = MigrationContext.configure(
            conn, opts={"compare_type": True, "compare_server_default": False}
        )
        diff = compare_metadata(context, metadata)
    assert diff == [], diff

    # ...plus what Alembic does not compare: CHECK constraints, partial-index predicates,
    # sort order and UNLOGGED. Generate the model DDL into a second scratch schema and compare
    # PostgreSQL's own normalised definitions.
    with engine.begin() as conn:
        conn.execute(text("CREATE SCHEMA model_ddl"))
        conn.execute(text("SET search_path TO model_ddl"))
        metadata.create_all(conn)
        model = conn.execute(
            text(
                "SELECT conname, pg_get_constraintdef(c.oid) AS def FROM pg_constraint c "
                "JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = 'model_ddl'"
            )
        ).all()
        model_indexes = conn.execute(
            text("SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'model_ddl'")
        ).all()
        model_persistence = conn.execute(
            text(
                "SELECT relname, relpersistence FROM pg_class c JOIN pg_namespace n "
                "ON n.oid = c.relnamespace WHERE n.nspname = 'model_ddl' AND relkind = 'r'"
            )
        ).all()
        model_columns = _columns(conn, "model_ddl")
        migrated_columns = _columns(conn, "public")
        conn.execute(text("SET search_path TO public"))
        conn.execute(text("DROP SCHEMA model_ddl CASCADE"))

    # Column server defaults, nullability, types and identity: the migration spells ~30 defaults
    # by hand (gen_random_uuid(), now(), '{}'::jsonb, ...) and each must equal the model's.
    assert migrated_columns, "no columns found in the migrated schema"
    assert model_columns == migrated_columns
    assert "gen_random_uuid()" in str(migrated_columns[("users", "id")][0])

    assert {r[0]: r[1] for r in model} == first["constraints"]
    assert {r[0]: r[1].replace("model_ddl.", "public.") for r in model_indexes} == first["indexes"]
    assert {r[0]: r[1] for r in model_persistence} == first["persistence"]
    assert first["persistence"]["rate_limit_counters"] == "u"


def test_migration_grants_runtime_roles(scratch_url: str, engine: Engine) -> None:
    command.upgrade(alembic_config(scratch_url), "head")
    with engine.connect() as conn:
        rows = conn.execute(
            text(
                "SELECT table_name, privilege_type FROM information_schema.role_table_grants "
                "WHERE grantee = 'afterme_api' ORDER BY 1, 2"
            )
        ).all()
    grants: dict[str, set[str]] = {}
    for table, privilege in rows:
        grants.setdefault(table, set()).add(privilege)
    assert grants.pop("audit_logs") == {"INSERT", "SELECT"}
    assert grants.pop("alembic_version") == {"SELECT"}
    assert grants.pop("trusted_contacts") == {"SELECT", "INSERT", "UPDATE"}  # soft delete only
    assert grants.pop("contact_verifications") == {"SELECT", "INSERT", "UPDATE"}
    assert grants.pop("email_suppressions") == {"SELECT", "INSERT"}  # append-only
    assert grants.pop("checkin_events") == {"SELECT", "INSERT"}  # append-only history
    # Phase 5 (INV-1): the API edits the plan but can never create an incident or an action.
    assert grants.pop("escalation_plans") == {"SELECT", "INSERT", "UPDATE", "DELETE"}
    assert grants.pop("escalation_steps") == {"SELECT", "INSERT", "UPDATE", "DELETE"}
    assert grants.pop("escalation_step_contacts") == {"SELECT", "INSERT", "UPDATE", "DELETE"}
    # Table-level only: the API's UPDATEs on these are column-limited (test_db_grants.py).
    assert grants.pop("escalation_incidents") == {"SELECT"}
    assert grants.pop("incident_actions") == {"SELECT"}
    assert grants.pop("notifications") == {"SELECT", "INSERT"}
    assert grants.pop("notification_logs") == {"SELECT", "INSERT"}  # webhooks (Phase 8)
    assert grants.pop("system_holds") == {"SELECT"}
    assert grants.pop("ingestion_probes") == {"INSERT"}
    # Phase 6: the API serves the owner and the portal; it cannot create releases, portal
    # access or link tokens (the engine's), and cannot modify a wrapped key. Phase 7: it can
    # delete one (account deletion destroys the key).
    assert grants.pop("user_keys") == {"SELECT", "INSERT", "DELETE"}
    assert grants.pop("instruction_categories") == {"SELECT"}
    assert grants.pop("instructions") == {"SELECT", "INSERT", "UPDATE"}  # soft delete only
    assert grants.pop("instruction_recipients") == {"SELECT", "INSERT", "UPDATE", "DELETE"}
    assert grants.pop("release_events") == {"SELECT"}  # UPDATE is column-limited
    assert grants.pop("portal_access") == {"SELECT"}
    assert grants.pop("portal_tokens") == {"SELECT"}
    assert grants.pop("portal_sessions") == {"SELECT", "INSERT"}
    assert grants.pop("portal_otp_challenges") == {"SELECT", "INSERT"}
    # Phase 8: receipts of direct mail are append-only for the runtime roles.
    assert grants.pop("email_receipts") == {"SELECT", "INSERT"}
    assert grants == {
        t: {"SELECT", "INSERT", "UPDATE", "DELETE"} for t in PHASE1_TABLES if t != "audit_logs"
    }

    command.downgrade(alembic_config(scratch_url), "base")
    with engine.connect() as conn:
        remaining = conn.execute(
            text(
                "SELECT count(*) FROM information_schema.role_table_grants "
                "WHERE grantee IN ('afterme_api', 'afterme_worker', 'afterme_maintenance')"
            )
        ).scalar_one()
    assert remaining == 0


def test_phase6_downgrade_removes_only_instructions_and_release(
    scratch_url: str, engine: Engine
) -> None:
    cfg = alembic_config(scratch_url)
    command.upgrade(cfg, "head")
    command.downgrade(cfg, "0005")
    assert _tables(engine) == {
        *PHASE1_TABLES,
        *PHASE3_TABLES,
        *PHASE4_TABLES,
        *PHASE5_TABLES,
        "alembic_version",
    }
    with engine.connect() as conn:
        left = conn.execute(
            text(
                "SELECT count(*) FROM information_schema.role_table_grants "
                "WHERE table_name IN ('instructions', 'release_events', 'portal_tokens')"
            )
        ).scalar_one()
        assert left == 0
        assert conn.execute(
            text("SELECT has_table_privilege('afterme_api', 'notifications', 'INSERT')")
        ).scalar_one()
    command.upgrade(cfg, "head")
    assert _tables(engine) == {*ALL_TABLES, "alembic_version"}


def test_phase5_downgrade_removes_only_the_engine_tables(scratch_url: str, engine: Engine) -> None:
    cfg = alembic_config(scratch_url)
    command.upgrade(cfg, "head")
    command.downgrade(cfg, "0003")
    assert _tables(engine) == {
        *PHASE1_TABLES,
        *PHASE3_TABLES,
        *PHASE4_TABLES,
        "alembic_version",
    }
    with engine.connect() as conn:
        left = conn.execute(
            text(
                "SELECT count(*) FROM information_schema.role_table_grants "
                "WHERE table_name IN ('escalation_incidents', 'incident_actions', 'notifications')"
            )
        ).scalar_one()
        assert left == 0
        assert conn.execute(
            text("SELECT has_table_privilege('afterme_api', 'checkin_events', 'INSERT')")
        ).scalar_one()
    command.upgrade(cfg, "head")
    assert _tables(engine) == {*ALL_TABLES, "alembic_version"}


def test_phase4_downgrade_removes_only_the_checkin_history(
    scratch_url: str, engine: Engine
) -> None:
    cfg = alembic_config(scratch_url)
    command.upgrade(cfg, "head")
    command.downgrade(cfg, "0002")
    assert _tables(engine) == {*PHASE1_TABLES, *PHASE3_TABLES, "alembic_version"}
    with engine.connect() as conn:
        left = conn.execute(
            text(
                "SELECT count(*) FROM information_schema.role_table_grants "
                "WHERE table_name = 'checkin_events'"
            )
        ).scalar_one()
        assert left == 0
        # Phase 3 privileges are untouched by the Phase 4 downgrade.
        assert conn.execute(
            text("SELECT has_table_privilege('afterme_api', 'trusted_contacts', 'UPDATE')")
        ).scalar_one()
    command.upgrade(cfg, "head")
    assert _tables(engine) == {*ALL_TABLES, "alembic_version"}


def test_phase3_downgrade_keeps_phase1_and_removes_only_phase3(
    scratch_url: str, engine: Engine
) -> None:
    cfg = alembic_config(scratch_url)
    command.upgrade(cfg, "head")
    command.downgrade(cfg, "0001")
    assert _tables(engine) == {*PHASE1_TABLES, "alembic_version"}
    with engine.connect() as conn:
        left = conn.execute(
            text(
                "SELECT count(*) FROM information_schema.role_table_grants "
                "WHERE table_name IN ('trusted_contacts', 'contact_verifications', "
                "'email_suppressions')"
            )
        ).scalar_one()
        assert left == 0
        # The maintenance role keeps only its Phase 1 privilege (purging audit logs).
        assert conn.execute(
            text("SELECT has_table_privilege('afterme_maintenance', 'audit_logs', 'DELETE')")
        ).scalar_one()
    command.upgrade(cfg, "head")
    assert _tables(engine) == {*ALL_TABLES, "alembic_version"}
