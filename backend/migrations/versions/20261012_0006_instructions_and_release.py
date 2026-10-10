"""Instructions, recipients, releases and the recipient portal.

Phase 6 tables (DATABASE §3.1, §3.5, §3.7): ``user_keys`` (the per-user wrapped DEK),
``instruction_categories`` (seeded), ``instructions`` (content only as ciphertext),
``instruction_recipients`` (who gets what, at which stage), ``release_events``, ``portal_access``,
``portal_tokens``, ``portal_sessions`` and ``portal_otp_challenges``.

Grants (DATABASE §6) are what keep INV-1 and the content boundary true in the database, and are
applied only to roles that exist:

* afterme_api serves the owner and the recipient portal. It reads and writes instructions and
  recipients and may create the user's key. It can **not** insert releases, portal access or
  tokens: those are the engine's. It may revoke (one way: a trigger refuses un-revoking) and
  count views. It owns portal sessions and one-time-code challenges.
* afterme_worker never reads instruction content: its SELECT on ``instructions`` lists every
  column except ``content_ciphertext``, and it has nothing on ``user_keys``. It creates releases,
  portal access and (at send time) the hashed link tokens.
* afterme_maintenance: DELETE of expired tokens, sessions and challenges.

Revision ID: 0006
Revises: 0005
Create Date: 2026-10-12 00:00:00 UTC
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0006"
down_revision: str | None = "0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

TZ = sa.DateTime(timezone=True)
UUID = postgresql.UUID(as_uuid=True)
NOW = sa.text("now()")
GEN_UUID = sa.text("gen_random_uuid()")

CATEGORIES = (
    ("personal", 1),
    ("family", 2),
    ("home", 3),
    ("work", 4),
    ("business", 5),
    ("documents", 6),
    ("insurance", 7),
    ("pets", 8),
    ("travel", 9),
    ("digital_accounts", 10),
    ("other", 11),
)
REVOKE_REASONS = (
    "user_safe",
    "user_checkin",
    "instruction_removed",
    "recipient_removed",
    "contact_removed",
    "contact_opted_out",
    "account_deleted",
    "hold_rollback",
    "operator",
)
TABLES = (
    "user_keys",
    "instruction_categories",
    "instructions",
    "instruction_recipients",
    "release_events",
    "portal_access",
    "portal_tokens",
    "portal_sessions",
    "portal_otp_challenges",
)


def _role_block(role: str, statements: str) -> str:
    return f"""
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}') THEN{statements}
  END IF;"""


def _grant_sql() -> str:
    api = """
    GRANT SELECT, INSERT ON user_keys TO afterme_api;
    GRANT SELECT ON instruction_categories TO afterme_api;
    GRANT SELECT, INSERT, UPDATE ON instructions TO afterme_api;
    GRANT SELECT, INSERT, UPDATE, DELETE ON instruction_recipients TO afterme_api;
    GRANT SELECT ON release_events, portal_access, portal_tokens TO afterme_api;
    GRANT UPDATE (revoked_at, revoke_reason, first_viewed_at, last_viewed_at, view_count)
          ON release_events TO afterme_api;
    GRANT UPDATE (revoked_at) ON portal_access TO afterme_api;
    GRANT UPDATE (first_used_at) ON portal_tokens TO afterme_api;
    GRANT SELECT, INSERT ON portal_sessions, portal_otp_challenges TO afterme_api;
    GRANT UPDATE (otp_verified_at, elevated_until, revoked_at) ON portal_sessions
          TO afterme_api;
    GRANT UPDATE (attempts, consumed_at) ON portal_otp_challenges TO afterme_api;"""
    worker = """
    GRANT SELECT (id, user_id, category_id, status, content_key_version, content_version,
                  created_at, updated_at, deleted_at) ON instructions TO afterme_worker;
    GRANT SELECT ON instruction_recipients TO afterme_worker;
    GRANT SELECT, INSERT, UPDATE ON release_events, portal_access TO afterme_worker;
    GRANT SELECT, INSERT ON portal_tokens TO afterme_worker;"""
    maintenance = """
    GRANT DELETE ON portal_tokens, portal_sessions, portal_otp_challenges
          TO afterme_maintenance;
    GRANT SELECT (id, expires_at) ON portal_tokens, portal_sessions, portal_otp_challenges
          TO afterme_maintenance;"""
    return f"""
DO $$
BEGIN{_role_block("afterme_api", api)}{_role_block("afterme_worker", worker)}{
        _role_block("afterme_maintenance", maintenance)
    }
END
$$;
"""


def _revoke_sql() -> str:
    tables = ", ".join(TABLES)
    blocks = "".join(
        _role_block(role, f"\n    REVOKE ALL ON {tables} FROM {role};")
        for role in ("afterme_api", "afterme_worker", "afterme_maintenance")
    )
    return f"""
DO $$
BEGIN{blocks}
END
$$;
"""


_GUARDS = """
CREATE OR REPLACE FUNCTION afterme_guard_api_releases() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  -- Revocation is one way: nothing the API role does can make a revoked release visible again.
  IF current_user = 'afterme_api' AND OLD.revoked_at IS NOT NULL
     AND (NEW.revoked_at IS DISTINCT FROM OLD.revoked_at
          OR NEW.revoke_reason IS DISTINCT FROM OLD.revoke_reason) THEN
    RAISE EXCEPTION 'a revoked release stays revoked' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$fn$;

CREATE OR REPLACE FUNCTION afterme_guard_api_portal_access() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF current_user = 'afterme_api' AND OLD.revoked_at IS NOT NULL
     AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
    RAISE EXCEPTION 'revoked portal access stays revoked' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$fn$;

CREATE TRIGGER afterme_guard_releases BEFORE UPDATE ON release_events
  FOR EACH ROW EXECUTE FUNCTION afterme_guard_api_releases();
CREATE TRIGGER afterme_guard_portal_access BEFORE UPDATE ON portal_access
  FOR EACH ROW EXECUTE FUNCTION afterme_guard_api_portal_access();
"""


def upgrade() -> None:
    # --- user_keys -----------------------------------------------------------------------------
    op.create_table(
        "user_keys",
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("wrapped_dek", sa.LargeBinary(), nullable=False),
        sa.Column("kek_id", sa.Text(), nullable=False),
        sa.Column("dek_version", sa.Integer(), server_default=sa.text("1"), nullable=False),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("rotated_at", TZ, nullable=True),
        sa.PrimaryKeyConstraint("user_id", name=op.f("pk_user_keys")),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_user_keys_user_id_users"), ondelete="CASCADE"
        ),
    )

    # --- categories (seeded) -------------------------------------------------------------------
    categories = op.create_table(
        "instruction_categories",
        sa.Column("id", sa.Text(), nullable=False),
        sa.Column("sort_order", sa.SmallInteger(), nullable=False),
        sa.Column("is_active", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_instruction_categories")),
        sa.CheckConstraint("id ~ '^[a-z_]{2,32}$'", name=op.f("ck_instruction_categories_id")),
    )
    op.bulk_insert(categories, [{"id": i, "sort_order": n} for i, n in CATEGORIES])

    # --- instructions --------------------------------------------------------------------------
    op.create_table(
        "instructions",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("category_id", sa.Text(), nullable=False),
        sa.Column("status", sa.Text(), server_default="active", nullable=False),
        sa.Column("content_ciphertext", sa.LargeBinary(), nullable=True),
        sa.Column("content_key_version", sa.Integer(), nullable=False),
        sa.Column("content_version", sa.Integer(), server_default=sa.text("1"), nullable=False),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("updated_at", TZ, server_default=NOW, nullable=False),
        sa.Column("deleted_at", TZ, nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_instructions")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_instructions_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["category_id"],
            ["instruction_categories.id"],
            name=op.f("fk_instructions_category_id_instruction_categories"),
        ),
        sa.UniqueConstraint("id", "user_id", name="uq_instructions_id_user"),
        sa.CheckConstraint("status IN ('active','inactive')", name=op.f("ck_instructions_status")),
        sa.CheckConstraint(
            "deleted_at IS NOT NULL OR content_ciphertext IS NOT NULL",
            name=op.f("ck_instructions_content"),
        ),
        sa.CheckConstraint("content_key_version >= 1", name=op.f("ck_instructions_key_version")),
    )
    op.create_index(
        "ix_instructions_user",
        "instructions",
        ["user_id"],
        postgresql_where=sa.text("deleted_at IS NULL"),
    )

    # --- instruction_recipients ----------------------------------------------------------------
    op.create_table(
        "instruction_recipients",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("instruction_id", UUID, nullable=False),
        sa.Column("contact_id", UUID, nullable=False),
        sa.Column("release_step_id", UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("updated_at", TZ, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_instruction_recipients")),
        sa.UniqueConstraint(
            "instruction_id", "contact_id", name="uq_instruction_recipients_instruction_contact"
        ),
        sa.ForeignKeyConstraint(
            ["instruction_id", "user_id"],
            ["instructions.id", "instructions.user_id"],
            name=op.f("fk_instruction_recipients_instruction_id_user_id_instructions"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["contact_id", "user_id"],
            ["trusted_contacts.id", "trusted_contacts.user_id"],
            name=op.f("fk_instruction_recipients_contact_id_user_id_trusted_contacts"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["release_step_id", "user_id"],
            ["escalation_steps.id", "escalation_steps.user_id"],
            name=op.f("fk_instruction_recipients_release_step_id_user_id_escalation_steps"),
            # Deferred to COMMIT, not RESTRICT: still refuses to remove a stage that holds an
            # instruction (the plan service answers 409 first), but deleting a whole account
            # (users -> steps and users -> instructions -> recipients) does not depend on the
            # order the cascades run in.
            deferrable=True,
            initially="DEFERRED",
        ),
    )
    op.create_index("ix_instruction_recipients_step", "instruction_recipients", ["release_step_id"])

    # --- release_events ------------------------------------------------------------------------
    reasons = ",".join(f"'{r}'" for r in REVOKE_REASONS)
    op.create_table(
        "release_events",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("incident_id", UUID, nullable=False),
        sa.Column("action_id", UUID, nullable=False),
        sa.Column("instruction_id", UUID, nullable=False),
        sa.Column("contact_id", UUID, nullable=False),
        sa.Column("step_id", UUID, nullable=False),
        sa.Column("released_at", TZ, nullable=False),
        sa.Column("visible_after", TZ, nullable=False),
        sa.Column("revoked_at", TZ, nullable=True),
        sa.Column("revoke_reason", sa.Text(), nullable=True),
        sa.Column("first_viewed_at", TZ, nullable=True),
        sa.Column("last_viewed_at", TZ, nullable=True),
        sa.Column("view_count", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_release_events")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_release_events_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["incident_id"],
            ["escalation_incidents.id"],
            name=op.f("fk_release_events_incident_id_escalation_incidents"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["action_id"],
            ["incident_actions.id"],
            name=op.f("fk_release_events_action_id_incident_actions"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["instruction_id"],
            ["instructions.id"],
            name=op.f("fk_release_events_instruction_id_instructions"),
        ),
        sa.ForeignKeyConstraint(
            ["contact_id"],
            ["trusted_contacts.id"],
            name=op.f("fk_release_events_contact_id_trusted_contacts"),
        ),
        sa.UniqueConstraint(
            "incident_id", "instruction_id", "contact_id", name="uq_release_events_release"
        ),
        sa.CheckConstraint(
            f"revoke_reason IS NULL OR revoke_reason IN ({reasons})",
            name=op.f("ck_release_events_revoke_reason"),
        ),
        sa.CheckConstraint(
            "(revoked_at IS NULL) = (revoke_reason IS NULL)",
            name=op.f("ck_release_events_revoked_pair"),
        ),
    )
    op.create_index(
        "ix_release_events_incident_contact", "release_events", ["incident_id", "contact_id"]
    )

    # --- portal_access -------------------------------------------------------------------------
    op.create_table(
        "portal_access",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("incident_id", UUID, nullable=False),
        sa.Column("contact_id", UUID, nullable=False),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("revoked_at", TZ, nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_portal_access")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_portal_access_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["incident_id"],
            ["escalation_incidents.id"],
            name=op.f("fk_portal_access_incident_id_escalation_incidents"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["contact_id"],
            ["trusted_contacts.id"],
            name=op.f("fk_portal_access_contact_id_trusted_contacts"),
        ),
        sa.UniqueConstraint("incident_id", "contact_id", name="uq_portal_access_incident_contact"),
    )

    # --- portal_tokens -------------------------------------------------------------------------
    op.create_table(
        "portal_tokens",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("access_id", UUID, nullable=False),
        sa.Column("token_hash", sa.LargeBinary(), nullable=False),
        sa.Column("notification_id", UUID, nullable=True),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("expires_at", TZ, nullable=False),
        sa.Column("first_used_at", TZ, nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_portal_tokens")),
        sa.ForeignKeyConstraint(
            ["access_id"],
            ["portal_access.id"],
            name=op.f("fk_portal_tokens_access_id_portal_access"),
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint("token_hash", name="uq_portal_tokens_token_hash"),
    )
    op.create_index("ix_portal_tokens_access", "portal_tokens", ["access_id"])

    # --- portal_sessions -----------------------------------------------------------------------
    op.create_table(
        "portal_sessions",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("access_id", UUID, nullable=False),
        sa.Column("session_hash", sa.LargeBinary(), nullable=False),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("expires_at", TZ, nullable=False),
        sa.Column("otp_verified_at", TZ, nullable=True),
        sa.Column("elevated_until", TZ, nullable=True),
        sa.Column("ip_hash", sa.LargeBinary(), nullable=True),
        sa.Column("revoked_at", TZ, nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_portal_sessions")),
        sa.ForeignKeyConstraint(
            ["access_id"],
            ["portal_access.id"],
            name=op.f("fk_portal_sessions_access_id_portal_access"),
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint("session_hash", name="uq_portal_sessions_session_hash"),
    )

    # --- portal_otp_challenges -----------------------------------------------------------------
    op.create_table(
        "portal_otp_challenges",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("portal_session_id", UUID, nullable=False),
        sa.Column("code_hash", sa.LargeBinary(), nullable=False),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("expires_at", TZ, nullable=False),
        sa.Column("attempts", sa.SmallInteger(), server_default=sa.text("0"), nullable=False),
        sa.Column("consumed_at", TZ, nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_portal_otp_challenges")),
        sa.ForeignKeyConstraint(
            ["portal_session_id"],
            ["portal_sessions.id"],
            name=op.f("fk_portal_otp_challenges_portal_session_id_portal_sessions"),
            ondelete="CASCADE",
        ),
    )
    op.create_index("ix_portal_otp_session", "portal_otp_challenges", ["portal_session_id"])

    op.execute(_GUARDS)
    op.execute(_grant_sql())


def downgrade() -> None:
    op.execute(_revoke_sql())
    op.execute("DROP TRIGGER afterme_guard_portal_access ON portal_access")
    op.execute("DROP TRIGGER afterme_guard_releases ON release_events")
    op.execute("DROP FUNCTION afterme_guard_api_portal_access()")
    op.execute("DROP FUNCTION afterme_guard_api_releases()")
    op.drop_index("ix_portal_otp_session", table_name="portal_otp_challenges")
    op.drop_table("portal_otp_challenges")
    op.drop_table("portal_sessions")
    op.drop_index("ix_portal_tokens_access", table_name="portal_tokens")
    op.drop_table("portal_tokens")
    op.drop_table("portal_access")
    op.drop_index("ix_release_events_incident_contact", table_name="release_events")
    op.drop_table("release_events")
    op.drop_index("ix_instruction_recipients_step", table_name="instruction_recipients")
    op.drop_table("instruction_recipients")
    op.drop_index("ix_instructions_user", table_name="instructions")
    op.drop_table("instructions")
    op.drop_table("instruction_categories")
    op.drop_table("user_keys")
