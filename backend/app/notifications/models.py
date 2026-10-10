"""The notification outbox and its attempt log (DATABASE §3.8).

``params`` holds identifiers and times only: never content, names or addresses. Recipient
addresses are resolved at send time so opt-outs and edits are respected.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    ForeignKey,
    Identity,
    Index,
    SmallInteger,
    Text,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, in_list

AUDIENCES = ("user", "contact")
CATEGORIES = ("user", "contact_escalation", "contact_other")
CHANNELS = ("push", "email", "sms")
NOTIFICATION_STATUSES = ("queued", "sending", "sent", "failed", "cancelled")
LOG_OUTCOMES = ("accepted", "rejected", "error", "delivered", "bounced", "complained")


class Notification(Base):
    __tablename__ = "notifications"
    __table_args__ = (
        CheckConstraint(in_list("audience", AUDIENCES), name="audience"),
        CheckConstraint(in_list("category", CATEGORIES), name="category"),
        CheckConstraint(in_list("channel", CHANNELS), name="channel"),
        CheckConstraint(in_list("status", NOTIFICATION_STATUSES), name="status"),
        CheckConstraint("(audience = 'contact') = (contact_id IS NOT NULL)", name="contact"),
        CheckConstraint(
            "category <> 'contact_escalation' "
            "OR (incident_id IS NOT NULL AND action_id IS NOT NULL)",
            name="escalation",
        ),
        Index("ix_notifications_due", "send_after", postgresql_where=text("status = 'queued'")),
        Index("ix_notifications_incident", "incident_id"),
        Index("ix_notifications_user_time", "user_id", text("created_at DESC")),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    audience: Mapped[str] = mapped_column(Text)
    category: Mapped[str] = mapped_column(Text)
    contact_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("trusted_contacts.id")
    )
    device_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("devices.id", ondelete="SET NULL")
    )
    channel: Mapped[str] = mapped_column(Text)
    template_key: Mapped[str] = mapped_column(Text)
    template_version: Mapped[int] = mapped_column(SmallInteger, server_default=text("1"))
    params: Mapped[dict[str, Any]] = mapped_column(JSONB, server_default=text("'{}'::jsonb"))
    incident_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("escalation_incidents.id", ondelete="CASCADE")
    )
    action_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("incident_actions.id", ondelete="SET NULL")
    )
    status: Mapped[str] = mapped_column(Text, server_default=text("'queued'"))
    send_after: Mapped[datetime]
    attempt_count: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    next_attempt_at: Mapped[datetime | None]
    provider: Mapped[str | None] = mapped_column(Text)
    provider_message_id: Mapped[str | None] = mapped_column(Text)
    cancelled_reason: Mapped[str | None] = mapped_column(Text)
    dedupe_key: Mapped[str] = mapped_column(Text, unique=True)
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    updated_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    sent_at: Mapped[datetime | None]


class NotificationLog(Base):
    __tablename__ = "notification_logs"
    __table_args__ = (
        CheckConstraint(in_list("outcome", LOG_OUTCOMES), name="outcome"),
        Index("ix_notification_logs_notification", "notification_id"),
    )

    id: Mapped[int] = mapped_column(BigInteger, Identity(always=True), primary_key=True)
    notification_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("notifications.id", ondelete="CASCADE")
    )
    attempted_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    provider: Mapped[str] = mapped_column(Text)
    outcome: Mapped[str] = mapped_column(Text)
    provider_message_id: Mapped[str | None] = mapped_column(Text)
    error_code: Mapped[str | None] = mapped_column(Text)  # provider code only; no PII
    latency_ms: Mapped[int | None] = mapped_column(SmallInteger)
