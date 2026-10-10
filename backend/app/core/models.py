"""System tables shared by every module (DATABASE §3.11)."""

from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import Text, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class SystemFlag(Base):
    __tablename__ = "system_flags"

    key: Mapped[str] = mapped_column(Text, primary_key=True)  # e.g. 'min_client_version'
    value: Mapped[Any] = mapped_column(JSONB)
    updated_at: Mapped[datetime] = mapped_column(server_default=text("now()"))
    updated_by: Mapped[str] = mapped_column(Text)
