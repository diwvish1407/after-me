"""Rate-limit counters (DATABASE §3.11). UNLOGGED: losing them on a crash is acceptable."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import Integer, PrimaryKeyConstraint, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


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
