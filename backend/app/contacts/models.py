"""Trusted contacts, invitations and the global suppression list (DATABASE §3.2)."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    CheckConstraint,
    ForeignKey,
    Index,
    SmallInteger,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import BYTEA, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, in_list
from app.users.models import PHONE_E164_SQL_PATTERN

RELATIONSHIPS = (
    "mother",
    "father",
    "parent",
    "spouse",
    "partner",
    "sibling",
    "child",
    "relative",
    "friend",
    "neighbor",
    "employer",
    "colleague",
    "other",
)
VERIFICATION_STATUSES = ("pending", "verified", "declined", "opted_out", "bounced")
VERIFICATION_RESPONSES = ("accepted", "declined")
SUPPRESSION_REASONS = ("contact_block_all", "hard_bounce", "complaint")
PRIORITY_MIN = 1
PRIORITY_MAX = 999


class TrustedContact(Base):
    __tablename__ = "trusted_contacts"
    __table_args__ = (
        CheckConstraint("char_length(display_name) BETWEEN 1 AND 80", name="display_name_length"),
        CheckConstraint(in_list("relationship", RELATIONSHIPS), name="relationship"),
        CheckConstraint("char_length(relationship_label) <= 40", name="relationship_label_length"),
        CheckConstraint("char_length(email) <= 254", name="email_length"),
        CheckConstraint(f"phone_e164 ~ '{PHONE_E164_SQL_PATTERN}'", name="phone_e164_format"),
        CheckConstraint(
            f"priority BETWEEN {PRIORITY_MIN} AND {PRIORITY_MAX}", name="priority_range"
        ),
        CheckConstraint(in_list("verification_status", VERIFICATION_STATUSES), name="status"),
        CheckConstraint("deleted_at IS NOT NULL OR email IS NOT NULL", name="email_present"),
        UniqueConstraint("id", "user_id", name="uq_trusted_contacts_id_user"),
        Index(
            "uq_trusted_contacts_user_email",
            "user_id",
            "email_normalized",
            unique=True,
            postgresql_where=text("deleted_at IS NULL"),
        ),
        Index("ix_trusted_contacts_user", "user_id", postgresql_where=text("deleted_at IS NULL")),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    display_name: Mapped[str] = mapped_column(Text)
    relationship: Mapped[str] = mapped_column(Text)
    relationship_label: Mapped[str | None] = mapped_column(Text)
    email: Mapped[str | None] = mapped_column(Text)
    email_normalized: Mapped[str | None] = mapped_column(Text)
    phone_e164: Mapped[str | None] = mapped_column(Text)
    priority: Mapped[int] = mapped_column(SmallInteger, server_default=text("100"))
    verification_status: Mapped[str] = mapped_column(Text, server_default=text("'pending'"))
    verified_at: Mapped[datetime | None]
    status_changed_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    is_active: Mapped[bool] = mapped_column(server_default=text("true"))
    invitation_sent_at: Mapped[datetime | None]
    invitation_send_count: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    updated_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    deleted_at: Mapped[datetime | None]


class ContactVerification(Base):
    """One invitation. ``token_hash`` is the SHA-256 of the emailed ``ci_`` token."""

    __tablename__ = "contact_verifications"
    __table_args__ = (
        CheckConstraint("channel IN ('email')", name="channel"),
        CheckConstraint(in_list("response", VERIFICATION_RESPONSES), name="response"),
        Index("ix_contact_verifications_contact", "contact_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    contact_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("trusted_contacts.id", ondelete="CASCADE")
    )
    channel: Mapped[str] = mapped_column(Text, server_default=text("'email'"))
    token_hash: Mapped[bytes] = mapped_column(BYTEA, unique=True)
    sent_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    expires_at: Mapped[datetime]
    responded_at: Mapped[datetime | None]
    response: Mapped[str | None] = mapped_column(Text)
    consent_text_version: Mapped[str] = mapped_column(Text)
    ip_hash: Mapped[bytes | None] = mapped_column(BYTEA)
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))


class EmailSuppression(Base):
    """Global, cross-user list of addresses that must never be contacted (no user_id on purpose).
    ``email_hash`` = HMAC(pepper, normalised address); the address itself is never stored."""

    __tablename__ = "email_suppressions"
    __table_args__ = (CheckConstraint(in_list("reason", SUPPRESSION_REASONS), name="reason"),)

    email_hash: Mapped[bytes] = mapped_column(BYTEA, primary_key=True)
    reason: Mapped[str] = mapped_column(Text)
    source_contact_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))  # no FK
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
