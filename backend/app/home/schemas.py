"""``GET /v1/home`` response models (API_SPEC §5)."""

from __future__ import annotations

import uuid
from typing import Any, Literal

from pydantic import Field

from app.checkins.schemas import CheckinStatus
from app.core.schemas import ResponseModel, UtcDateTime

ReadinessCode = Literal[
    "schedule_inactive",
    "no_contacts",
    "contact_pending",
    "contact_declined",
    "contact_bounced",
    "contact_opted_out",
    "no_stages",
    "stage_empty",
]


class HomeUser(ResponseModel):
    display_name: str
    tier: str
    timezone: str


class HomeSchedule(ResponseModel):
    interval_days: int
    interval_minutes: int | None
    due_local_time: str
    reminder_lead_minutes: int


class HomeEvent(ResponseModel):
    """An extra check-in event (the primary one is ``schedule``)."""

    id: uuid.UUID
    label: str
    due_local_time: str
    interval_days: int
    interval_minutes: int | None
    next_due_at: UtcDateTime | None


class HomeCheckin(ResponseModel):
    status: CheckinStatus
    next_due_at: UtcDateTime | None
    last_checkin_at: UtcDateTime | None
    schedule: HomeSchedule
    # The event whose deadline ``next_due_at`` is (``None``: the primary schedule), and the
    # extra events with their own deadlines.
    next_due_event_id: uuid.UUID | None = None
    next_due_label: str | None = None
    events: list[HomeEvent] = Field(default_factory=list)


class PlanSummary(ResponseModel):
    stages: int
    contacts_total: int
    contacts_verified: int
    instructions_active: int


class ReadinessIssue(ResponseModel):
    code: ReadinessCode
    contact_id: uuid.UUID | None


class Readiness(ResponseModel):
    ready: bool
    issues: list[ReadinessIssue]


class ActivityItem(ResponseModel):
    action: str
    occurred_at: UtcDateTime


class ServiceStatus(ResponseModel):
    """The state of the service itself, the same for everyone. ``interruption`` is true while a
    Hold (the system circuit breaker) blocks contact-facing work, up to the moment the deadlines
    have been shifted. Nothing about the reason, the time or the operator is exposed."""

    interruption: bool


class HomeResponse(ResponseModel):
    server_time: UtcDateTime
    user: HomeUser
    checkin: HomeCheckin
    incident: dict[str, Any] | None
    plan_summary: PlanSummary
    readiness: Readiness
    recent_activity: list[ActivityItem]
    service: ServiceStatus
