"""Delivery events from email providers, receipts for direct mail, retention guards.

``notification_logs`` already records every attempt the dispatcher makes. A provider also tells
us later what happened (delivered, bounced, complained) through a webhook. Each such event is
written to the same table with the provider's own event id, which is unique per provider, so a
redelivered webhook is recognised and changes nothing twice.

* afterme_api receives the webhooks and may therefore INSERT log rows (it had SELECT only), but
  only rows that carry a provider event id (a trigger refuses it the dispatcher's kind: the API
  cannot back-date an attempt, which the 24-hour give-up reads).
* ``email_receipts`` remembers the provider message id of mail sent straight to a contact (an
  invitation), so that a bounce or complaint reported later can be tied to the contact. The
  outbox does that for everything the dispatcher sends; this is for mail that carries a secret.
* afterme_maintenance may read ``notifications.incident_id`` and an incident's status, so that
  the retention job never deletes the messages of an incident that is still open (they are the
  all-clear audience), and may delete old receipts.

Revision ID: 0008
Revises: 0007
Create Date: 2026-10-14 00:00:00 UTC
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0008"
down_revision: str | None = "0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

UUID = postgresql.UUID(as_uuid=True)
TZ = sa.DateTime(timezone=True)


def _role_block(role: str, statements: str) -> str:
    return f"""
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}') THEN{statements}
  END IF;"""


_GRANT = f"""
DO $$
BEGIN{
    _role_block(
        "afterme_api",
        '''
    GRANT INSERT ON notification_logs TO afterme_api;
    EXECUTE format('GRANT USAGE ON SEQUENCE %s TO afterme_api',
                   pg_get_serial_sequence('public.notification_logs', 'id'));
    GRANT SELECT, INSERT ON email_receipts TO afterme_api;''',
    )
}{_role_block("afterme_worker", "\n    GRANT SELECT, INSERT ON email_receipts TO afterme_worker;")}{
    _role_block(
        "afterme_maintenance",
        '''
    GRANT DELETE ON email_receipts TO afterme_maintenance;
    GRANT SELECT (id, sent_at) ON email_receipts TO afterme_maintenance;
    GRANT SELECT (incident_id) ON notifications TO afterme_maintenance;
    GRANT SELECT (id, status) ON escalation_incidents TO afterme_maintenance;''',
    )
}
END
$$;
"""

_REVOKE = f"""
DO $$
BEGIN{
    _role_block(
        "afterme_api",
        '''
    REVOKE INSERT ON notification_logs FROM afterme_api;
    EXECUTE format('REVOKE USAGE ON SEQUENCE %s FROM afterme_api',
                   pg_get_serial_sequence('public.notification_logs', 'id'));
    REVOKE ALL ON email_receipts FROM afterme_api;''',
    )
}{_role_block("afterme_worker", "\n    REVOKE ALL ON email_receipts FROM afterme_worker;")}{
    _role_block(
        "afterme_maintenance",
        '''
    REVOKE ALL ON email_receipts FROM afterme_maintenance;
    REVOKE SELECT (incident_id) ON notifications FROM afterme_maintenance;
    REVOKE SELECT (id, status) ON escalation_incidents FROM afterme_maintenance;''',
    )
}
END
$$;
"""

_GUARD = """
CREATE OR REPLACE FUNCTION afterme_guard_api_log_insert() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  -- The API role records provider webhook events, which carry the provider's event id. The
  -- dispatcher's attempt log (no event id) is the worker's: the API cannot forge one.
  IF current_user = 'afterme_api' AND NEW.provider_event_id IS NULL THEN
    RAISE EXCEPTION 'the API role writes provider events only' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$fn$;

CREATE TRIGGER afterme_guard_log_insert BEFORE INSERT ON notification_logs
  FOR EACH ROW EXECUTE FUNCTION afterme_guard_api_log_insert();
"""

_UNGUARD = """
DROP TRIGGER IF EXISTS afterme_guard_log_insert ON notification_logs;
DROP FUNCTION IF EXISTS afterme_guard_api_log_insert();
"""


def upgrade() -> None:
    op.add_column("notification_logs", sa.Column("provider_event_id", sa.Text(), nullable=True))
    op.create_index(
        "uq_notification_logs_event",
        "notification_logs",
        ["provider", "provider_event_id"],
        unique=True,
        postgresql_where=sa.text("provider_event_id IS NOT NULL"),
    )
    op.create_table(
        "email_receipts",
        sa.Column("id", UUID, server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("contact_id", UUID, nullable=False),
        sa.Column("template_key", sa.Text(), nullable=False),
        sa.Column("provider", sa.Text(), nullable=False),
        sa.Column("provider_message_id", sa.Text(), nullable=False),
        sa.Column("sent_at", TZ, server_default=sa.text("now()"), nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_email_receipts")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_email_receipts_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["contact_id"],
            ["trusted_contacts.id"],
            name=op.f("fk_email_receipts_contact_id_trusted_contacts"),
            ondelete="CASCADE",
        ),
    )
    op.create_index(
        "uq_email_receipts_message",
        "email_receipts",
        ["provider", "provider_message_id"],
        unique=True,
    )
    op.create_index("ix_email_receipts_sent", "email_receipts", ["sent_at"])
    op.execute(_GUARD)
    op.execute(_GRANT)


def downgrade() -> None:
    op.execute(_REVOKE)
    op.execute(_UNGUARD)
    op.drop_index("ix_email_receipts_sent", table_name="email_receipts")
    op.drop_index("uq_email_receipts_message", table_name="email_receipts")
    op.drop_table("email_receipts")
    op.drop_index("uq_notification_logs_event", table_name="notification_logs")
    op.drop_column("notification_logs", "provider_event_id")
