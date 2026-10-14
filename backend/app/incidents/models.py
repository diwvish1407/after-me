"""Incidents and their materialised timeline (DATABASE §3.6; ESCALATION_ENGINE §4, §5).

Only the engine worker inserts these rows (INV-1): the API role has no INSERT privilege on
either table, and only column-limited UPDATEs that *stop* or *observe* things.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    CheckConstraint,
    ForeignKey,
    Index,
    Integer,
    SmallInteger,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, in_list

OPEN_STATUSES = ("grace", "escalating", "escalated")
CLOSED_STATUSES = ("resolved", "cancelled", "voided")
INCIDENT_STATUSES = OPEN_STATUSES + CLOSED_STATUSES
CLOSED_BY = ("user_checkin", "user_safe", "account_deleted", "operator_void")

ACTION_KINDS = ("user_reminder", "user_final_warning", "execute_stage")
ACTION_VARIANTS = ("missed", "midpoint", "last_chance")
ACTION_STATUSES = ("pending", "executed", "cancelled", "held")


class EscalationIncident(Base):
    __tablename__ = "escalation_incidents"
    __table_args__ = (
        CheckConstraint(in_list("status", INCIDENT_STATUSES), name="status"),
        CheckConstraint(in_list("closed_by", CLOSED_BY), name="closed_by"),
        CheckConstraint(
            "(status IN ('resolved', 'cancelled', 'voided')) = (closed_at IS NOT NULL)",
            name="closed",
        ),
        CheckConstraint("anchor_at >= missed_due_at AND anchor_at >= opened_at", name="anchor"),
        UniqueConstraint("user_id", "missed_due_at", name="uq_incidents_user_missed"),
        Index(
            "uq_incidents_one_open",
            "user_id",
            unique=True,
            postgresql_where=text("status IN ('grace', 'escalating', 'escalated')"),
        ),
        # Hold's anomaly check counts the incidents opened in the last hour, every tick, and
        # compares with the same hour of earlier days (migration 0011).
        Index("ix_incidents_opened", "opened_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    plan_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("escalation_plans.id", ondelete="CASCADE")
    )
    plan_version: Mapped[int] = mapped_column(Integer)
    plan_snapshot: Mapped[dict[str, Any]] = mapped_column(JSONB)  # IDs only (§5.4)
    missed_due_at: Mapped[datetime]
    opened_at: Mapped[datetime]
    anchor_at: Mapped[datetime]
    grace_ends_at: Mapped[datetime]
    status: Mapped[str] = mapped_column(Text, server_default=text("'grace'"))
    contacts_messaged_at: Mapped[datetime | None]  # set by the dispatcher (§4.2)
    closed_at: Mapped[datetime | None]
    closed_by: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    updated_at: Mapped[datetime] = mapped_column(server_default=text("now()"))


class IncidentAction(Base):
    __tablename__ = "incident_actions"
    __table_args__ = (
        CheckConstraint(in_list("kind", ACTION_KINDS), name="kind"),
        CheckConstraint(in_list("variant", ACTION_VARIANTS), name="variant"),
        CheckConstraint(in_list("status", ACTION_STATUSES), name="status"),
        Index(
            "ix_incident_actions_due",
            "scheduled_for",
            postgresql_where=text("status = 'pending'"),
        ),
        Index("ix_incident_actions_incident", "incident_id"),
        # One person's due actions (``EngineStore.due_actions``): without it every unit of work
        # of a tick reads every due action of every person (migration 0011).
        Index(
            "ix_incident_actions_user_pending",
            "user_id",
            "scheduled_for",
            postgresql_where=text("status = 'pending'"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    incident_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("escalation_incidents.id", ondelete="CASCADE")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    kind: Mapped[str] = mapped_column(Text)
    variant: Mapped[str | None] = mapped_column(Text)
    step_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))  # from the snapshot
    scheduled_for: Mapped[datetime]
    original_scheduled_for: Mapped[datetime]  # before any Hold shift
    status: Mapped[str] = mapped_column(Text, server_default=text("'pending'"))
    attempt_count: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    last_error_class: Mapped[str | None] = mapped_column(Text)  # class name only
    executed_at: Mapped[datetime | None]
    outcome: Mapped[dict[str, Any] | None] = mapped_column(JSONB)  # IDs + reason codes
    dedupe_key: Mapped[str] = mapped_column(Text, unique=True)
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    updated_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
