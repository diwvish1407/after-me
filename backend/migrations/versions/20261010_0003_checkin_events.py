"""Check-in history and idempotent replay store.

Phase 4 table (DATABASE §3.3): ``checkin_events``, one row per recorded I'M OK. The unique
``(user_id, idempotency_key)`` makes a retried request return the original result
(``response_snapshot``) instead of recording a second event. ``incident_id`` has no foreign key
yet: the incidents table arrives in Phase 5, whose migration adds it.

Grants (DATABASE §6), applied only to roles that exist (scripts/dev_db_setup.sh creates them):
* afterme_api, afterme_worker: SELECT and INSERT only. History is append-only; a user's rows
  disappear with the account through the ``ON DELETE CASCADE`` foreign key.
* afterme_maintenance: DELETE (the 400-day purge), plus SELECT on the two columns the purge
  needs in its WHERE clause.

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-10 00:00:00 UTC
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0003"
down_revision: str | None = "0002"
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
    GRANT SELECT, INSERT ON checkin_events TO {role};
  END IF;"""
        for role in RUNTIME_ROLES
    )
    return f"""
DO $$
BEGIN{runtime}
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_maintenance') THEN
    GRANT DELETE ON checkin_events TO afterme_maintenance;
    GRANT SELECT (id, received_at) ON checkin_events TO afterme_maintenance;
  END IF;
END
$$;
"""


def _revoke_sql() -> str:
    runtime = "\n".join(
        f"""
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}') THEN
    REVOKE ALL ON checkin_events FROM {role};
  END IF;"""
        for role in RUNTIME_ROLES
    )
    return f"""
DO $$
BEGIN{runtime}
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_maintenance') THEN
    REVOKE ALL ON checkin_events FROM afterme_maintenance;
    REVOKE SELECT (id, received_at) ON checkin_events FROM afterme_maintenance;
  END IF;
END
$$;
"""


def upgrade() -> None:
    op.create_table(
        "checkin_events",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("received_at", TZ, nullable=False),
        sa.Column("client_reported_at", TZ, nullable=True),
        sa.Column("idempotency_key", sa.Text(), nullable=False),
        sa.Column("session_id", UUID, nullable=True),
        sa.Column("device_id", UUID, nullable=True),
        sa.Column("incident_id", UUID, nullable=True),
        sa.Column("response_snapshot", postgresql.JSONB(), nullable=False),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_checkin_events")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_checkin_events_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["session_id"],
            ["sessions.id"],
            name=op.f("fk_checkin_events_session_id_sessions"),
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["device_id"],
            ["devices.id"],
            name=op.f("fk_checkin_events_device_id_devices"),
            ondelete="SET NULL",
        ),
        sa.UniqueConstraint("user_id", "idempotency_key", name="uq_checkin_events_idem"),
        sa.CheckConstraint("kind IN ('ok', 'safe')", name=op.f("ck_checkin_events_kind")),
        sa.CheckConstraint("source IN ('app', 'web')", name=op.f("ck_checkin_events_source")),
        sa.CheckConstraint(
            "char_length(idempotency_key) BETWEEN 16 AND 64",
            name=op.f("ck_checkin_events_idempotency_key_length"),
        ),
    )
    op.create_index(
        "ix_checkin_events_user_time",
        "checkin_events",
        ["user_id", sa.text("received_at DESC")],
    )
    op.execute(_grant_sql())


def downgrade() -> None:
    op.execute(_revoke_sql())
    op.drop_index("ix_checkin_events_user_time", table_name="checkin_events")
    op.drop_table("checkin_events")
