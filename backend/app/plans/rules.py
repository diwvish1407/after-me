"""Plan validation rules (ESCALATION_ENGINE §5.1; API_SPEC §8). Pure: no I/O.

The service validates a plan with these rules under the per-user lock, and the engine's safety
gate re-checks the same invariants at execution time (G4), so a plan that was valid when it was
saved can never produce an early or unordered stage even if the data is changed behind the API.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Final

from app.core.config import Settings

# Offsets (minutes) a free-tier plan may use: 3 h, 6 h, 12 h, 1 d, 2 d, 3 d.
PRESET_OFFSETS: Final = (180, 360, 720, 1440, 2880, 4320)


@dataclass(frozen=True)
class PlanRules:
    grace_min: int
    grace_max: int
    stage_gap_min: int
    offset_max: int
    release_offset_min: int
    max_stages: int
    custom_offsets: bool
    presets: tuple[int, ...]


def plan_rules(settings: Settings, *, max_stages: int, custom_offsets: bool) -> PlanRules:
    return PlanRules(
        grace_min=settings.grace_min_minutes,
        grace_max=settings.grace_max_minutes,
        stage_gap_min=settings.stage_min_gap_minutes,
        offset_max=settings.stage_max_offset_minutes,
        release_offset_min=settings.min_release_offset_minutes,
        max_stages=max_stages,
        custom_offsets=custom_offsets,
        presets=PRESET_OFFSETS,
    )


@dataclass(frozen=True)
class StageDraft:
    id: uuid.UUID | None
    offset_minutes: int
    notify_contact_ids: tuple[uuid.UUID, ...]


@dataclass(frozen=True)
class RuleError:
    field: str
    code: str
    message: str

    def as_dict(self) -> dict[str, str]:
        return {"field": self.field, "code": self.code, "message": self.message}


def validate_plan(
    *,
    grace_minutes: int,
    stages: Sequence[StageDraft],
    rules: PlanRules,
    kept_offsets: frozenset[int] = frozenset(),
    release_stage_ids: frozenset[uuid.UUID] = frozenset(),
) -> list[RuleError]:
    """Field-level problems of a proposed plan; empty when it is valid.

    ``kept_offsets`` are the offsets the plan already stores: a downgraded account keeps what it
    has (PRD §10) but cannot choose new custom values. ``release_stage_ids`` are stages that
    carry instruction releases and therefore may not move earlier than the release minimum.
    """
    errors: list[RuleError] = []

    def allowed_value(value: int) -> bool:
        return rules.custom_offsets or value in rules.presets or value in kept_offsets

    if not rules.grace_min <= grace_minutes <= rules.grace_max:
        errors.append(
            RuleError(
                "grace_minutes",
                "out_of_range",
                f"The grace period must be between {rules.grace_min} "
                f"and {rules.grace_max} minutes.",
            )
        )
    elif not allowed_value(grace_minutes):
        errors.append(
            RuleError("grace_minutes", "not_a_preset", "Choose one of the suggested grace periods.")
        )

    if not stages:
        errors.append(RuleError("stages", "too_short", "Add at least one stage."))
        return errors

    seen_ids: set[uuid.UUID] = set()
    previous: int | None = None
    for index, stage in enumerate(stages):
        prefix = f"stages[{index}]"
        if stage.id is not None:
            if stage.id in seen_ids:
                errors.append(RuleError(f"{prefix}.id", "duplicate", "This stage appears twice."))
            seen_ids.add(stage.id)
        offset = stage.offset_minutes
        if index == 0 and offset != grace_minutes:
            errors.append(
                RuleError(
                    f"{prefix}.offset_minutes",
                    "must_equal_grace",
                    "The first stage runs when the grace period ends.",
                )
            )
        if offset > rules.offset_max:
            errors.append(
                RuleError(
                    f"{prefix}.offset_minutes",
                    "too_large",
                    f"A stage can be at most {rules.offset_max} minutes after the start.",
                )
            )
        elif index > 0 and previous is not None and offset < previous + rules.stage_gap_min:
            errors.append(
                RuleError(
                    f"{prefix}.offset_minutes",
                    "too_close",
                    f"Stages must be at least {rules.stage_gap_min} minutes apart, in order.",
                )
            )
        elif index > 0 and not allowed_value(offset):
            errors.append(
                RuleError(
                    f"{prefix}.offset_minutes",
                    "not_a_preset",
                    "Choose one of the suggested times.",
                )
            )
        if (
            stage.id is not None
            and stage.id in release_stage_ids
            and offset < rules.release_offset_min
        ):
            errors.append(
                RuleError(
                    f"{prefix}.offset_minutes",
                    "release_too_early",
                    "A stage that shares information must be at least "
                    f"{rules.release_offset_min} minutes after the start.",
                )
            )
        if len(set(stage.notify_contact_ids)) != len(stage.notify_contact_ids):
            errors.append(
                RuleError(f"{prefix}.notify_contact_ids", "duplicate", "A contact is listed twice.")
            )
        previous = offset
    return errors
