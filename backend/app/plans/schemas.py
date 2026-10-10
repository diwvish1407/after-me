"""Plan request/response models (API_SPEC §8)."""

from __future__ import annotations

import uuid
from typing import Annotated

from pydantic import Field

from app.core.schemas import RequestModel, ResponseModel

MAX_STAGES_IN_REQUEST = 50  # far above any tier limit; bounds the body, the tier decides


class StageIn(RequestModel):
    id: uuid.UUID | None = None
    offset_minutes: Annotated[int, Field(strict=True, ge=0, le=10_000_000)]
    notify_contact_ids: Annotated[list[uuid.UUID], Field(max_length=100)]


class PlanPutRequest(RequestModel):
    grace_minutes: Annotated[int, Field(strict=True, ge=0, le=10_000_000)]
    stages: Annotated[list[StageIn], Field(max_length=MAX_STAGES_IN_REQUEST)]


class StageOut(ResponseModel):
    id: uuid.UUID
    position: int
    offset_minutes: int
    notify_contact_ids: list[uuid.UUID]
    release_count: int


class RulesOut(ResponseModel):
    grace_min: int
    grace_max: int
    stage_gap_min: int
    offset_max: int
    release_offset_min: int
    max_stages: int
    custom_offsets: bool
    presets: list[int]


class PlanOut(ResponseModel):
    id: uuid.UUID
    version: int
    grace_minutes: int
    stages: list[StageOut]
    rules: RulesOut
