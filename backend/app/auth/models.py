"""Identity and access tables (DATABASE §3.1)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    CheckConstraint,
    ForeignKey,
    Index,
    SmallInteger,
    Text,
    text,
)
from sqlalchemy.dialects.postgresql import BYTEA, JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base, in_list

USER_STATUSES = ("active", "pending_deletion", "suspended")
USER_TIERS = ("free", "premium")
SESSION_KINDS = ("app", "web")
REVOKE_REASONS = (
    "logout",
    "logout_all",
    "password_changed",
    "password_reset",
    "reuse_detected",
    "account_deleted",
    "operator",
    "expired",
)
AUTH_TOKEN_PURPOSES = ("signup_verify", "email_change", "password_reset", "account_delete_web")
AUTH_TOKEN_KINDS = ("code", "link")


def _uuid_pk() -> Mapped[uuid.UUID]:
    return mapped_column(
        UUID(as_uuid=True), primary_key=True, server_default=text("gen_random_uuid()")
    )


def _now_default() -> Mapped[datetime]:
    return mapped_column(server_default=text("now()"))


class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        CheckConstraint("char_length(email) <= 254", name="email_length"),
        CheckConstraint(in_list("status", USER_STATUSES), name="status"),
        CheckConstraint(in_list("tier", USER_TIERS), name="tier"),
        CheckConstraint(
            "status <> 'pending_deletion' OR deletion_requested_at IS NOT NULL",
            name="pending_has_request",
        ),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    email: Mapped[str] = mapped_column(Text)
    email_normalized: Mapped[str] = mapped_column(Text, unique=True)  # lower(trim(email))
    email_verified_at: Mapped[datetime | None]
    password_hash: Mapped[str] = mapped_column(Text)  # Argon2id PHC string
    password_changed_at: Mapped[datetime] = _now_default()
    status: Mapped[str] = mapped_column(Text, server_default=text("'active'"))
    tier: Mapped[str] = mapped_column(Text, server_default=text("'free'"))
    deletion_requested_at: Mapped[datetime | None]
    failed_login_count: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    locked_until: Mapped[datetime | None]
    last_login_at: Mapped[datetime | None]
    created_at: Mapped[datetime] = _now_default()
    updated_at: Mapped[datetime] = _now_default()


class Device(Base):
    __tablename__ = "devices"
    __table_args__ = (
        CheckConstraint("platform IN ('android')", name="platform"),
        Index(
            "uq_devices_push_token",
            "push_token",
            unique=True,
            postgresql_where=text("push_token IS NOT NULL"),
        ),
        Index("ix_devices_user", "user_id", postgresql_where=text("revoked_at IS NULL")),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    platform: Mapped[str] = mapped_column(Text)
    push_token: Mapped[str | None] = mapped_column(Text)
    push_token_updated_at: Mapped[datetime | None]
    app_version: Mapped[str | None] = mapped_column(Text)
    os_version: Mapped[str | None] = mapped_column(Text)
    locale: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = _now_default()
    last_seen_at: Mapped[datetime] = _now_default()
    revoked_at: Mapped[datetime | None]


class AuthSession(Base):
    """A login session (table ``sessions``). Named to avoid confusion with SQLAlchemy sessions."""

    __tablename__ = "sessions"
    __table_args__ = (
        CheckConstraint(in_list("kind", SESSION_KINDS), name="kind"),
        CheckConstraint(in_list("revoke_reason", REVOKE_REASONS), name="revoke_reason"),
        CheckConstraint("char_length(user_agent) <= 200", name="user_agent_length"),
        Index("ix_sessions_user_active", "user_id", postgresql_where=text("revoked_at IS NULL")),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    kind: Mapped[str] = mapped_column(Text)
    device_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("devices.id", ondelete="SET NULL")
    )
    web_token_hash: Mapped[bytes | None] = mapped_column(BYTEA, unique=True)
    auth_method: Mapped[str] = mapped_column(Text, server_default=text("'password'"))
    reauthenticated_at: Mapped[datetime | None]
    created_at: Mapped[datetime] = _now_default()
    last_used_at: Mapped[datetime] = _now_default()
    idle_expires_at: Mapped[datetime]
    absolute_expires_at: Mapped[datetime]
    revoked_at: Mapped[datetime | None]
    revoke_reason: Mapped[str | None] = mapped_column(Text)
    ip_hash: Mapped[bytes | None] = mapped_column(BYTEA)
    user_agent: Mapped[str | None] = mapped_column(Text)


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"
    __table_args__ = (Index("ix_refresh_tokens_session", "session_id"),)

    id: Mapped[uuid.UUID] = _uuid_pk()
    session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("sessions.id", ondelete="CASCADE")
    )
    token_hash: Mapped[bytes] = mapped_column(BYTEA, unique=True)  # SHA-256 of the token
    issued_at: Mapped[datetime] = _now_default()
    expires_at: Mapped[datetime]
    used_at: Mapped[datetime | None]
    replaced_by: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("refresh_tokens.id", ondelete="SET NULL")
    )


class AuthToken(Base):
    """Emailed one-time codes (and, in later phases, link tokens)."""

    __tablename__ = "auth_tokens"
    __table_args__ = (
        CheckConstraint(in_list("purpose", AUTH_TOKEN_PURPOSES), name="purpose"),
        CheckConstraint(in_list("kind", AUTH_TOKEN_KINDS), name="kind"),
        Index(
            "uq_auth_tokens_link",
            "secret_hash",
            unique=True,
            postgresql_where=text("kind = 'link'"),
        ),
        Index(
            "ix_auth_tokens_user_purpose",
            "user_id",
            "purpose",
            postgresql_where=text("used_at IS NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    purpose: Mapped[str] = mapped_column(Text)
    kind: Mapped[str] = mapped_column(Text)
    # code: HMAC(pepper, user_id|purpose|code); link: SHA-256(token)
    secret_hash: Mapped[bytes] = mapped_column(BYTEA)
    payload: Mapped[dict[str, Any] | None] = mapped_column(JSONB)
    attempts: Mapped[int] = mapped_column(SmallInteger, server_default=text("0"))
    expires_at: Mapped[datetime]
    used_at: Mapped[datetime | None]
    created_at: Mapped[datetime] = _now_default()
