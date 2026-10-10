"""Check-in request/response models (API_SPEC §6)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Annotated, Literal

from pydantic import BeforeValidator, Field
from pydantic_core import PydanticCustomError

from app.checkins.schedule import parse_hhmm
from app.core.schemas import RequestModel, ResponseModel, UtcDateTime

CheckinStatus = Literal["inactive", "active", "incident_open"]
ReminderLead = Literal[0, 30, 60, 120, 240]
EventKind = Literal["ok", "safe"]
EventSource = Literal["app", "web"]

# A device with a dead clock battery reports 1970 or 2000: such a value says nothing, so it is
# dropped rather than stored (or, worse, used to reject a check-in).
_CLIENT_TIME_MIN = datetime(2020, 1, 1, tzinfo=UTC)
_CLIENT_TIME_MAX = datetime(2100, 1, 1, tzinfo=UTC)


def _hhmm(value: object) -> str:
    if not isinstance(value, str):
        raise PydanticCustomError("invalid_time", "Use a time such as 20:00.")
    try:
        parse_hhmm(value)
    except ValueError as exc:
        raise PydanticCustomError("invalid_time", "Use a time such as 20:00 (24-hour).") from exc
    return value


def _informational_instant(value: object) -> datetime | None:
    """Parse leniently: an unusable ``client_reported_at`` must never block a check-in."""
    if isinstance(value, datetime):
        parsed = value
    elif isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    else:
        return None
    if parsed.tzinfo is None:
        return None
    try:
        utc = parsed.astimezone(UTC)
    except (OverflowError, ValueError):
        return None
    return utc if _CLIENT_TIME_MIN <= utc < _CLIENT_TIME_MAX else None


class ScheduleOut(ResponseModel):
    interval_days: int
    due_local_time: str
    reminder_lead_minutes: int
    timezone: str
    status: CheckinStatus
    next_due_at: UtcDateTime | None
    last_checkin_at: UtcDateTime | None
    version: int


class SchedulePutRequest(RequestModel):
    interval_days: Annotated[int, Field(strict=True, ge=1, le=30)]
    due_local_time: Annotated[str, BeforeValidator(_hhmm)]
    reminder_lead_minutes: ReminderLead


class CheckinRequest(RequestModel):
    client_reported_at: Annotated[datetime | None, BeforeValidator(_informational_instant)] = None


class CheckinRecord(ResponseModel):
    id: uuid.UUID
    kind: EventKind
    received_at: UtcDateTime


class CheckinResponse(ResponseModel):
    checkin: CheckinRecord
    next_due_at: UtcDateTime | None
    incident_resolved: bool
    server_time: UtcDateTime


class CheckinItem(ResponseModel):
    id: uuid.UUID
    kind: EventKind
    source: EventSource
    received_at: UtcDateTime


class CheckinPage(ResponseModel):
    items: list[CheckinItem]
    next_cursor: str | None
