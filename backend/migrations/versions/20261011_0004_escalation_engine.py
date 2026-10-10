"""Escalation plan, incidents and timeline, notification outbox, Hold and worker liveness.

Phase 5 tables (DATABASE §3.4, §3.6, §3.8, §3.11): ``escalation_plans``, ``escalation_steps``,
``escalation_step_contacts``, ``escalation_incidents``, ``incident_actions``, ``notifications``,
``notification_logs``, ``system_holds``, ``ingestion_probes`` and ``service_heartbeats``; plus the
foreign key from ``checkin_events.incident_id`` that Phase 4 left open.

Grants (DATABASE §6) are what makes INV-1 (backend authority) a property of the database and not
only of the code. They are applied only to roles that exist (scripts/dev_db_setup.sh creates them):

* afterme_api: may edit the plan (DML on the three plan tables); may only *stop or observe*
  incidents: **no INSERT** on ``escalation_incidents`` or ``incident_actions``, and UPDATE
  limited to ``status``/``closed_at``/``closed_by``/``updated_at`` (incidents) and
  ``status``/``updated_at`` (actions). May INSERT notifications (the all-clear, security
  mail) and cancel queued ones; may INSERT probes. Cannot touch Hold or heartbeats.
* afterme_worker: DML on everything the engine owns; reads the user's plan and contacts.
* afterme_maintenance: DELETE (with the two columns the purge filters on) for probes (30 days)
  and notifications (90 days).

Revision ID: 0004
Revises: 0003
Create Date: 2026-10-11 00:00:00 UTC
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0004"
down_revision: str | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

TZ = sa.DateTime(timezone=True)
UUID = postgresql.UUID(as_uuid=True)
NOW = sa.text("now()")
GEN_UUID = sa.text("gen_random_uuid()")


def _role_block(role: str, statements: str) -> str:
    return f"""
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}') THEN{statements}
  END IF;"""


def _grant_sql() -> str:
    api = """
    GRANT SELECT, INSERT, UPDATE, DELETE ON escalation_plans, escalation_steps,
          escalation_step_contacts TO afterme_api;
    GRANT SELECT ON escalation_incidents, incident_actions, notification_logs,
          system_holds TO afterme_api;
    GRANT UPDATE (status, closed_at, closed_by, updated_at) ON escalation_incidents
          TO afterme_api;
    GRANT UPDATE (status, updated_at) ON incident_actions TO afterme_api;
    GRANT SELECT, INSERT ON notifications TO afterme_api;
    GRANT UPDATE (status, cancelled_reason, updated_at) ON notifications TO afterme_api;
    GRANT INSERT ON ingestion_probes TO afterme_api;
    EXECUTE format('GRANT USAGE ON SEQUENCE %s TO afterme_api',
                   pg_get_serial_sequence('public.ingestion_probes', 'id'));"""
    worker = """
    GRANT SELECT, INSERT, UPDATE, DELETE ON escalation_plans, escalation_steps,
          escalation_step_contacts, escalation_incidents, incident_actions, notifications,
          system_holds, service_heartbeats TO afterme_worker;
    GRANT SELECT, INSERT ON notification_logs TO afterme_worker;
    GRANT SELECT ON ingestion_probes TO afterme_worker;
    EXECUTE format('GRANT USAGE ON SEQUENCE %s TO afterme_worker',
                   pg_get_serial_sequence('public.notification_logs', 'id'));"""
    maintenance = """
    GRANT DELETE ON ingestion_probes, notifications, notification_logs
          TO afterme_maintenance;
    GRANT SELECT (id, received_at) ON ingestion_probes TO afterme_maintenance;
    GRANT SELECT (id, created_at) ON notifications TO afterme_maintenance;
    GRANT SELECT (id, attempted_at) ON notification_logs TO afterme_maintenance;"""
    return f"""
DO $$
BEGIN{_role_block("afterme_api", api)}{_role_block("afterme_worker", worker)}{
        _role_block("afterme_maintenance", maintenance)
    }
END
$$;
"""


def _revoke_sql() -> str:
    tables = (
        "escalation_plans, escalation_steps, escalation_step_contacts, escalation_incidents, "
        "incident_actions, notifications, notification_logs, system_holds, ingestion_probes, "
        "service_heartbeats"
    )
    api = f"""
    REVOKE ALL ON {tables} FROM afterme_api;"""
    worker = f"""
    REVOKE ALL ON {tables} FROM afterme_worker;"""
    maintenance = f"""
    REVOKE ALL ON {tables} FROM afterme_maintenance;"""
    return f"""
DO $$
BEGIN{_role_block("afterme_api", api)}{_role_block("afterme_worker", worker)}{
        _role_block("afterme_maintenance", maintenance)
    }
END
$$;
"""


def upgrade() -> None:
    # --- escalation_plans / steps / step contacts --------------------------------------------
    op.create_table(
        "escalation_plans",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("grace_minutes", sa.Integer(), server_default=sa.text("180"), nullable=False),
        sa.Column("version", sa.Integer(), server_default=sa.text("1"), nullable=False),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("updated_at", TZ, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_escalation_plans")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_escalation_plans_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint("user_id", name="uq_escalation_plans_user"),
        sa.CheckConstraint(
            "grace_minutes BETWEEN 60 AND 4320",
            name=op.f("ck_escalation_plans_grace_minutes"),
        ),
    )
    op.create_table(
        "escalation_steps",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("plan_id", UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("position", sa.SmallInteger(), nullable=False),
        sa.Column("offset_minutes", sa.Integer(), nullable=False),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("updated_at", TZ, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_escalation_steps")),
        sa.ForeignKeyConstraint(
            ["plan_id"],
            ["escalation_plans.id"],
            name=op.f("fk_escalation_steps_plan_id_escalation_plans"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_escalation_steps_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint("id", "user_id", name="uq_escalation_steps_id_user"),
        sa.UniqueConstraint(
            "plan_id",
            "position",
            name="uq_escalation_steps_position",
            deferrable=True,
            initially="DEFERRED",
        ),
        sa.UniqueConstraint(
            "plan_id",
            "offset_minutes",
            name="uq_escalation_steps_offset",
            deferrable=True,
            initially="DEFERRED",
        ),
        sa.CheckConstraint("position >= 1", name=op.f("ck_escalation_steps_position")),
        sa.CheckConstraint(
            "offset_minutes BETWEEN 60 AND 43200",
            name=op.f("ck_escalation_steps_offset_minutes"),
        ),
    )
    op.create_table(
        "escalation_step_contacts",
        sa.Column("step_id", UUID, nullable=False),
        sa.Column("contact_id", UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.PrimaryKeyConstraint("step_id", "contact_id", name="pk_escalation_step_contacts"),
        sa.ForeignKeyConstraint(
            ["step_id", "user_id"],
            ["escalation_steps.id", "escalation_steps.user_id"],
            name=op.f("fk_escalation_step_contacts_step_id_user_id_escalation_steps"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["contact_id", "user_id"],
            ["trusted_contacts.id", "trusted_contacts.user_id"],
            name=op.f("fk_escalation_step_contacts_contact_id_user_id_trusted_contacts"),
            ondelete="CASCADE",
        ),
    )

    # --- escalation_incidents ----------------------------------------------------------------
    op.create_table(
        "escalation_incidents",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("plan_id", UUID, nullable=False),
        sa.Column("plan_version", sa.Integer(), nullable=False),
        sa.Column("plan_snapshot", postgresql.JSONB(), nullable=False),
        sa.Column("missed_due_at", TZ, nullable=False),
        sa.Column("opened_at", TZ, nullable=False),
        sa.Column("anchor_at", TZ, nullable=False),
        sa.Column("grace_ends_at", TZ, nullable=False),
        sa.Column("status", sa.Text(), server_default=sa.text("'grace'"), nullable=False),
        sa.Column("contacts_messaged_at", TZ, nullable=True),
        sa.Column("closed_at", TZ, nullable=True),
        sa.Column("closed_by", sa.Text(), nullable=True),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("updated_at", TZ, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_escalation_incidents")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_escalation_incidents_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["plan_id"],
            ["escalation_plans.id"],
            name=op.f("fk_escalation_incidents_plan_id_escalation_plans"),
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint("user_id", "missed_due_at", name="uq_incidents_user_missed"),
        sa.CheckConstraint(
            "status IN ('grace', 'escalating', 'escalated', 'resolved', 'cancelled', 'voided')",
            name=op.f("ck_escalation_incidents_status"),
        ),
        sa.CheckConstraint(
            "closed_by IN ('user_checkin', 'user_safe', 'account_deleted', 'operator_void')",
            name=op.f("ck_escalation_incidents_closed_by"),
        ),
        sa.CheckConstraint(
            "(status IN ('resolved', 'cancelled', 'voided')) = (closed_at IS NOT NULL)",
            name=op.f("ck_escalation_incidents_closed"),
        ),
        sa.CheckConstraint(
            "anchor_at >= missed_due_at AND anchor_at >= opened_at",
            name=op.f("ck_escalation_incidents_anchor"),
        ),
    )
    op.create_index(
        "uq_incidents_one_open",
        "escalation_incidents",
        ["user_id"],
        unique=True,
        postgresql_where=sa.text("status IN ('grace', 'escalating', 'escalated')"),
    )
    op.create_foreign_key(
        op.f("fk_checkin_events_incident_id_escalation_incidents"),
        "checkin_events",
        "escalation_incidents",
        ["incident_id"],
        ["id"],
        ondelete="SET NULL",
    )

    # --- incident_actions --------------------------------------------------------------------
    op.create_table(
        "incident_actions",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("incident_id", UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("variant", sa.Text(), nullable=True),
        sa.Column("step_id", UUID, nullable=True),
        sa.Column("scheduled_for", TZ, nullable=False),
        sa.Column("original_scheduled_for", TZ, nullable=False),
        sa.Column("status", sa.Text(), server_default=sa.text("'pending'"), nullable=False),
        sa.Column("attempt_count", sa.SmallInteger(), server_default=sa.text("0"), nullable=False),
        sa.Column("last_error_class", sa.Text(), nullable=True),
        sa.Column("executed_at", TZ, nullable=True),
        sa.Column("outcome", postgresql.JSONB(), nullable=True),
        sa.Column("dedupe_key", sa.Text(), nullable=False),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("updated_at", TZ, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_incident_actions")),
        sa.ForeignKeyConstraint(
            ["incident_id"],
            ["escalation_incidents.id"],
            name=op.f("fk_incident_actions_incident_id_escalation_incidents"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_incident_actions_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint("dedupe_key", name=op.f("uq_incident_actions_dedupe_key")),
        sa.CheckConstraint(
            "kind IN ('user_reminder', 'user_final_warning', 'execute_stage')",
            name=op.f("ck_incident_actions_kind"),
        ),
        sa.CheckConstraint(
            "variant IN ('missed', 'midpoint', 'last_chance')",
            name=op.f("ck_incident_actions_variant"),
        ),
        sa.CheckConstraint(
            "status IN ('pending', 'executed', 'cancelled', 'held')",
            name=op.f("ck_incident_actions_status"),
        ),
    )
    op.create_index(
        "ix_incident_actions_due",
        "incident_actions",
        ["scheduled_for"],
        postgresql_where=sa.text("status = 'pending'"),
    )
    op.create_index("ix_incident_actions_incident", "incident_actions", ["incident_id"])

    # --- notifications (outbox) and their log ------------------------------------------------
    op.create_table(
        "notifications",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("audience", sa.Text(), nullable=False),
        sa.Column("category", sa.Text(), nullable=False),
        sa.Column("contact_id", UUID, nullable=True),
        sa.Column("device_id", UUID, nullable=True),
        sa.Column("channel", sa.Text(), nullable=False),
        sa.Column("template_key", sa.Text(), nullable=False),
        sa.Column(
            "template_version", sa.SmallInteger(), server_default=sa.text("1"), nullable=False
        ),
        sa.Column(
            "params",
            postgresql.JSONB(),
            server_default=sa.text("'{}'::jsonb"),
            nullable=False,
        ),
        sa.Column("incident_id", UUID, nullable=True),
        sa.Column("action_id", UUID, nullable=True),
        sa.Column("status", sa.Text(), server_default=sa.text("'queued'"), nullable=False),
        sa.Column("send_after", TZ, nullable=False),
        sa.Column("attempt_count", sa.SmallInteger(), server_default=sa.text("0"), nullable=False),
        sa.Column("next_attempt_at", TZ, nullable=True),
        sa.Column("provider", sa.Text(), nullable=True),
        sa.Column("provider_message_id", sa.Text(), nullable=True),
        sa.Column("cancelled_reason", sa.Text(), nullable=True),
        sa.Column("dedupe_key", sa.Text(), nullable=False),
        sa.Column("created_at", TZ, server_default=NOW, nullable=False),
        sa.Column("updated_at", TZ, server_default=NOW, nullable=False),
        sa.Column("sent_at", TZ, nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_notifications")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_notifications_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["contact_id"],
            ["trusted_contacts.id"],
            name=op.f("fk_notifications_contact_id_trusted_contacts"),
        ),
        sa.ForeignKeyConstraint(
            ["device_id"],
            ["devices.id"],
            name=op.f("fk_notifications_device_id_devices"),
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["incident_id"],
            ["escalation_incidents.id"],
            name=op.f("fk_notifications_incident_id_escalation_incidents"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["action_id"],
            ["incident_actions.id"],
            name=op.f("fk_notifications_action_id_incident_actions"),
            ondelete="SET NULL",
        ),
        sa.UniqueConstraint("dedupe_key", name=op.f("uq_notifications_dedupe_key")),
        sa.CheckConstraint(
            "audience IN ('user', 'contact')", name=op.f("ck_notifications_audience")
        ),
        sa.CheckConstraint(
            "category IN ('user', 'contact_escalation', 'contact_other')",
            name=op.f("ck_notifications_category"),
        ),
        sa.CheckConstraint(
            "channel IN ('push', 'email', 'sms')", name=op.f("ck_notifications_channel")
        ),
        sa.CheckConstraint(
            "status IN ('queued', 'sending', 'sent', 'failed', 'cancelled')",
            name=op.f("ck_notifications_status"),
        ),
        sa.CheckConstraint(
            "(audience = 'contact') = (contact_id IS NOT NULL)",
            name=op.f("ck_notifications_contact"),
        ),
        sa.CheckConstraint(
            "category <> 'contact_escalation' "
            "OR (incident_id IS NOT NULL AND action_id IS NOT NULL)",
            name=op.f("ck_notifications_escalation"),
        ),
    )
    op.create_index(
        "ix_notifications_due",
        "notifications",
        ["send_after"],
        postgresql_where=sa.text("status = 'queued'"),
    )
    op.create_index("ix_notifications_incident", "notifications", ["incident_id"])
    op.create_index(
        "ix_notifications_user_time",
        "notifications",
        ["user_id", sa.text("created_at DESC")],
    )
    op.create_table(
        "notification_logs",
        sa.Column("id", sa.BigInteger(), sa.Identity(always=True), nullable=False),
        sa.Column("notification_id", UUID, nullable=False),
        sa.Column("attempted_at", TZ, server_default=NOW, nullable=False),
        sa.Column("provider", sa.Text(), nullable=False),
        sa.Column("outcome", sa.Text(), nullable=False),
        sa.Column("provider_message_id", sa.Text(), nullable=True),
        sa.Column("error_code", sa.Text(), nullable=True),
        sa.Column("latency_ms", sa.SmallInteger(), nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_notification_logs")),
        sa.ForeignKeyConstraint(
            ["notification_id"],
            ["notifications.id"],
            name=op.f("fk_notification_logs_notification_id_notifications"),
            ondelete="CASCADE",
        ),
        sa.CheckConstraint(
            "outcome IN ('accepted', 'rejected', 'error', 'delivered', 'bounced', 'complained')",
            name=op.f("ck_notification_logs_outcome"),
        ),
    )
    op.create_index("ix_notification_logs_notification", "notification_logs", ["notification_id"])

    # --- Hold, probes and heartbeats ---------------------------------------------------------
    op.create_table(
        "system_holds",
        sa.Column("id", UUID, server_default=GEN_UUID, nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("started_at", TZ, nullable=False),
        sa.Column("detected_at", TZ, nullable=False),
        sa.Column("ended_at", TZ, nullable=True),
        sa.Column("exit_processed_at", TZ, nullable=True),
        sa.Column("created_by", sa.Text(), nullable=False),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_system_holds")),
        sa.CheckConstraint(
            "reason IN ('ingestion', 'anomaly', 'operator')",
            name=op.f("ck_system_holds_reason"),
        ),
    )
    op.create_index(
        "ix_system_holds_open",
        "system_holds",
        ["started_at"],
        postgresql_where=sa.text("ended_at IS NULL"),
    )
    op.create_table(
        "ingestion_probes",
        sa.Column("id", sa.BigInteger(), sa.Identity(always=True), nullable=False),
        sa.Column("received_at", TZ, server_default=NOW, nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_ingestion_probes")),
    )
    op.create_index("ix_ingestion_probes_time", "ingestion_probes", ["received_at"])
    op.create_table(
        "service_heartbeats",
        sa.Column("service", sa.Text(), nullable=False),
        sa.Column("instance_id", sa.Text(), nullable=False),
        sa.Column("last_beat_at", TZ, nullable=False),
        sa.Column("started_at", TZ, nullable=False),
        sa.Column("version", sa.Text(), nullable=False),
        sa.PrimaryKeyConstraint("service", "instance_id", name=op.f("pk_service_heartbeats")),
    )

    op.execute(_grant_sql())


def downgrade() -> None:
    op.execute(_revoke_sql())
    op.drop_table("service_heartbeats")
    op.drop_index("ix_ingestion_probes_time", table_name="ingestion_probes")
    op.drop_table("ingestion_probes")
    op.drop_index("ix_system_holds_open", table_name="system_holds")
    op.drop_table("system_holds")
    op.drop_index("ix_notification_logs_notification", table_name="notification_logs")
    op.drop_table("notification_logs")
    op.drop_index("ix_notifications_user_time", table_name="notifications")
    op.drop_index("ix_notifications_incident", table_name="notifications")
    op.drop_index("ix_notifications_due", table_name="notifications")
    op.drop_table("notifications")
    op.drop_index("ix_incident_actions_incident", table_name="incident_actions")
    op.drop_index("ix_incident_actions_due", table_name="incident_actions")
    op.drop_table("incident_actions")
    op.drop_constraint(
        op.f("fk_checkin_events_incident_id_escalation_incidents"),
        "checkin_events",
        type_="foreignkey",
    )
    op.drop_index("uq_incidents_one_open", table_name="escalation_incidents")
    op.drop_table("escalation_incidents")
    op.drop_table("escalation_step_contacts")
    op.drop_table("escalation_steps")
    op.drop_table("escalation_plans")
