"""Check-in configuration and check-in events (DATABASE §3.3).

Phase 1 creates the configuration row at signup verification with ``status = 'inactive'``; Phase 4
adds scheduling and the check-in history. The configuration row is also the per-user lock row
(ESCALATION_ENGINE §6.2)."""

from __future__ import annotations

import uuid
from datetime import datetime, time
from typing import Any

from sqlalchemy import (
    CheckConstraint,
    ForeignKey,
    Index,
    Integer,
    SmallInteger,
    Text,
    Time,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column
from sqlalchemy.sql.naming import conv

from app.core.db import Base, in_list

CHECKIN_STATUSES = ("inactive", "active", "incident_open")
CHECKIN_EVENT_KINDS = ("ok", "safe")
CHECKIN_SOURCES = ("app", "web")
IDEMPOTENCY_KEY_MIN = 16
IDEMPOTENCY_KEY_MAX = 64


class CheckinConfiguration(Base):
    __tablename__ = "checkin_configurations"
    __table_args__ = (
        CheckConstraint("interval_days BETWEEN 1 AND 30", name="interval_days"),
        CheckConstraint(
            "interval_minutes IS NULL OR interval_minutes BETWEEN 1 AND 43200",
            name="interval_minutes",
        ),
        CheckConstraint("reminder_lead_minutes BETWEEN 0 AND 1440", name="reminder_lead_minutes"),
        CheckConstraint(in_list("status", CHECKIN_STATUSES), name="status"),
        CheckConstraint(
            "status = 'inactive' OR (next_due_at IS NOT NULL AND baseline_at IS NOT NULL)",
            name=conv("ck_checkin_cfg_active_has_due"),
        ),
        Index("ix_checkin_cfg_due", "next_due_at", postgresql_where=text("status = 'active'")),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    interval_days: Mapped[int] = mapped_column(SmallInteger, server_default=text("1"))
    # When set, the next deadline is the baseline plus this many minutes (a custom interval);
    # otherwise ``interval_days`` at ``due_local_time``.
    interval_minutes: Mapped[int | None] = mapped_column(Integer)
    due_local_time: Mapped[time] = mapped_column(Time, server_default=text("'20:00'"))
    reminder_lead_minutes: Mapped[int] = mapped_column(SmallInteger, server_default=text("60"))
    status: Mapped[str] = mapped_column(Text, server_default=text("'inactive'"))
    baseline_at: Mapped[datetime | None]  # last check-in or schedule change
    last_checkin_at: Mapped[datetime | None]
    # The earliest deadline of all the person's check-in events: what the engine watches.
    next_due_at: Mapped[datetime | None]
    # The primary event's own deadline (the fields above), and which event ``next_due_at``
    # belongs to (``None``: the primary one; otherwise a ``checkin_slots`` row).
    primary_due_at: Mapped[datetime | None]
    # Not a foreign key (the two tables would reference each other): every write of a slot
    # happens under the lock on this row and re-syncs it (app/checkins/slots.py).
    due_slot_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    activated_at: Mapped[datetime | None]
    version: Mapped[int] = mapped_column(Integer, server_default=text("1"))
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    updated_at: Mapped[datetime] = mapped_column(server_default=text("now()"))


class CheckinEvent(Base):
    """One recorded I'M OK (or, from Phase 5, I'M SAFE). Append-only: the API and worker roles
    have INSERT and SELECT only. ``response_snapshot`` is the exact body returned to the caller,
    replayed verbatim when the same ``(user_id, idempotency_key)`` arrives again."""

    __tablename__ = "checkin_events"
    __table_args__ = (
        CheckConstraint(in_list("kind", CHECKIN_EVENT_KINDS), name="kind"),
        CheckConstraint(in_list("source", CHECKIN_SOURCES), name="source"),
        CheckConstraint(
            f"char_length(idempotency_key) BETWEEN {IDEMPOTENCY_KEY_MIN} AND {IDEMPOTENCY_KEY_MAX}",
            name="idempotency_key_length",
        ),
        UniqueConstraint("user_id", "idempotency_key", name="uq_checkin_events_idem"),
        Index("ix_checkin_events_user_time", "user_id", text("received_at DESC")),
        # Performance (migration 0011; backend/tests/perf/PLANS.md): the retention purge reads
        # the oldest rows, and ON DELETE SET NULL of a session or a device must find its rows.
        Index("ix_checkin_events_received_at", "received_at"),
        Index(
            "ix_checkin_events_session",
            "session_id",
            postgresql_where=text("session_id IS NOT NULL"),
        ),
        Index(
            "ix_checkin_events_device",
            "device_id",
            postgresql_where=text("device_id IS NOT NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    kind: Mapped[str] = mapped_column(Text)
    source: Mapped[str] = mapped_column(Text)
    received_at: Mapped[datetime]  # the database clock: authoritative (INV-3)
    client_reported_at: Mapped[datetime | None]  # informational only, never used in a decision
    idempotency_key: Mapped[str] = mapped_column(Text)
    session_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("sessions.id", ondelete="SET NULL")
    )
    device_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("devices.id", ondelete="SET NULL")
    )
    incident_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("escalation_incidents.id", ondelete="SET NULL")
    )
    response_snapshot: Mapped[dict[str, Any]] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))


MAX_EXTRA_SLOTS = 5
SLOT_LABEL_MAX = 60


class CheckinSlot(Base):
    """An additional daily (or every-N-days, or every-N-minutes) check-in event, next to the
    primary one held in ``checkin_configurations``. Each event may have its own escalation plan
    (``escalation_plans.slot_id``); without one the default plan applies. The per-user lock is
    still the configuration row: every change to a slot happens under it."""

    __tablename__ = "checkin_slots"
    __table_args__ = (
        CheckConstraint("interval_days BETWEEN 1 AND 30", name="interval_days"),
        CheckConstraint(
            "interval_minutes IS NULL OR interval_minutes BETWEEN 1 AND 43200",
            name="interval_minutes",
        ),
        CheckConstraint(f"char_length(label) BETWEEN 1 AND {SLOT_LABEL_MAX}", name="label_length"),
        UniqueConstraint("id", "user_id", name="uq_checkin_slots_id_user"),
        Index("ix_checkin_slots_user", "user_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    label: Mapped[str] = mapped_column(Text)
    interval_days: Mapped[int] = mapped_column(SmallInteger, server_default=text("1"))
    interval_minutes: Mapped[int | None] = mapped_column(Integer)
    due_local_time: Mapped[time] = mapped_column(Time)
    next_due_at: Mapped[datetime | None]
    # Removed events are kept (never hard-deleted): their plan may be referenced by past
    # incidents, and incidents must never disappear with it.
    deleted_at: Mapped[datetime | None]
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    updated_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
