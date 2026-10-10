"""Initial schema: identity and access, check-in configuration, audit, system tables.

Phase 1 tables (DATABASE §3.1, §3.3 checkin_configurations only, §3.9, §3.11 system_flags and
rate_limit_counters). Later phases add their own tables in their own migrations.

Reference data: Phase 1 seeds none. ``system_flags`` is created empty because nothing in Phase 1
reads it (``MIN_CLIENT_VERSION`` comes from the environment); the phase that first reads a flag
seeds its default in its own migration (DATABASE §8 item 6).

Grants (DATABASE §6), applied only to roles that exist (scripts/dev_db_setup.sh creates them):
* afterme_api, afterme_worker: SELECT/INSERT/UPDATE/DELETE on the Phase 1 tables except
  audit_logs, which is INSERT/SELECT only (append-only); USAGE on the audit_logs identity
  sequence; SELECT on alembic_version (readiness check).
* afterme_maintenance: DELETE on audit_logs, plus SELECT on the two columns a retention
  DELETE needs in its WHERE clause (PostgreSQL requires SELECT for columns read by a DELETE).

Revision ID: 0001
Revises:
Create Date: 2026-10-08 00:00:00 UTC
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

TZ = sa.DateTime(timezone=True)
UUID = postgresql.UUID(as_uuid=True)
NOW = sa.text("now()")
GEN_UUID = sa.text("gen_random_uuid()")

DML_TABLES = (
    "users",
    "user_profiles",
    "devices",
    "sessions",
    "refresh_tokens",
    "auth_tokens",
    "checkin_configurations",
    "system_flags",
    "rate_limit_counters",
)
RUNTIME_ROLES = ("afterme_api", "afterme_worker")


def _grant_sql() -> str:
    tables = ", ".join(DML_TABLES)
    runtime = "\n".join(
        f"""
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}') THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON {tables} TO {role};
    GRANT SELECT, INSERT ON audit_logs TO {role};
    EXECUTE format('GRANT USAGE ON SEQUENCE %s TO {role}',
                   pg_get_serial_sequence('public.audit_logs', 'id'));
    GRANT SELECT ON alembic_version TO {role};
  END IF;"""
        for role in RUNTIME_ROLES
    )
    return f"""
DO $$
BEGIN{runtime}
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_maintenance') THEN
    GRANT DELETE ON audit_logs TO afterme_maintenance;
    GRANT SELECT (id, occurred_at) ON audit_logs TO afterme_maintenance;
  END IF;
END
$$;
"""


def _revoke_sql() -> str:
    tables = ", ".join(DML_TABLES)
    runtime = "\n".join(
        f"""
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}') THEN
    REVOKE ALL ON {tables}, audit_logs FROM {role};
    EXECUTE format('REVOKE ALL ON SEQUENCE %s FROM {role}',
                   pg_get_serial_sequence('public.audit_logs', 'id'));
    REVOKE ALL ON alembic_version FROM {role};
  END IF;"""
        for role in RUNTIME_ROLES
    )
    return f"""
DO $$
BEGIN{runtime}
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_maintenance') THEN
    REVOKE ALL ON audit_logs FROM afterme_maintenance;
    REVOKE SELECT (id, occurred_at) ON audit_logs FROM afterme_maintenance;
  END IF;
END
$$;
"""


def upgrade() -> None:
    # --- users -------------------------------------------------------------------------------
    op.create_table(
        "users",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("email", sa.Text(), nullable=False),
        sa.Column("email_normalized", sa.Text(), nullable=False),
        sa.Column("email_verified_at", TZ, nullable=True),
        sa.Column("password_hash", sa.Text(), nullable=False),
        sa.Column("password_changed_at", TZ, server_default=NOW, nullable=False),
        sa.Column("status", sa.Text(), server_default=sa.text("'active'"), nullable=False),
        sa.Column("tier", sa.Text(), server_default=sa.text("'free'"), nullable=False),
        sa.Column("deletion_requested_at", TZ, nullable=True),
        sa.Column(
            "failed_login_count", sa.SmallInteger(), server_default=sa.text("0"), nullable=False
        ),
        sa.Column("locked_until", TZ, nullable=True),
        sa.Column("last_login_at", TZ, nullable=True),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("updated_at", TZ, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_users")),
        sa.UniqueConstraint("email_normalized", name=op.f("uq_users_email_normalized")),
        sa.CheckConstraint("char_length(email) <= 254", name=op.f("ck_users_email_length")),
        sa.CheckConstraint(
            "status IN ('active', 'pending_deletion', 'suspended')", name=op.f("ck_users_status")
        ),
        sa.CheckConstraint("tier IN ('free', 'premium')", name=op.f("ck_users_tier")),
    )

    # --- user_profiles -----------------------------------------------------------------------
    op.create_table(
        "user_profiles",
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("display_name", sa.Text(), nullable=False),
        sa.Column("phone_e164", sa.Text(), nullable=True),
        sa.Column("country_code", sa.CHAR(2), nullable=True),
        sa.Column("timezone", sa.Text(), nullable=False),
        sa.Column("locale", sa.Text(), server_default=sa.text("'en'"), nullable=False),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("updated_at", TZ, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("user_id", name=op.f("pk_user_profiles")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_user_profiles_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.CheckConstraint(
            "char_length(display_name) BETWEEN 1 AND 80",
            name=op.f("ck_user_profiles_display_name_length"),
        ),
        sa.CheckConstraint(
            r"phone_e164 ~ '^\+[1-9][0-9]{6,14}$'", name=op.f("ck_user_profiles_phone_e164_format")
        ),
    )

    # --- devices -----------------------------------------------------------------------------
    op.create_table(
        "devices",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("platform", sa.Text(), nullable=False),
        sa.Column("push_token", sa.Text(), nullable=True),
        sa.Column("push_token_updated_at", TZ, nullable=True),
        sa.Column("app_version", sa.Text(), nullable=True),
        sa.Column("os_version", sa.Text(), nullable=True),
        sa.Column("locale", sa.Text(), nullable=True),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("last_seen_at", TZ, server_default=NOW, nullable=False),
        sa.Column("revoked_at", TZ, nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_devices")),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_devices_user_id_users"), ondelete="CASCADE"
        ),
        sa.CheckConstraint("platform IN ('android')", name=op.f("ck_devices_platform")),
    )
    op.create_index(
        "uq_devices_push_token",
        "devices",
        ["push_token"],
        unique=True,
        postgresql_where=sa.text("push_token IS NOT NULL"),
    )
    op.create_index(
        "ix_devices_user", "devices", ["user_id"], postgresql_where=sa.text("revoked_at IS NULL")
    )

    # --- sessions ----------------------------------------------------------------------------
    op.create_table(
        "sessions",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("device_id", UUID, nullable=True),
        sa.Column("web_token_hash", postgresql.BYTEA(), nullable=True),
        sa.Column("auth_method", sa.Text(), server_default=sa.text("'password'"), nullable=False),
        sa.Column("reauthenticated_at", TZ, nullable=True),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("last_used_at", TZ, server_default=NOW, nullable=False),
        sa.Column("idle_expires_at", TZ, nullable=False),
        sa.Column("absolute_expires_at", TZ, nullable=False),
        sa.Column("revoked_at", TZ, nullable=True),
        sa.Column("revoke_reason", sa.Text(), nullable=True),
        sa.Column("ip_hash", postgresql.BYTEA(), nullable=True),
        sa.Column("user_agent", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_sessions")),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_sessions_user_id_users"), ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["device_id"],
            ["devices.id"],
            name=op.f("fk_sessions_device_id_devices"),
            ondelete="SET NULL",
        ),
        sa.UniqueConstraint("web_token_hash", name=op.f("uq_sessions_web_token_hash")),
        sa.CheckConstraint("kind IN ('app', 'web')", name=op.f("ck_sessions_kind")),
        sa.CheckConstraint(
            "revoke_reason IN ('logout', 'logout_all', 'password_changed', 'password_reset', "
            "'reuse_detected', 'account_deleted', 'operator', 'expired')",
            name=op.f("ck_sessions_revoke_reason"),
        ),
        sa.CheckConstraint(
            "char_length(user_agent) <= 200", name=op.f("ck_sessions_user_agent_length")
        ),
    )
    op.create_index(
        "ix_sessions_user_active",
        "sessions",
        ["user_id"],
        postgresql_where=sa.text("revoked_at IS NULL"),
    )

    # --- refresh_tokens ----------------------------------------------------------------------
    op.create_table(
        "refresh_tokens",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("session_id", UUID, nullable=False),
        sa.Column("token_hash", postgresql.BYTEA(), nullable=False),
        sa.Column("issued_at", TZ, server_default=NOW, nullable=False),
        sa.Column("expires_at", TZ, nullable=False),
        sa.Column("used_at", TZ, nullable=True),
        sa.Column("replaced_by", UUID, nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_refresh_tokens")),
        sa.ForeignKeyConstraint(
            ["session_id"],
            ["sessions.id"],
            name=op.f("fk_refresh_tokens_session_id_sessions"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["replaced_by"],
            ["refresh_tokens.id"],
            name=op.f("fk_refresh_tokens_replaced_by_refresh_tokens"),
            ondelete="SET NULL",
        ),
        sa.UniqueConstraint("token_hash", name=op.f("uq_refresh_tokens_token_hash")),
    )
    op.create_index("ix_refresh_tokens_session", "refresh_tokens", ["session_id"])

    # --- auth_tokens -------------------------------------------------------------------------
    op.create_table(
        "auth_tokens",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("purpose", sa.Text(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("secret_hash", postgresql.BYTEA(), nullable=False),
        sa.Column("payload", postgresql.JSONB(), nullable=True),
        sa.Column("attempts", sa.SmallInteger(), server_default=sa.text("0"), nullable=False),
        sa.Column("expires_at", TZ, nullable=False),
        sa.Column("used_at", TZ, nullable=True),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_auth_tokens")),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_auth_tokens_user_id_users"), ondelete="CASCADE"
        ),
        sa.CheckConstraint(
            "purpose IN ('signup_verify', 'email_change', 'password_reset', 'account_delete_web')",
            name=op.f("ck_auth_tokens_purpose"),
        ),
        sa.CheckConstraint("kind IN ('code', 'link')", name=op.f("ck_auth_tokens_kind")),
    )
    op.create_index(
        "uq_auth_tokens_link",
        "auth_tokens",
        ["secret_hash"],
        unique=True,
        postgresql_where=sa.text("kind = 'link'"),
    )
    op.create_index(
        "ix_auth_tokens_user_purpose",
        "auth_tokens",
        ["user_id", "purpose"],
        postgresql_where=sa.text("used_at IS NULL"),
    )

    # --- checkin_configurations --------------------------------------------------------------
    op.create_table(
        "checkin_configurations",
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("interval_days", sa.SmallInteger(), server_default=sa.text("1"), nullable=False),
        sa.Column("due_local_time", sa.Time(), server_default=sa.text("'20:00'"), nullable=False),
        sa.Column(
            "reminder_lead_minutes", sa.SmallInteger(), server_default=sa.text("60"), nullable=False
        ),
        sa.Column("status", sa.Text(), server_default=sa.text("'inactive'"), nullable=False),
        sa.Column("baseline_at", TZ, nullable=True),
        sa.Column("last_checkin_at", TZ, nullable=True),
        sa.Column("next_due_at", TZ, nullable=True),
        sa.Column("activated_at", TZ, nullable=True),
        sa.Column("version", sa.Integer(), server_default="1", nullable=False),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("updated_at", TZ, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("user_id", name=op.f("pk_checkin_configurations")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_checkin_configurations_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.CheckConstraint(
            "interval_days BETWEEN 1 AND 30", name=op.f("ck_checkin_configurations_interval_days")
        ),
        sa.CheckConstraint(
            "reminder_lead_minutes IN (0, 30, 60, 120, 240)",
            name=op.f("ck_checkin_configurations_reminder_lead_minutes"),
        ),
        sa.CheckConstraint(
            "status IN ('inactive', 'active', 'incident_open')",
            name=op.f("ck_checkin_configurations_status"),
        ),
        sa.CheckConstraint(
            "status = 'inactive' OR (next_due_at IS NOT NULL AND baseline_at IS NOT NULL)",
            name=op.f("ck_checkin_cfg_active_has_due"),
        ),
    )
    op.create_index(
        "ix_checkin_cfg_due",
        "checkin_configurations",
        ["next_due_at"],
        postgresql_where=sa.text("status = 'active'"),
    )

    # --- audit_logs (append-only; no FKs so history survives account deletion) ----------------
    op.create_table(
        "audit_logs",
        sa.Column("id", sa.BigInteger(), sa.Identity(always=True), nullable=False),
        sa.Column("occurred_at", TZ, server_default=NOW, nullable=False),
        sa.Column("actor_type", sa.Text(), nullable=False),
        sa.Column("actor_id", UUID, nullable=True),
        sa.Column("subject_user_id", UUID, nullable=True),
        sa.Column("action", sa.Text(), nullable=False),
        sa.Column("resource_type", sa.Text(), nullable=True),
        sa.Column("resource_id", UUID, nullable=True),
        sa.Column("request_id", sa.Text(), nullable=True),
        sa.Column("ip_hash", postgresql.BYTEA(), nullable=True),
        sa.Column("user_visible", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column(
            "metadata",
            postgresql.JSONB(),
            server_default=sa.text("'{}'::jsonb"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_audit_logs")),
        sa.CheckConstraint(
            "actor_type IN ('user', 'contact', 'system', 'operator')",
            name=op.f("ck_audit_logs_actor_type"),
        ),
    )
    op.create_index(
        "ix_audit_subject_time",
        "audit_logs",
        ["subject_user_id", sa.text("occurred_at DESC")],
    )
    op.create_index("ix_audit_action_time", "audit_logs", ["action", sa.text("occurred_at DESC")])

    # --- system_flags ------------------------------------------------------------------------
    op.create_table(
        "system_flags",
        sa.Column("key", sa.Text(), nullable=False),
        sa.Column("value", postgresql.JSONB(), nullable=False),
        sa.Column("updated_at", TZ, server_default=NOW, nullable=False),
        sa.Column("updated_by", sa.Text(), nullable=False),
        sa.PrimaryKeyConstraint("key", name=op.f("pk_system_flags")),
    )

    # --- rate_limit_counters (UNLOGGED: non-authoritative, loss on crash is acceptable) -------
    op.create_table(
        "rate_limit_counters",
        sa.Column("key", sa.Text(), nullable=False),
        sa.Column("window_start", TZ, nullable=False),
        sa.Column("count", sa.Integer(), nullable=False),
        sa.Column("expires_at", TZ, nullable=False),
        sa.PrimaryKeyConstraint("key", "window_start", name=op.f("pk_rate_limit_counters")),
        prefixes=["UNLOGGED"],
    )

    op.execute(_grant_sql())


def downgrade() -> None:
    op.execute(_revoke_sql())
    op.drop_table("rate_limit_counters")
    op.drop_table("system_flags")
    op.drop_index("ix_audit_action_time", table_name="audit_logs")
    op.drop_index("ix_audit_subject_time", table_name="audit_logs")
    op.drop_table("audit_logs")
    op.drop_index("ix_checkin_cfg_due", table_name="checkin_configurations")
    op.drop_table("checkin_configurations")
    op.drop_index("ix_auth_tokens_user_purpose", table_name="auth_tokens")
    op.drop_index("uq_auth_tokens_link", table_name="auth_tokens")
    op.drop_table("auth_tokens")
    op.drop_index("ix_refresh_tokens_session", table_name="refresh_tokens")
    op.drop_table("refresh_tokens")
    op.drop_index("ix_sessions_user_active", table_name="sessions")
    op.drop_table("sessions")
    op.drop_index("ix_devices_user", table_name="devices")
    op.drop_index("uq_devices_push_token", table_name="devices")
    op.drop_table("devices")
    op.drop_table("user_profiles")
    op.drop_table("users")
