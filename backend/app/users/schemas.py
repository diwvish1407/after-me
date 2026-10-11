"""``/v1/me`` response models (API_SPEC §3)."""

from __future__ import annotations

import uuid
from collections.abc import Callable
from typing import Annotated, Any, Literal

from pydantic import BeforeValidator, model_validator
from pydantic_core import PydanticCustomError

from app.core.schemas import RequestModel, ResponseModel, UtcDateTime
from app.core.validation import (
    clean_country_code,
    clean_display_name,
    clean_locale,
    clean_phone,
    clean_timezone,
)


def _nullable(clean: Callable[[object], str]) -> Callable[[object], str | None]:
    return lambda value: None if value is None else clean(value)


def _not_null(clean: Callable[[object], str]) -> Callable[[object], str]:
    def validate(value: object) -> str:
        if value is None:
            raise PydanticCustomError("null_not_allowed", "This field can't be cleared.")
        return clean(value)

    return validate


class ProfileOut(ResponseModel):
    display_name: str
    phone_e164: str | None
    country_code: str | None
    timezone: str
    locale: str


class MeResponse(ResponseModel):
    id: uuid.UUID
    email: str
    tier: str
    status: str
    profile: ProfileOut | None
    created_at: UtcDateTime


class ProfilePatchRequest(RequestModel):
    """``PATCH /v1/me/profile``: any non-empty subset of the profile fields.

    Absent means unchanged (``model_fields_set``); ``null`` clears ``phone_e164`` and
    ``country_code`` and is rejected for the others.
    """

    display_name: Annotated[str | None, BeforeValidator(_not_null(clean_display_name))] = None
    phone_e164: Annotated[str | None, BeforeValidator(_nullable(clean_phone))] = None
    country_code: Annotated[str | None, BeforeValidator(_nullable(clean_country_code))] = None
    timezone: Annotated[str | None, BeforeValidator(_not_null(clean_timezone))] = None
    locale: Annotated[str | None, BeforeValidator(_not_null(clean_locale))] = None

    @model_validator(mode="after")
    def _at_least_one_field(self) -> ProfilePatchRequest:
        if not self.model_fields_set:
            raise PydanticCustomError("empty_update", "Send at least one field to change.")
        return self

    def changes(self) -> dict[str, Any]:
        return {name: getattr(self, name) for name in self.model_fields_set}


class EntitlementLimits(ResponseModel):
    contacts: int
    instructions: int
    stages: int
    custom_offsets: bool


class EntitlementUsage(ResponseModel):
    contacts: int
    instructions: int
    stages: int


class EntitlementsResponse(ResponseModel):
    tier: str
    limits: EntitlementLimits
    usage: EntitlementUsage


class DeleteAccountRequest(RequestModel):
    """``DELETE /v1/me``: the word is typed, so a stray tap or a replayed request is not
    enough."""

    confirm: Literal["DELETE"]


class DeletionResponse(ResponseModel):
    status: Literal["pending_deletion"]
    purge_after: UtcDateTime
