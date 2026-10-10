"""Trusted-contact request/response models (API_SPEC §7)."""

from __future__ import annotations

import uuid
from collections.abc import Callable
from typing import Annotated, Any, Literal

from pydantic import BeforeValidator, Field, ValidationInfo, field_validator, model_validator
from pydantic_core import PydanticCustomError

from app.contacts.models import PRIORITY_MAX, PRIORITY_MIN
from app.core.schemas import RequestModel, ResponseModel, UtcDateTime
from app.core.validation import (
    DisplayName,
    EmailField,
    clean_display_name,
    clean_email,
    clean_phone,
    clean_relationship_label,
    normalize_email,
)

Relationship = Literal[
    "mother",
    "father",
    "parent",
    "spouse",
    "partner",
    "sibling",
    "child",
    "relative",
    "friend",
    "neighbor",
    "employer",
    "colleague",
    "other",
]
VerificationStatus = Literal["pending", "verified", "declined", "opted_out", "bounced"]
Priority = Annotated[int, Field(strict=True, ge=PRIORITY_MIN, le=PRIORITY_MAX)]


def _nullable(clean: Callable[[object], str]) -> Callable[[object], str | None]:
    return lambda value: None if value is None else clean(value)


def _reject_null(value: object) -> object:
    if value is None:
        raise PydanticCustomError("null_not_allowed", "This field can't be cleared.")
    return value


def _not_null(clean: Callable[[object], str]) -> Callable[[object], str]:
    return lambda value: clean(_reject_null(value))


LabelField = Annotated[str | None, BeforeValidator(_nullable(clean_relationship_label))]
PhoneField = Annotated[str | None, BeforeValidator(_nullable(clean_phone))]


class ContactOut(ResponseModel):
    id: uuid.UUID
    display_name: str
    relationship: Relationship
    relationship_label: str | None
    email: str
    phone_e164: str | None
    priority: int
    verification_status: VerificationStatus
    verified_at: UtcDateTime | None
    is_active: bool
    invitation_sent_at: UtcDateTime | None
    invitation_send_count: int
    notified_at_stages: list[int]
    receives_instructions: int
    created_at: UtcDateTime
    updated_at: UtcDateTime


class ContactList(ResponseModel):
    items: list[ContactOut]


class InvitationQueued(ResponseModel):
    status: Literal["queued"] = "queued"


class ContactCreateRequest(RequestModel):
    display_name: DisplayName
    relationship: Relationship
    relationship_label: LabelField = None
    email: EmailField
    phone_e164: PhoneField = None
    priority: Priority | None = None

    @field_validator("relationship_label")
    @classmethod
    def _label_needs_other(cls, value: str | None, info: ValidationInfo) -> str | None:
        if value is not None and info.data.get("relationship") not in (None, "other"):
            raise PydanticCustomError(
                "label_not_allowed",
                "A description is only allowed when the relationship is Other.",
            )
        return value

    @property
    def email_normalized(self) -> str:
        return normalize_email(self.email)


class ContactPatchRequest(RequestModel):
    """Any non-empty subset. Absent means unchanged; ``null`` clears ``phone_e164`` and
    ``relationship_label`` and is rejected for every other field."""

    display_name: Annotated[str | None, BeforeValidator(_not_null(clean_display_name))] = None
    relationship: Annotated[Relationship | None, BeforeValidator(_reject_null)] = None
    relationship_label: LabelField = None
    email: Annotated[str | None, BeforeValidator(_not_null(clean_email))] = None
    phone_e164: PhoneField = None
    priority: Annotated[Priority | None, BeforeValidator(_reject_null)] = None
    is_active: Annotated[bool | None, BeforeValidator(_reject_null)] = None

    @model_validator(mode="after")
    def _at_least_one_field(self) -> ContactPatchRequest:
        if not self.model_fields_set:
            raise PydanticCustomError("empty_update", "Send at least one field to change.")
        return self

    def changes(self) -> dict[str, Any]:
        changes = {name: getattr(self, name) for name in self.model_fields_set}
        if isinstance(changes.get("email"), str):
            changes["email"] = normalize_email(changes["email"])
        return changes
