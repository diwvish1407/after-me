"""Instructions and who receives them (DATABASE §3.5).

An instruction's title and body exist only as ciphertext (``content_ciphertext``, sealed with
the owner's key and bound to this row by the additional authenticated data). The worker role
cannot read that column at all.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    Integer,
    LargeBinary,
    SmallInteger,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base

INSTRUCTION_STATUSES = ("active", "inactive")
# The seed of ``instruction_categories`` (the migration carries its own copy; a test pins them).
CATEGORY_SEED: tuple[tuple[str, int], ...] = (
    ("personal", 1),
    ("family", 2),
    ("home", 3),
    ("work", 4),
    ("business", 5),
    ("documents", 6),
    ("insurance", 7),
    ("pets", 8),
    ("travel", 9),
    ("digital_accounts", 10),
    ("other", 11),
)
TITLE_MAX = 120
BODY_MAX = 20_000


class InstructionCategory(Base):
    __tablename__ = "instruction_categories"
    __table_args__ = (CheckConstraint("id ~ '^[a-z_]{2,32}$'", name="id"),)

    id: Mapped[str] = mapped_column(Text, primary_key=True)
    sort_order: Mapped[int] = mapped_column(SmallInteger)
    is_active: Mapped[bool] = mapped_column(Boolean, server_default=text("true"))


class Instruction(Base):
    __tablename__ = "instructions"
    __table_args__ = (
        CheckConstraint("status IN ('active','inactive')", name="status"),
        CheckConstraint("deleted_at IS NOT NULL OR content_ciphertext IS NOT NULL", name="content"),
        CheckConstraint("content_key_version >= 1", name="key_version"),
        UniqueConstraint("id", "user_id", name="uq_instructions_id_user"),
        Index("ix_instructions_user", "user_id", postgresql_where=text("deleted_at IS NULL")),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    category_id: Mapped[str] = mapped_column(Text, ForeignKey("instruction_categories.id"))
    status: Mapped[str] = mapped_column(Text, server_default=text("'active'"))
    content_ciphertext: Mapped[bytes | None] = mapped_column(LargeBinary)
    content_key_version: Mapped[int] = mapped_column(Integer)
    content_version: Mapped[int] = mapped_column(Integer, server_default=text("1"))
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    updated_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    deleted_at: Mapped[datetime | None]


class InstructionRecipient(Base):
    """WHO gets WHAT, WHEN. A stage cannot be removed while an instruction is assigned to it
    (the foreign key is deferred to commit: refused then, and robust to the order a whole
    account's rows are deleted in)."""

    __tablename__ = "instruction_recipients"
    __table_args__ = (
        UniqueConstraint(
            "instruction_id", "contact_id", name="uq_instruction_recipients_instruction_contact"
        ),
        ForeignKeyConstraint(
            ["instruction_id", "user_id"],
            ["instructions.id", "instructions.user_id"],
            ondelete="CASCADE",
        ),
        ForeignKeyConstraint(
            ["contact_id", "user_id"],
            ["trusted_contacts.id", "trusted_contacts.user_id"],
            ondelete="CASCADE",
        ),
        ForeignKeyConstraint(
            ["release_step_id", "user_id"],
            ["escalation_steps.id", "escalation_steps.user_id"],
            deferrable=True,
            initially="DEFERRED",
        ),
        Index("ix_instruction_recipients_step", "release_step_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    instruction_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True))
    contact_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True))
    release_step_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True))
    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True))
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    updated_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
