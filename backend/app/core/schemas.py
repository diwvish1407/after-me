"""Base classes for API request/response models."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated

from pydantic import BaseModel, ConfigDict, PlainSerializer


def _rfc3339_utc(value: datetime) -> str:
    return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


# RFC 3339 UTC with a "Z" suffix, second precision (API_SPEC §1).
UtcDateTime = Annotated[datetime, PlainSerializer(_rfc3339_utc, return_type=str)]


class RequestModel(BaseModel):
    """Request bodies: unknown fields are rejected (no mass assignment)."""

    model_config = ConfigDict(extra="forbid", str_max_length=4096, frozen=True)


class ResponseModel(BaseModel):
    """Response bodies: explicit fields only."""

    model_config = ConfigDict(extra="forbid", frozen=True)
