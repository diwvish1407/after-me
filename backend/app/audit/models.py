"""Append-only audit log (DATABASE §3.9). No foreign keys, so history survives account deletion.

The API and worker roles have INSERT and SELECT only (granted in the migration)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import BigInteger, Boolean, CheckConstraint, Identity, Index, Text, text
from sqlalchemy.dialects.postgresql import BYTEA, JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, in_list

ACTOR_TYPES = ("user", "contact", "system", "operator")


class AuditLog(Base):
    __tablename__ = "audit_logs"
    __table_args__ = (
        CheckConstraint(in_list("actor_type", ACTOR_TYPES), name="actor_type"),
        Index("ix_audit_subject_time", "subject_user_id", text("occurred_at DESC")),
        Index("ix_audit_action_time", "action", text("occurred_at DESC")),
        # The retention purge reads the oldest rows of every account (migration 0011).
        Index("ix_audit_occurred", "occurred_at"),
    )

    id: Mapped[int] = mapped_column(BigInteger, Identity(always=True), primary_key=True)
    occurred_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    actor_type: Mapped[str] = mapped_column(Text)
    actor_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    subject_user_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))  # no FK
    action: Mapped[str] = mapped_column(Text)
    resource_type: Mapped[str | None] = mapped_column(Text)
    resource_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    request_id: Mapped[str | None] = mapped_column(Text)
    ip_hash: Mapped[bytes | None] = mapped_column(BYTEA)
    user_visible: Mapped[bool] = mapped_column(Boolean, server_default=text("false"))
    # "metadata" is reserved on declarative classes, hence the attribute name.
    metadata_: Mapped[dict[str, Any]] = mapped_column(
        "metadata", JSONB, server_default=text("'{}'::jsonb")
    )
