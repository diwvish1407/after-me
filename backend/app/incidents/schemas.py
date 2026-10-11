"""Incident request/response models (API_SPEC §9)."""

from __future__ import annotations

import uuid
from typing import Literal

from app.core.schemas import ResponseModel, UtcDateTime

IncidentStatus = Literal["grace", "escalating", "escalated", "resolved", "cancelled", "voided"]
ActionStatus = Literal["pending", "executed", "cancelled", "held"]


class TimelineContact(ResponseModel):
    id: uuid.UUID
    display_name: str
    result: Literal["messaged", "skipped"] | None


class TimelineItem(ResponseModel):
    kind: Literal["user_reminder", "user_final_warning", "execute_stage"]
    variant: Literal["missed", "midpoint", "last_chance"] | None
    stage_position: int | None
    scheduled_for: UtcDateTime
    status: ActionStatus
    contacts: list[TimelineContact] | None
    release_count: int | None


class ReleaseOut(ResponseModel):
    """What was (or is to be) shared in this incident, for its owner: with whom, which
    instruction (the title is decrypted for the owner only), and what happened to it."""

    contact_id: uuid.UUID
    contact_display_name: str
    instruction_id: uuid.UUID
    instruction_title: str | None
    stage_position: int | None
    released_at: UtcDateTime
    visible_after: UtcDateTime
    first_viewed_at: UtcDateTime | None
    last_viewed_at: UtcDateTime | None
    view_count: int
    revoked_at: UtcDateTime | None
    revoke_reason: str | None


class IncidentOut(ResponseModel):
    id: uuid.UUID
    status: IncidentStatus
    requires: Literal["checkin", "safe"] | None
    missed_due_at: UtcDateTime
    anchor_at: UtcDateTime
    grace_ends_at: UtcDateTime
    contacts_messaged: bool
    closed_at: UtcDateTime | None
    closed_by: str | None
    timeline: list[TimelineItem]
    releases: list[ReleaseOut]
    server_time: UtcDateTime


class IncidentCurrent(ResponseModel):
    incident: IncidentOut | None


class IncidentSummary(ResponseModel):
    id: uuid.UUID
    status: IncidentStatus
    missed_due_at: UtcDateTime
    opened_at: UtcDateTime
    closed_at: UtcDateTime | None
    closed_by: str | None
    contacts_messaged: bool


class IncidentPage(ResponseModel):
    items: list[IncidentSummary]
    next_cursor: str | None


class AllClearTarget(ResponseModel):
    contact_id: uuid.UUID
    display_name: str


class SafeResponse(ResponseModel):
    status: Literal["cancelled"]
    incident_id: uuid.UUID
    all_clear_sent_to: list[AllClearTarget]
    next_due_at: UtcDateTime | None
    server_time: UtcDateTime
