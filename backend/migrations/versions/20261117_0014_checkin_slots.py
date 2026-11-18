"""Several check-in events per person, each optionally with its own escalation plan.

* ``checkin_slots``: extra check-in events (label, interval, local due time, own deadline).
* ``checkin_configurations.primary_due_at``: the primary event's own deadline;
  ``next_due_at`` becomes the earliest deadline of all events and ``due_slot_id`` says whose.
* ``escalation_plans.slot_id``: a plan that belongs to one event (same owner); the one-plan-per-
  person unique constraint becomes "one default plan" plus "one plan per event".

Revision ID: 0014
Revises: 0013
Create Date: 2026-11-17 00:00:00 UTC
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0014"
down_revision: str | None = "0013"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_GRANT = """
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_api') THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON checkin_slots TO afterme_api;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_worker') THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON checkin_slots TO afterme_worker;
  END IF;
END
$$;
"""


def upgrade() -> None:
    op.create_table(
        "checkin_slots",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            primary_key=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("label", sa.Text(), nullable=False),
        sa.Column("interval_days", sa.SmallInteger(), server_default=sa.text("1"), nullable=False),
        sa.Column("interval_minutes", sa.Integer()),
        sa.Column("due_local_time", sa.Time(), nullable=False),
        sa.Column("next_due_at", sa.DateTime(timezone=True)),
        sa.Column("deleted_at", sa.DateTime(timezone=True)),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "interval_days BETWEEN 1 AND 30", name=op.f("ck_checkin_slots_interval_days")
        ),
        sa.CheckConstraint(
            "interval_minutes IS NULL OR interval_minutes BETWEEN 1 AND 43200",
            name=op.f("ck_checkin_slots_interval_minutes"),
        ),
        sa.CheckConstraint(
            "char_length(label) BETWEEN 1 AND 60", name=op.f("ck_checkin_slots_label_length")
        ),
        sa.UniqueConstraint("id", "user_id", name="uq_checkin_slots_id_user"),
    )
    op.create_index("ix_checkin_slots_user", "checkin_slots", ["user_id"])

    op.add_column("checkin_configurations", sa.Column("primary_due_at", sa.DateTime(timezone=True)))
    op.add_column("checkin_configurations", sa.Column("due_slot_id", postgresql.UUID(as_uuid=True)))
    # Until now the only deadline was the primary one.
    op.execute("UPDATE checkin_configurations SET primary_due_at = next_due_at")

    op.add_column("escalation_plans", sa.Column("slot_id", postgresql.UUID(as_uuid=True)))
    op.create_foreign_key(
        "fk_escalation_plans_slot",
        "escalation_plans",
        "checkin_slots",
        ["slot_id", "user_id"],
        ["id", "user_id"],
        ondelete="CASCADE",
    )
    op.drop_constraint("uq_escalation_plans_user", "escalation_plans", type_="unique")
    op.create_index(
        "uq_escalation_plans_user_default",
        "escalation_plans",
        ["user_id"],
        unique=True,
        postgresql_where=sa.text("slot_id IS NULL"),
    )
    op.create_index(
        "uq_escalation_plans_slot",
        "escalation_plans",
        ["slot_id"],
        unique=True,
        postgresql_where=sa.text("slot_id IS NOT NULL"),
    )
    op.execute(_GRANT)


def downgrade() -> None:
    # Event plans and events cannot be represented by the older schema: they are removed, and
    # each person keeps the primary event and the default plan.
    op.execute("DELETE FROM escalation_plans WHERE slot_id IS NOT NULL")
    op.drop_index("uq_escalation_plans_slot", table_name="escalation_plans")
    op.drop_index("uq_escalation_plans_user_default", table_name="escalation_plans")
    op.create_unique_constraint("uq_escalation_plans_user", "escalation_plans", ["user_id"])
    op.drop_constraint("fk_escalation_plans_slot", "escalation_plans", type_="foreignkey")
    op.drop_column("escalation_plans", "slot_id")
    op.execute(
        "UPDATE checkin_configurations SET next_due_at = primary_due_at WHERE status <> 'inactive'"
    )
    op.drop_column("checkin_configurations", "due_slot_id")
    op.drop_column("checkin_configurations", "primary_due_at")
    op.drop_index("ix_checkin_slots_user", table_name="checkin_slots")
    op.drop_table("checkin_slots")
