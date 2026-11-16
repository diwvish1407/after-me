"""Custom timings: check-in intervals in minutes and shorter floors for the plan.

* ``checkin_configurations.interval_minutes`` (nullable): when set, the next deadline is the
  baseline plus this many minutes, instead of ``interval_days`` at ``due_local_time``.
* ``reminder_lead_minutes`` accepts any value from 0 to 1440 instead of the fixed list.
* ``escalation_plans.grace_minutes`` and ``escalation_steps.offset_minutes`` accept values from
  one minute (the floors were 60).

Revision ID: 0013
Revises: 0012
Create Date: 2026-11-15 00:00:00 UTC
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0013"
down_revision: str | None = "0012"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def _replace_check(table: str, name: str, condition: str) -> None:
    op.drop_constraint(op.f(name), table, type_="check")
    op.create_check_constraint(op.f(name), table, condition)


def upgrade() -> None:
    op.add_column("checkin_configurations", sa.Column("interval_minutes", sa.Integer()))
    op.create_check_constraint(
        op.f("ck_checkin_configurations_interval_minutes"),
        "checkin_configurations",
        "interval_minutes IS NULL OR interval_minutes BETWEEN 1 AND 43200",
    )
    _replace_check(
        "checkin_configurations",
        "ck_checkin_configurations_reminder_lead_minutes",
        "reminder_lead_minutes BETWEEN 0 AND 1440",
    )
    _replace_check(
        "escalation_plans", "ck_escalation_plans_grace_minutes", "grace_minutes BETWEEN 1 AND 4320"
    )
    _replace_check(
        "escalation_steps",
        "ck_escalation_steps_offset_minutes",
        "offset_minutes BETWEEN 1 AND 43200",
    )


def downgrade() -> None:
    # Rows that only the new rules allow are moved back inside the old ones first.
    op.execute(
        "UPDATE checkin_configurations SET reminder_lead_minutes = 60 "
        "WHERE reminder_lead_minutes NOT IN (0, 30, 60, 120, 240)"
    )
    op.execute("UPDATE escalation_plans SET grace_minutes = 60 WHERE grace_minutes < 60")
    op.execute("UPDATE escalation_steps SET offset_minutes = 60 WHERE offset_minutes < 60")
    _replace_check(
        "escalation_steps",
        "ck_escalation_steps_offset_minutes",
        "offset_minutes BETWEEN 60 AND 43200",
    )
    _replace_check(
        "escalation_plans", "ck_escalation_plans_grace_minutes", "grace_minutes BETWEEN 60 AND 4320"
    )
    _replace_check(
        "checkin_configurations",
        "ck_checkin_configurations_reminder_lead_minutes",
        "reminder_lead_minutes IN (0, 30, 60, 120, 240)",
    )
    op.drop_constraint(
        op.f("ck_checkin_configurations_interval_minutes"), "checkin_configurations", type_="check"
    )
    op.drop_column("checkin_configurations", "interval_minutes")
