"""``GET /v1/activity`` response models (API_SPEC §11)."""

from __future__ import annotations

from app.core.schemas import ResponseModel, UtcDateTime

ParamValue = str | int | bool | list[str] | None


class ActivityEntry(ResponseModel):
    id: int
    action: str
    occurred_at: UtcDateTime
    params: dict[str, ParamValue]


class ActivityPage(ResponseModel):
    items: list[ActivityEntry]
    next_cursor: str | None
