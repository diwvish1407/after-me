"""Admin API models. Contact addresses are masked; instruction content is never exposed."""

from __future__ import annotations

import uuid
from typing import Annotated, Literal

from pydantic import Field

from app.core.schemas import RequestModel, ResponseModel, UtcDateTime

Reason = Annotated[str, Field(min_length=3, max_length=200)]


class AdminOverview(ResponseModel):
    users_total: int
    users_active: int
    users_suspended: int
    users_pending_deletion: int
    users_premium: int
    schedules_active: int
    incidents_open: int
    checkins_24h: int
    signups_7d: int
    hold_active: bool


class AdminUserRow(ResponseModel):
    id: uuid.UUID
    email: str
    display_name: str | None
    status: str
    tier: str
    role: str
    schedule_status: str | None
    next_due_at: UtcDateTime | None
    last_checkin_at: UtcDateTime | None
    created_at: UtcDateTime


class AdminUserPage(ResponseModel):
    items: list[AdminUserRow]
    total: int


class AdminContact(ResponseModel):
    id: uuid.UUID
    display_name: str
    relationship: str
    email_masked: str | None
    verification_status: str
    is_active: bool


class AdminEvent(ResponseModel):
    id: uuid.UUID
    label: str
    due_local_time: str
    interval_days: int
    interval_minutes: int | None
    next_due_at: UtcDateTime | None


class AdminIncident(ResponseModel):
    id: uuid.UUID
    user_id: uuid.UUID
    email: str | None = None
    status: str
    missed_due_at: UtcDateTime
    opened_at: UtcDateTime
    closed_at: UtcDateTime | None
    closed_by: str | None


class AdminUserDetail(ResponseModel):
    user: AdminUserRow
    timezone: str | None
    mfa_enabled: bool
    google_linked: bool
    interval_days: int | None
    interval_minutes: int | None
    due_local_time: str | None
    events: list[AdminEvent]
    contacts: list[AdminContact]
    instructions_active: int
    incidents: list[AdminIncident]


class AdminIncidentPage(ResponseModel):
    items: list[AdminIncident]


class AdminHoldStatus(ResponseModel):
    active: bool
    holds: list[dict[str, str | None]]


class TierRequest(RequestModel):
    tier: Literal["free", "premium"]
    reason: Reason


class ReasonRequest(RequestModel):
    reason: Reason


class RoleRequest(RequestModel):
    role: Literal["user", "admin"]
    reason: Reason


class AdminChange(ResponseModel):
    changed: bool
    before: str
    after: str
    notes: list[str]
