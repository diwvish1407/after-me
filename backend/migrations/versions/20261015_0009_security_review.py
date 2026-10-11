"""Database-side findings of the Phase 9 security review.

* **BD-1.** ``afterme_api`` may insert notifications (it enqueues all-clears and the person's own
  messages), and the trigger of 0005 only refused the escalation category. A row of another
  category could still name an alert template and a contact of any account. Now:
  - the trigger allows exactly the (category, audience, template) combinations the API process
    writes, and nothing else;
  - a CHECK says the two alert templates exist only in the escalation category, for every role;
  - ``(contact_id, user_id)`` is a composite foreign key to the contact's owner, like the
    other tables that name a contact (a message can no longer be aimed at another account's
    contact, whoever writes it).
* **BD-10.** ``afterme_maintenance`` may scrub contacts and write audit rows, but only for what
  it is for: contacts of a ``pending_deletion`` account, and ``account.purged`` events.
* **BD-11.** The guard functions pin ``search_path`` so that a temporary table cannot stand in
  for ``users``.

Revision ID: 0009
Revises: 0008
Create Date: 2026-10-15 00:00:00 UTC
"""

from __future__ import annotations

from collections.abc import Sequence

from alembic import op

revision: str = "0009"
down_revision: str | None = "0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# What the API process enqueues (app/incidents/closing.py, app/releases/portal_service.py,
# app/notifications/unreachable.py). A new template written by the API needs a line here:
# tests/security/test_migrations.py compares this list with the code.
API_USER_TEMPLATES = (
    "all_clear_confirmation",
    "alert_withdrawn_notice",
    "service_interruption",
    "contact_unreachable",
)
API_CONTACT_TEMPLATES = ("contact_all_clear", "contact_alert_withdrawn", "contact_release")


def _quoted(values: Sequence[str]) -> str:
    return ", ".join(f"'{v}'" for v in values)


_NOTIFICATIONS_GUARD = f"""
CREATE OR REPLACE FUNCTION afterme_guard_api_notifications() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $fn$
BEGIN
  IF current_user <> 'afterme_api' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'queued' THEN
      RAISE EXCEPTION 'afterme_api may only enqueue messages' USING ERRCODE = '42501';
    END IF;
    IF NEW.category = 'user' THEN
      IF NEW.audience <> 'user' OR NEW.template_key NOT IN ({_quoted(API_USER_TEMPLATES)}) THEN
        RAISE EXCEPTION 'afterme_api may not enqueue this message' USING ERRCODE = '42501';
      END IF;
    ELSIF NEW.category = 'contact_other' THEN
      IF NEW.audience <> 'contact'
         OR NEW.template_key NOT IN ({_quoted(API_CONTACT_TEMPLATES)}) THEN
        RAISE EXCEPTION 'afterme_api may not enqueue this message' USING ERRCODE = '42501';
      END IF;
    ELSE
      RAISE EXCEPTION 'afterme_api may only enqueue non-escalation messages'
        USING ERRCODE = '42501';
    END IF;
  ELSIF NOT (OLD.status = 'queued' AND NEW.status = 'cancelled') THEN
    RAISE EXCEPTION 'afterme_api may only cancel a queued message' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$fn$;
"""

_NOTIFICATIONS_GUARD_BEFORE = """
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
"""

_MAINTENANCE_GUARDS = """
CREATE OR REPLACE FUNCTION afterme_guard_maintenance_contacts() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $fn$
BEGIN
  IF current_user = 'afterme_maintenance' AND NOT EXISTS (
       SELECT 1 FROM users WHERE id = OLD.user_id AND status = 'pending_deletion'
  ) THEN
    RAISE EXCEPTION 'only the contacts of a closed account can be scrubbed'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$fn$;

CREATE TRIGGER afterme_guard_maintenance_contacts BEFORE UPDATE ON trusted_contacts
  FOR EACH ROW EXECUTE FUNCTION afterme_guard_maintenance_contacts();

CREATE OR REPLACE FUNCTION afterme_guard_maintenance_audit() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $fn$
BEGIN
  IF current_user = 'afterme_maintenance' AND NEW.action <> 'account.purged' THEN
    RAISE EXCEPTION 'the retention job may only record account.purged' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$fn$;

CREATE TRIGGER afterme_guard_maintenance_audit BEFORE INSERT ON audit_logs
  FOR EACH ROW EXECUTE FUNCTION afterme_guard_maintenance_audit();
"""

_MAINTENANCE_UNGUARD = """
DROP TRIGGER IF EXISTS afterme_guard_maintenance_audit ON audit_logs;
DROP FUNCTION IF EXISTS afterme_guard_maintenance_audit();
DROP TRIGGER IF EXISTS afterme_guard_maintenance_contacts ON trusted_contacts;
DROP FUNCTION IF EXISTS afterme_guard_maintenance_contacts();
"""

# Every guard that reads another table, so that a TEMP table of the same name cannot shadow it.
_PINNED = (
    "afterme_guard_active_owner()",
    "afterme_guard_user_purge()",
    "afterme_guard_api_actions()",
    "afterme_guard_api_incidents()",
    "afterme_guard_api_releases()",
    "afterme_guard_api_portal_access()",
    "afterme_guard_api_log_insert()",
)


def upgrade() -> None:
    op.create_check_constraint(
        op.f("ck_notifications_alert_category"),
        "notifications",
        "template_key NOT IN ('contact_alert', 'contact_alert_with_release') "
        "OR category = 'contact_escalation'",
    )
    op.create_foreign_key(
        op.f("fk_notifications_contact_id_user_id_trusted_contacts"),
        "notifications",
        "trusted_contacts",
        ["contact_id", "user_id"],
        ["id", "user_id"],
    )
    op.execute(_NOTIFICATIONS_GUARD)
    op.execute(_MAINTENANCE_GUARDS)
    for function in _PINNED:
        op.execute(f"ALTER FUNCTION {function} SET search_path = public, pg_temp")


def downgrade() -> None:
    for function in _PINNED:
        op.execute(f"ALTER FUNCTION {function} RESET search_path")
    op.execute(_MAINTENANCE_UNGUARD)
    op.execute(_NOTIFICATIONS_GUARD_BEFORE)
    op.drop_constraint(
        op.f("fk_notifications_contact_id_user_id_trusted_contacts"),
        "notifications",
        type_="foreignkey",
    )
    op.drop_constraint(op.f("ck_notifications_alert_category"), "notifications", type_="check")
