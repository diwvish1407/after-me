"""Rate-limit counters (DATABASE §3.11) and the per-user wrapped keys (DATABASE §3.1).

Rate-limit counters are UNLOGGED: losing them on a crash is acceptable.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import ForeignKey, Integer, LargeBinary, PrimaryKeyConstraint, Text, text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class UserKey(Base):
    """A user's data-encryption key, wrapped by the KMS. Never read by the worker or by any
    role that does not serve the owner or a verified recipient."""

    __tablename__ = "user_keys"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    wrapped_dek: Mapped[bytes] = mapped_column(LargeBinary)
    kek_id: Mapped[str] = mapped_column(Text)
    dek_version: Mapped[int] = mapped_column(Integer, server_default=text("1"))
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    rotated_at: Mapped[datetime | None]


class RateLimitCounter(Base):
    __tablename__ = "rate_limit_counters"
    __table_args__ = (
        PrimaryKeyConstraint("key", "window_start"),
        {"prefixes": ["UNLOGGED"]},
    )

    key: Mapped[str] = mapped_column(Text)  # '<rule>:<hmac(subject)>' - never a raw IP or email
    window_start: Mapped[datetime]
    count: Mapped[int] = mapped_column(Integer)
    expires_at: Mapped[datetime]
