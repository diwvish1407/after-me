"""Admin role, two-factor authentication, Sign in with Google, contact acknowledgements.

* ``users.role`` (``user`` | ``admin``): admins may use ``/v1/admin``.
* ``users.totp_*``: TOTP two-factor authentication (secret wrapped by the KMS).
* ``users.google_sub``: the linked Google account (unique when set).
* ``incident_acknowledgements``: a trusted contact confirmed from their alert link that they are
  checking on the person (informational; the engine never reads it).
* The API role may start and end an operator Hold (admin screen): INSERT on ``system_holds`` and
  UPDATE of ``ended_at`` only.

Revision ID: 0015
Revises: 0014
Create Date: 2026-11-17 01:00:00 UTC
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0015"
down_revision: str | None = "0014"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_GRANT = """
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_api') THEN
    GRANT SELECT, INSERT ON incident_acknowledgements TO afterme_api;
    GRANT INSERT ON system_holds TO afterme_api;
    GRANT UPDATE (ended_at) ON system_holds TO afterme_api;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_worker') THEN
    GRANT SELECT ON incident_acknowledgements TO afterme_worker;
  END IF;
END
$$;
"""

_REVOKE = """
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_api') THEN
    REVOKE INSERT ON system_holds FROM afterme_api;
    REVOKE UPDATE (ended_at) ON system_holds FROM afterme_api;
  END IF;
END
$$;
"""


def upgrade() -> None:
    op.add_column(
        "users", sa.Column("role", sa.Text(), server_default=sa.text("'user'"), nullable=False)
    )
    op.create_check_constraint(op.f("ck_users_role"), "users", "role IN ('user', 'admin')")
    op.add_column("users", sa.Column("totp_secret_wrapped", postgresql.BYTEA()))
    op.add_column("users", sa.Column("totp_key_id", sa.Text()))
    op.add_column("users", sa.Column("totp_enabled_at", sa.DateTime(timezone=True)))
    op.add_column("users", sa.Column("totp_last_step", sa.BigInteger()))
    op.add_column("users", sa.Column("totp_recovery", postgresql.JSONB()))
    op.add_column("users", sa.Column("google_sub", sa.Text()))
    op.create_index(
        "uq_users_google_sub",
        "users",
        ["google_sub"],
        unique=True,
        postgresql_where=sa.text("google_sub IS NOT NULL"),
    )

    op.create_table(
        "incident_acknowledgements",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            primary_key=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "incident_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("escalation_incidents.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("contact_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("acknowledged_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("incident_id", "contact_id", name="uq_incident_ack_contact"),
        sa.ForeignKeyConstraint(
            ["contact_id", "user_id"],
            ["trusted_contacts.id", "trusted_contacts.user_id"],
            ondelete="CASCADE",
            name="fk_incident_ack_contact",
        ),
    )
    op.create_index("ix_incident_ack_incident", "incident_acknowledgements", ["incident_id"])
    op.execute(_GRANT)


def downgrade() -> None:
    op.execute(_REVOKE)
    op.drop_index("ix_incident_ack_incident", table_name="incident_acknowledgements")
    op.drop_table("incident_acknowledgements")
    op.drop_index("uq_users_google_sub", table_name="users")
    for column in (
        "google_sub",
        "totp_recovery",
        "totp_last_step",
        "totp_enabled_at",
        "totp_key_id",
        "totp_secret_wrapped",
    ):
        op.drop_column("users", column)
    op.drop_constraint(op.f("ck_users_role"), "users", type_="check")
    op.drop_column("users", "role")
