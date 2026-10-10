"""``GET /v1/home`` response models (API_SPEC §5)."""

from __future__ import annotations

import uuid
from typing import Any, Literal

from app.checkins.schemas import CheckinStatus, ReminderLead
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
    due_local_time: str
    reminder_lead_minutes: ReminderLead


class HomeCheckin(ResponseModel):
    status: CheckinStatus
    next_due_at: UtcDateTime | None
    last_checkin_at: UtcDateTime | None
    schedule: HomeSchedule


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


class HomeResponse(ResponseModel):
    server_time: UtcDateTime
    user: HomeUser
    checkin: HomeCheckin
    incident: dict[str, Any] | None
    plan_summary: PlanSummary
    readiness: Readiness
    recent_activity: list[ActivityItem]
