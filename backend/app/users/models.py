"""User profile (DATABASE §3.1, ``user_profiles``)."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import CHAR, CheckConstraint, ForeignKey, Text, text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base

PHONE_E164_SQL_PATTERN = r"^\+[1-9][0-9]{6,14}$"


class UserProfile(Base):
    __tablename__ = "user_profiles"
    __table_args__ = (
        CheckConstraint("char_length(display_name) BETWEEN 1 AND 80", name="display_name_length"),
        CheckConstraint(f"phone_e164 ~ '{PHONE_E164_SQL_PATTERN}'", name="phone_e164_format"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    display_name: Mapped[str] = mapped_column(Text)
    phone_e164: Mapped[str | None] = mapped_column(Text)
    country_code: Mapped[str | None] = mapped_column(CHAR(2))  # ISO 3166-1 alpha-2
    timezone: Mapped[str] = mapped_column(Text)  # IANA; validated against zoneinfo in the app
    locale: Mapped[str] = mapped_column(Text, server_default=text("'en'"))
    created_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    updated_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
