"""Trusted contacts, invitations and the global suppression list.

Phase 3 tables (DATABASE §3.2): ``trusted_contacts`` (soft delete; composite unique ``(id,
user_id)`` for later same-owner foreign keys; partial unique ``(user_id, email_normalized)`` over
non-deleted rows), ``contact_verifications`` (one row per invitation) and ``email_suppressions``
(global, hashed addresses only). One addition to the documented DDL: ``priority`` is restricted
to 1..999 so the database agrees with the API.

Grants (DATABASE §6), applied only to roles that exist (scripts/dev_db_setup.sh creates them):
* afterme_api, afterme_worker: SELECT/INSERT/UPDATE on trusted_contacts and contact_verifications
  (NO hard delete of contacts: they are soft-deleted and scrubbed; invitations are invalidated
  by UPDATE) and SELECT/INSERT on email_suppressions (append-only).
* afterme_maintenance: DELETE on contact_verifications (purge of expired invitations), plus
  SELECT on the two columns that purge needs in its WHERE clause.

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-09 00:00:00 UTC
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

TZ = sa.DateTime(timezone=True)
UUID = postgresql.UUID(as_uuid=True)
NOW = sa.text("now()")
GEN_UUID = sa.text("gen_random_uuid()")

RUNTIME_ROLES = ("afterme_api", "afterme_worker")


def _grant_sql() -> str:
    runtime = "\n".join(
        f"""
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}') THEN
    GRANT SELECT, INSERT, UPDATE ON trusted_contacts, contact_verifications TO {role};
    GRANT SELECT, INSERT ON email_suppressions TO {role};
  END IF;"""
        for role in RUNTIME_ROLES
    )
    return f"""
DO $$
BEGIN{runtime}
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_maintenance') THEN
    GRANT DELETE ON contact_verifications TO afterme_maintenance;
    GRANT SELECT (id, expires_at) ON contact_verifications TO afterme_maintenance;
  END IF;
END
$$;
"""


def _revoke_sql() -> str:
    runtime = "\n".join(
        f"""
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}') THEN
    REVOKE ALL ON trusted_contacts, contact_verifications, email_suppressions FROM {role};
  END IF;"""
        for role in RUNTIME_ROLES
    )
    return f"""
DO $$
BEGIN{runtime}
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_maintenance') THEN
    REVOKE ALL ON contact_verifications FROM afterme_maintenance;
    REVOKE SELECT (id, expires_at) ON contact_verifications FROM afterme_maintenance;
  END IF;
END
$$;
"""


def upgrade() -> None:
    # --- trusted_contacts --------------------------------------------------------------------
    op.create_table(
        "trusted_contacts",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("display_name", sa.Text(), nullable=False),
        sa.Column("relationship", sa.Text(), nullable=False),
        sa.Column("relationship_label", sa.Text(), nullable=True),
        sa.Column("email", sa.Text(), nullable=True),
        sa.Column("email_normalized", sa.Text(), nullable=True),
        sa.Column("phone_e164", sa.Text(), nullable=True),
        sa.Column("priority", sa.SmallInteger(), server_default=sa.text("100"), nullable=False),
        sa.Column(
            "verification_status", sa.Text(), server_default=sa.text("'pending'"), nullable=False
        ),
        sa.Column("verified_at", TZ, nullable=True),
        sa.Column("status_changed_at", TZ, server_default=NOW, nullable=False),
        sa.Column("is_active", sa.Boolean(), server_default=sa.text("true"), nullable=False),
        sa.Column("invitation_sent_at", TZ, nullable=True),
        sa.Column(
            "invitation_send_count", sa.SmallInteger(), server_default=sa.text("0"), nullable=False
        ),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("updated_at", TZ, server_default=NOW, nullable=False),
        sa.Column("deleted_at", TZ, nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_trusted_contacts")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_trusted_contacts_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint("id", "user_id", name="uq_trusted_contacts_id_user"),
        sa.CheckConstraint(
            "char_length(display_name) BETWEEN 1 AND 80",
            name=op.f("ck_trusted_contacts_display_name_length"),
        ),
        sa.CheckConstraint(
            "relationship IN ('mother', 'father', 'parent', 'spouse', 'partner', 'sibling', "
            "'child', 'relative', 'friend', 'neighbor', 'employer', 'colleague', 'other')",
            name=op.f("ck_trusted_contacts_relationship"),
        ),
        sa.CheckConstraint(
            "char_length(relationship_label) <= 40",
            name=op.f("ck_trusted_contacts_relationship_label_length"),
        ),
        sa.CheckConstraint(
            "char_length(email) <= 254", name=op.f("ck_trusted_contacts_email_length")
        ),
        sa.CheckConstraint(
            "phone_e164 ~ '^\\+[1-9][0-9]{6,14}$'",
            name=op.f("ck_trusted_contacts_phone_e164_format"),
        ),
        sa.CheckConstraint(
            "priority BETWEEN 1 AND 999", name=op.f("ck_trusted_contacts_priority_range")
        ),
        sa.CheckConstraint(
            "verification_status IN ('pending', 'verified', 'declined', 'opted_out', 'bounced')",
            name=op.f("ck_trusted_contacts_status"),
        ),
        sa.CheckConstraint(
            "deleted_at IS NOT NULL OR email IS NOT NULL",
            name=op.f("ck_trusted_contacts_email_present"),
        ),
    )
    op.create_index(
        "uq_trusted_contacts_user_email",
        "trusted_contacts",
        ["user_id", "email_normalized"],
        unique=True,
        postgresql_where=sa.text("deleted_at IS NULL"),
    )
    op.create_index(
        "ix_trusted_contacts_user",
        "trusted_contacts",
        ["user_id"],
        postgresql_where=sa.text("deleted_at IS NULL"),
    )

    # --- contact_verifications ---------------------------------------------------------------
    op.create_table(
        "contact_verifications",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("contact_id", UUID, nullable=False),
        sa.Column("channel", sa.Text(), server_default=sa.text("'email'"), nullable=False),
        sa.Column("token_hash", postgresql.BYTEA(), nullable=False),
        sa.Column("sent_at", TZ, server_default=NOW, nullable=False),
        sa.Column("expires_at", TZ, nullable=False),
        sa.Column("responded_at", TZ, nullable=True),
        sa.Column("response", sa.Text(), nullable=True),
        sa.Column("consent_text_version", sa.Text(), nullable=False),
        sa.Column("ip_hash", postgresql.BYTEA(), nullable=True),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_contact_verifications")),
        sa.ForeignKeyConstraint(
            ["contact_id"],
            ["trusted_contacts.id"],
            name=op.f("fk_contact_verifications_contact_id_trusted_contacts"),
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint("token_hash", name=op.f("uq_contact_verifications_token_hash")),
        sa.CheckConstraint("channel IN ('email')", name=op.f("ck_contact_verifications_channel")),
        sa.CheckConstraint(
            "response IN ('accepted', 'declined')", name=op.f("ck_contact_verifications_response")
        ),
    )
    op.create_index("ix_contact_verifications_contact", "contact_verifications", ["contact_id"])

    # --- email_suppressions (global; hashed addresses only) ----------------------------------
    op.create_table(
        "email_suppressions",
        sa.Column("email_hash", postgresql.BYTEA(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("source_contact_id", UUID, nullable=True),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("email_hash", name=op.f("pk_email_suppressions")),
        sa.CheckConstraint(
            "reason IN ('contact_block_all', 'hard_bounce', 'complaint')",
            name=op.f("ck_email_suppressions_reason"),
        ),
    )

    op.execute(_grant_sql())


def downgrade() -> None:
    op.execute(_revoke_sql())
    op.drop_table("email_suppressions")
    op.drop_index("ix_contact_verifications_contact", table_name="contact_verifications")
    op.drop_table("contact_verifications")
    op.drop_index("ix_trusted_contacts_user", table_name="trusted_contacts")
    op.drop_index("uq_trusted_contacts_user_email", table_name="trusted_contacts")
    op.drop_table("trusted_contacts")
