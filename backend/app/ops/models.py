"""System Hold, ingestion probes and service heartbeats (DATABASE §3.11; ESCALATION_ENGINE §7)."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import BigInteger, CheckConstraint, Identity, Index, Text, text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, in_list

HOLD_REASONS = ("ingestion", "anomaly", "operator")


class SystemHold(Base):
    """A circuit-breaker window. ``started_at`` may be backdated to the last good probe."""

    __tablename__ = "system_holds"
    __table_args__ = (
        CheckConstraint(in_list("reason", HOLD_REASONS), name="reason"),
        Index("ix_system_holds_open", "started_at", postgresql_where=text("ended_at IS NULL")),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    reason: Mapped[str] = mapped_column(Text)
    started_at: Mapped[datetime]
    detected_at: Mapped[datetime]
    ended_at: Mapped[datetime | None]
    exit_processed_at: Mapped[datetime | None]  # rollback and shift applied
    created_by: Mapped[str] = mapped_column(Text)
    notes: Mapped[str | None] = mapped_column(Text)


class IngestionProbe(Base):
    __tablename__ = "ingestion_probes"
    __table_args__ = (Index("ix_ingestion_probes_time", "received_at"),)

    id: Mapped[int] = mapped_column(BigInteger, Identity(always=True), primary_key=True)
    received_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    source: Mapped[str] = mapped_column(Text)


class ServiceHeartbeat(Base):
    __tablename__ = "service_heartbeats"

    service: Mapped[str] = mapped_column(Text, primary_key=True)
    instance_id: Mapped[str] = mapped_column(Text, primary_key=True)
    last_beat_at: Mapped[datetime]
    started_at: Mapped[datetime]
    version: Mapped[str] = mapped_column(Text)
