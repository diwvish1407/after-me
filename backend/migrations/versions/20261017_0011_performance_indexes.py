"""Indexes the query plans of the hot paths asked for (TEST_PLAN §9, PERF-01..04).

Only indexes; no table, column, constraint or grant changes. Each one is here because
``scripts/perf.py`` (EXPLAIN (ANALYZE, BUFFERS) of every statement of the hot paths on 100,000
people, ``backend/tests/perf/PLANS.md``) showed the statement reading whole tables, or a statement
timeout, without it:

* ``ix_incident_actions_user_pending (user_id, scheduled_for) WHERE status = 'pending'``: the
  engine's unit of work for one person (``due_actions``, ``late_stage_actions``) read every due
  action of every person through ``ix_incident_actions_due`` and kept one person's: with 10,000
  people due at once, each of the 10,000 units read about 10,000 rows.
* ``ix_escalation_steps_user (user_id)``: every read of an owner's plan (Home, the plan, the
  activation check) scanned ``escalation_steps``.
* ``ix_notifications_sending (updated_at) WHERE status = 'sending'``: the dispatcher puts back
  what a dead worker left in ``sending`` at the start of every pass; it scanned ``notifications``.
* ``ix_incidents_opened (opened_at)``: Hold's anomaly check (every tick during a burst) and the
  operator reports count incidents by the hour.
* Retention (``app.maintenance.retention``) takes the oldest rows in batches of 1,000 and sorts by
  time: ``ix_notifications_finished (created_at) WHERE status IN ('sent', 'failed',
  'cancelled')``, ``ix_checkin_events_received_at``, ``ix_audit_occurred``.
* Foreign keys with ``ON DELETE SET NULL`` or ``CASCADE`` to a parent that retention deletes, whose
  child column had no index: deleting ONE session, device or token read the whole child table
  (PostgreSQL checks the reference with a scan). At 100,000 people the purge of sessions and
  refresh tokens died on the 15 s statement timeout. ``ix_checkin_events_session``,
  ``ix_checkin_events_device``, ``ix_sessions_device``, ``ix_refresh_tokens_replaced_by``,
  ``ix_notifications_action``, ``ix_notifications_device``: all partial on ``IS NOT NULL``.

``CREATE INDEX`` without ``CONCURRENTLY`` takes a lock that blocks writes to the table while it is
built. That is acceptable only because every table here is small or empty when this runs (before
launch). On a populated database (docs/DEPLOYMENT.md §5):

1. build each index first with ``CREATE INDEX CONCURRENTLY <name> ON <table> <definition>``,
   outside a transaction (the definitions are ``_INDEXES`` below);
2. check that every one of them is VALID before running this migration::

       SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
        WHERE c.relname IN (<the names>) AND NOT (i.indisvalid AND i.indisready);

   must return no row. A concurrent build that failed or was cancelled leaves an INVALID index
   under the name: the planner ignores it, and ``IF NOT EXISTS`` alone would accept it and leave
   the hot paths on the scans this migration exists to remove. Drop it (``DROP INDEX
   CONCURRENTLY <name>``) and build it again;
3. run the migration: ``IF NOT EXISTS`` then skips the valid indexes.

``upgrade`` itself refuses to run while an index of one of these names exists but is invalid.

Revision ID: 0011
Revises: 0010
Create Date: 2026-10-17 00:00:00 UTC
"""

from __future__ import annotations

from collections.abc import Sequence

from alembic import op

revision: str = "0011"
down_revision: str | None = "0010"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# name, table, definition after the table name
_INDEXES: tuple[tuple[str, str, str], ...] = (
    (
        "ix_incident_actions_user_pending",
        "incident_actions",
        "(user_id, scheduled_for) WHERE status = 'pending'",
    ),
    ("ix_escalation_steps_user", "escalation_steps", "(user_id)"),
    ("ix_notifications_sending", "notifications", "(updated_at) WHERE status = 'sending'"),
    ("ix_incidents_opened", "escalation_incidents", "(opened_at)"),
    (
        "ix_notifications_finished",
        "notifications",
        "(created_at) WHERE status IN ('sent', 'failed', 'cancelled')",
    ),
    ("ix_checkin_events_received_at", "checkin_events", "(received_at)"),
    ("ix_audit_occurred", "audit_logs", "(occurred_at)"),
    (
        "ix_checkin_events_session",
        "checkin_events",
        "(session_id) WHERE session_id IS NOT NULL",
    ),
    ("ix_checkin_events_device", "checkin_events", "(device_id) WHERE device_id IS NOT NULL"),
    ("ix_sessions_device", "sessions", "(device_id) WHERE device_id IS NOT NULL"),
    (
        "ix_refresh_tokens_replaced_by",
        "refresh_tokens",
        "(replaced_by) WHERE replaced_by IS NOT NULL",
    ),
    ("ix_notifications_action", "notifications", "(action_id) WHERE action_id IS NOT NULL"),
    ("ix_notifications_device", "notifications", "(device_id) WHERE device_id IS NOT NULL"),
)


def _invalid_indexes() -> list[str]:
    names = ", ".join(f"'{name}'" for name, _table, _definition in _INDEXES)
    rows = op.get_bind().exec_driver_sql(
        "SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        f"WHERE n.nspname = current_schema() AND c.relname IN ({names}) "
        "AND NOT (i.indisvalid AND i.indisready) ORDER BY c.relname"
    )
    return [str(r[0]) for r in rows]


def upgrade() -> None:
    invalid = _invalid_indexes()
    if invalid:
        msg = (
            f"invalid index(es) {', '.join(invalid)} (a failed CREATE INDEX CONCURRENTLY): "
            "DROP INDEX CONCURRENTLY each one, build it again, check pg_index.indisvalid, then "
            "re-run the migration (docs/DEPLOYMENT.md section 5)"
        )
        raise RuntimeError(msg)
    for name, table, definition in _INDEXES:
        op.execute(f"CREATE INDEX IF NOT EXISTS {name} ON {table} {definition}")


def downgrade() -> None:
    for name, _table, _definition in reversed(_INDEXES):
        op.execute(f"DROP INDEX IF EXISTS {name}")
