"""Instruction request/response models (API_SPEC §10).

Content is plain text: normalised to NFC, line endings to ``\\n``, no control characters and no
characters that reorder text. Validators raise errors with stable codes and never echo input.
"""

from __future__ import annotations

import unicodedata
import uuid
from typing import Annotated, Final, Literal

from pydantic import BaseModel, BeforeValidator, ConfigDict, Field, model_validator
from pydantic_core import PydanticCustomError

from app.core.schemas import ResponseModel, UtcDateTime
from app.instructions.models import BODY_MAX, TITLE_MAX

Status = Literal["active", "inactive"]
MAX_RECIPIENTS: Final = 50

# Format characters (category Cf) change how text reads or hide it: bidi embeddings, overrides and
# isolates, directional marks, the word joiner, the BOM, tag characters, invisible operators.
# Three are legitimate in ordinary text and in several scripts and are kept.
_ALLOWED_FORMAT: Final = frozenset({0x00AD, 0x200C, 0x200D})  # soft hyphen, ZWNJ, ZWJ


def _fail(code: str, message: str) -> PydanticCustomError:
    return PydanticCustomError(code, message)


def _plain_text(value: object, *, multiline: bool) -> str:
    if not isinstance(value, str):
        raise _fail("invalid_text", "Enter text.")
    text = unicodedata.normalize("NFC", value)
    if multiline:
        text = text.replace("\r\n", "\n").replace("\r", "\n")
    for char in text:
        category = unicodedata.category(char)
        if (
            category == "Cs"  # a lone surrogate cannot be stored (or even encoded)
            or (category == "Cf" and ord(char) not in _ALLOWED_FORMAT)
            or (category == "Cc" and not (multiline and char in "\n\t"))
        ):
            raise _fail("invalid_characters", "This text contains characters that can't be used.")
    return text.strip()


def clean_title(value: object) -> str:
    text = _plain_text(value, multiline=False)
    if not text:
        raise _fail("required", "Enter a title.")
    if len(text) > TITLE_MAX:
        raise _fail("too_long", f"Use at most {TITLE_MAX} characters.")
    return text


def clean_body(value: object) -> str:
    text = _plain_text(value, multiline=True)
    if not text:
        raise _fail("required", "Enter some text.")
    if len(text) > BODY_MAX:
        raise _fail("too_long", f"Use at most {BODY_MAX:,} characters.")
    return text


def _reject_null(value: object) -> object:
    if value is None:
        raise _fail("null_not_allowed", "This field can't be cleared.")
    return value


Title = Annotated[str, BeforeValidator(clean_title)]
Body = Annotated[str, BeforeValidator(clean_body)]


class _Request(BaseModel):
    """Like ``RequestModel`` but without its 4,096-character string cap: a body may be 20,000."""

    model_config = ConfigDict(extra="forbid", frozen=True)


class RecipientIn(_Request):
    contact_id: uuid.UUID
    release_stage_id: uuid.UUID


class InstructionCreateRequest(_Request):
    category: Annotated[str, Field(min_length=2, max_length=32, pattern=r"^[a-z_]+$")]
    title: Title
    body: Body
    status: Status = "active"
    recipients: Annotated[list[RecipientIn], Field(max_length=MAX_RECIPIENTS)] = Field(
        default_factory=list
    )


class InstructionPatchRequest(_Request):
    category: Annotated[
        str | None,
        BeforeValidator(_reject_null),
        Field(min_length=2, max_length=32, pattern=r"^[a-z_]+$"),
    ] = None
    title: Annotated[str | None, BeforeValidator(lambda v: clean_title(_reject_null(v)))] = None
    body: Annotated[str | None, BeforeValidator(lambda v: clean_body(_reject_null(v)))] = None
    status: Annotated[Status | None, BeforeValidator(_reject_null)] = None
    recipients: Annotated[
        list[RecipientIn] | None,
        BeforeValidator(_reject_null),
        Field(max_length=MAX_RECIPIENTS),
    ] = None

    @model_validator(mode="after")
    def _not_empty(self) -> InstructionPatchRequest:
        if not self.model_fields_set:
            raise _fail("empty_body", "Send at least one field to change.")
        return self


class CategoryOut(ResponseModel):
    id: str
    sort_order: int


class CategoryList(ResponseModel):
    items: list[CategoryOut]


class RecipientOut(ResponseModel):
    contact_id: uuid.UUID
    display_name: str
    release_stage_id: uuid.UUID
    stage_position: int


class InstructionSummary(ResponseModel):
    id: uuid.UUID
    category: str
    title: str
    status: Status
    recipients: list[RecipientOut]
    updated_at: UtcDateTime


class InstructionOut(InstructionSummary):
    body: str
    created_at: UtcDateTime


class InstructionList(ResponseModel):
    items: list[InstructionSummary]
