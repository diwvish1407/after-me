"""Releases and the recipient portal (DATABASE §3.7).

A release is "instruction X released to contact Y during incident Z". The engine creates them;
the API may only revoke them (one way) and count views. A portal link token is only ever stored
as a hash, and is minted by the dispatcher when the email is sent.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    CheckConstraint,
    ForeignKey,
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

from app.core.db import Base, in_list

REVOKE_REASONS = (
    "user_safe",
    "user_checkin",
    "instruction_removed",
    "recipient_removed",
    "contact_removed",
    "contact_opted_out",
    "account_deleted",
    "hold_rollback",
    "operator",
)


class ReleaseEvent(Base):
    __tablename__ = "release_events"
    __table_args__ = (
        UniqueConstraint(
            "incident_id", "instruction_id", "contact_id", name="uq_release_events_release"
        ),
        CheckConstraint(
            "revoke_reason IS NULL OR " + in_list("revoke_reason", REVOKE_REASONS),
            name="revoke_reason",
        ),
        CheckConstraint("(revoked_at IS NULL) = (revoke_reason IS NULL)", name="revoked_pair"),
        Index("ix_release_events_incident_contact", "incident_id", "contact_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    incident_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("escalation_incidents.id", ondelete="CASCADE")
    )
    action_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("incident_actions.id", ondelete="CASCADE")
    )
    instruction_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("instructions.id")
    )
    contact_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("trusted_contacts.id")
    )
    step_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True))
    released_at: Mapped[datetime]
    visible_after: Mapped[datetime]
    revoked_at: Mapped[datetime | None]
    revoke_reason: Mapped[str | None] = mapped_column(Text)
    first_viewed_at: Mapped[datetime | None]
    last_viewed_at: Mapped[datetime | None]
    view_count: Mapped[int] = mapped_column(Integer, server_default=text("0"))


class PortalAccess(Base):
    """One per (incident, contact) with at least one release."""

    __tablename__ = "portal_access"
    __table_args__ = (
        UniqueConstraint("incident_id", "contact_id", name="uq_portal_access_incident_contact"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    incident_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("escalation_incidents.id", ondelete="CASCADE")
    )
    contact_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("trusted_contacts.id")
    )
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    revoked_at: Mapped[datetime | None]


class PortalToken(Base):
    """A link token: only its SHA-256 is stored."""

    __tablename__ = "portal_tokens"
    __table_args__ = (
        UniqueConstraint("token_hash", name="uq_portal_tokens_token_hash"),
        Index("ix_portal_tokens_access", "access_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    access_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("portal_access.id", ondelete="CASCADE")
    )
    token_hash: Mapped[bytes] = mapped_column(LargeBinary)
    notification_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    expires_at: Mapped[datetime]
    first_used_at: Mapped[datetime | None]


class PortalSession(Base):
    __tablename__ = "portal_sessions"
    __table_args__ = (UniqueConstraint("session_hash", name="uq_portal_sessions_session_hash"),)

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    access_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("portal_access.id", ondelete="CASCADE")
    )
    session_hash: Mapped[bytes] = mapped_column(LargeBinary)
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    expires_at: Mapped[datetime]
    otp_verified_at: Mapped[datetime | None]
    elevated_until: Mapped[datetime | None]
    ip_hash: Mapped[bytes | None] = mapped_column(LargeBinary)
    revoked_at: Mapped[datetime | None]


class PortalOtpChallenge(Base):
    __tablename__ = "portal_otp_challenges"
    __table_args__ = (Index("ix_portal_otp_session", "portal_session_id"),)

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )
    portal_session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("portal_sessions.id", ondelete="CASCADE")
    )
    code_hash: Mapped[bytes] = mapped_column(LargeBinary)
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    expires_at: Mapped[datetime]
    attempts: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    consumed_at: Mapped[datetime | None]
