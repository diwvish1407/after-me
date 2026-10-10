"""Engine hardening found by the Phase 5 independent review.

Migration 0004 gave the API role the *columns* it needs to stop an incident, cancel an action
and cancel or enqueue a notification. Column grants cannot say which **values** it may write, so
a compromised API role could still resurrect a closed incident, mark an action ``executed``, or
insert a ``contact_escalation`` row that the dispatcher would then believe. These triggers close
that: for ``afterme_api`` only, the database refuses anything but

* ``notifications``: INSERT of anything but a ``queued`` row outside the escalation category;
  UPDATE only ``queued`` -> ``cancelled``;
* ``incident_actions``: UPDATE only ``pending`` -> ``cancelled``;
* ``escalation_incidents``: UPDATE only of an *open* incident to a *closed* status.

(The dispatcher also derives every contact-facing message again from the incident's own
snapshot; this is the second lock on the same door.)

The worker loses what it never needed: DML on the plan tables (it reads them), and DELETE on
incidents, actions and notifications (retention is the maintenance role's).

Revision ID: 0005
Revises: 0004
Create Date: 2026-10-12 00:00:00 UTC
"""

from __future__ import annotations

from collections.abc import Sequence

from alembic import op

revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_FUNCTIONS = """
CREATE OR REPLACE FUNCTION afterme_guard_api_notifications() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF current_user <> 'afterme_api' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.category = 'contact_escalation' OR NEW.status <> 'queued' THEN
      RAISE EXCEPTION 'afterme_api may only enqueue non-escalation messages'
        USING ERRCODE = '42501';
    END IF;
  ELSIF NOT (OLD.status = 'queued' AND NEW.status = 'cancelled') THEN
    RAISE EXCEPTION 'afterme_api may only cancel a queued message' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$fn$;

CREATE OR REPLACE FUNCTION afterme_guard_api_actions() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF current_user = 'afterme_api'
     AND NOT (OLD.status = 'pending' AND NEW.status = 'cancelled') THEN
    RAISE EXCEPTION 'afterme_api may only cancel a pending action' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$fn$;

CREATE OR REPLACE FUNCTION afterme_guard_api_incidents() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF current_user = 'afterme_api' AND NOT (
       OLD.status IN ('grace', 'escalating', 'escalated')
       AND NEW.status IN ('resolved', 'cancelled', 'voided')
       AND OLD.closed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'afterme_api may only close an open incident' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$fn$;
"""

_TRIGGERS = """
CREATE TRIGGER afterme_guard_notifications_insert BEFORE INSERT ON notifications
  FOR EACH ROW EXECUTE FUNCTION afterme_guard_api_notifications();
CREATE TRIGGER afterme_guard_notifications_update BEFORE UPDATE ON notifications
  FOR EACH ROW EXECUTE FUNCTION afterme_guard_api_notifications();
CREATE TRIGGER afterme_guard_actions BEFORE UPDATE ON incident_actions
  FOR EACH ROW EXECUTE FUNCTION afterme_guard_api_actions();
CREATE TRIGGER afterme_guard_incidents BEFORE UPDATE ON escalation_incidents
  FOR EACH ROW EXECUTE FUNCTION afterme_guard_api_incidents();
"""

_WORKER_REVOKE = """
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_worker') THEN
    REVOKE INSERT, UPDATE, DELETE ON escalation_plans, escalation_steps,
           escalation_step_contacts FROM afterme_worker;
    REVOKE DELETE ON escalation_incidents, incident_actions, notifications FROM afterme_worker;
  END IF;
END
$$;
"""

_WORKER_RESTORE = """
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_worker') THEN
    GRANT INSERT, UPDATE, DELETE ON escalation_plans, escalation_steps,
          escalation_step_contacts TO afterme_worker;
    GRANT DELETE ON escalation_incidents, incident_actions, notifications TO afterme_worker;
  END IF;
END
$$;
"""


def upgrade() -> None:
    op.execute(_FUNCTIONS)
    op.execute(_TRIGGERS)
    op.execute(_WORKER_REVOKE)


def downgrade() -> None:
    op.execute(_WORKER_RESTORE)
    op.execute("DROP TRIGGER afterme_guard_incidents ON escalation_incidents")
    op.execute("DROP TRIGGER afterme_guard_actions ON incident_actions")
    op.execute("DROP TRIGGER afterme_guard_notifications_update ON notifications")
    op.execute("DROP TRIGGER afterme_guard_notifications_insert ON notifications")
    op.execute("DROP FUNCTION afterme_guard_api_incidents()")
    op.execute("DROP FUNCTION afterme_guard_api_actions()")
    op.execute("DROP FUNCTION afterme_guard_api_notifications()")
