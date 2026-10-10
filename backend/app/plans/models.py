"""The escalation plan: grace period, stages and who is notified at each (DATABASE §3.4).

Cross-row rules (stage 1 offset = grace, increasing offsets with gaps, tier limits) are enforced
by the service inside the plan-update transaction under the per-user lock, and re-checked by the
engine's safety gate; the database enforces the per-row bounds and the same-owner links.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    CheckConstraint,
    ForeignKey,
    ForeignKeyConstraint,
    Integer,
    PrimaryKeyConstraint,
    SmallInteger,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base

GRACE_DEFAULT_MINUTES = 180


class EscalationPlan(Base):
    __tablename__ = "escalation_plans"
    __table_args__ = (
        CheckConstraint("grace_minutes BETWEEN 60 AND 4320", name="grace_minutes"),
        UniqueConstraint("user_id", name="uq_escalation_plans_user"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    grace_minutes: Mapped[int] = mapped_column(
        Integer, server_default=text(str(GRACE_DEFAULT_MINUTES))
    )
    version: Mapped[int] = mapped_column(Integer, server_default=text("1"))
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    updated_at: Mapped[datetime] = mapped_column(server_default=text("now()"))


class EscalationStep(Base):
    """A stage ("step" in the database). ``user_id`` repeats the owner so that links to other
    tables can be same-owner composite foreign keys."""

    __tablename__ = "escalation_steps"
    __table_args__ = (
        CheckConstraint("position >= 1", name="position"),
        CheckConstraint("offset_minutes BETWEEN 60 AND 43200", name="offset_minutes"),
        UniqueConstraint("id", "user_id", name="uq_escalation_steps_id_user"),
        UniqueConstraint(
            "plan_id",
            "position",
            name="uq_escalation_steps_position",
            deferrable=True,
            initially="DEFERRED",
        ),
        UniqueConstraint(
            "plan_id",
            "offset_minutes",
            name="uq_escalation_steps_offset",
            deferrable=True,
            initially="DEFERRED",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    plan_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("escalation_plans.id", ondelete="CASCADE")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    position: Mapped[int] = mapped_column(SmallInteger)
    offset_minutes: Mapped[int] = mapped_column(Integer)
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    updated_at: Mapped[datetime] = mapped_column(server_default=text("now()"))


class EscalationStepContact(Base):
    """Who is NOTIFIED at a stage. Both links are same-owner composite foreign keys."""

    __tablename__ = "escalation_step_contacts"
    __table_args__ = (
        PrimaryKeyConstraint("step_id", "contact_id", name="pk_escalation_step_contacts"),
        ForeignKeyConstraint(
            ["step_id", "user_id"],
            ["escalation_steps.id", "escalation_steps.user_id"],
            ondelete="CASCADE",
        ),
        ForeignKeyConstraint(
            ["contact_id", "user_id"],
            ["trusted_contacts.id", "trusted_contacts.user_id"],
            ondelete="CASCADE",
        ),
    )

    step_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True))
    contact_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True))
    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True))
