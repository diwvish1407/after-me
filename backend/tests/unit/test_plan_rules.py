"""Plan validation rules (ESCALATION_ENGINE §5.1; TEST_PLAN PLAN-*). Pure, no database."""

from __future__ import annotations

import uuid

import pytest

from app.plans.rules import PRESET_OFFSETS, PlanRules, StageDraft, validate_plan

pytestmark = pytest.mark.no_db

FREE = PlanRules(
    grace_min=60,
    grace_max=4320,
    stage_gap_min=30,
    offset_max=43200,
    release_offset_min=1440,
    max_stages=2,
    custom_offsets=False,
    presets=PRESET_OFFSETS,
)
PREMIUM = PlanRules(
    grace_min=60,
    grace_max=4320,
    stage_gap_min=30,
    offset_max=43200,
    release_offset_min=1440,
    max_stages=10,
    custom_offsets=True,
    presets=PRESET_OFFSETS,
)
C1, C2 = uuid.uuid4(), uuid.uuid4()


def stage(offset: int, *, id: uuid.UUID | None = None, contacts: tuple[uuid.UUID, ...] = (C1,)):
    return StageDraft(id=id, offset_minutes=offset, notify_contact_ids=contacts)


def codes(errors) -> list[tuple[str, str]]:
    return [(e.field, e.code) for e in errors]


def test_a_standard_plan_is_valid() -> None:
    assert validate_plan(grace_minutes=180, stages=[stage(180), stage(1440)], rules=FREE) == []


def test_the_first_stage_runs_when_grace_ends() -> None:
    errors = validate_plan(grace_minutes=180, stages=[stage(360)], rules=FREE)
    assert ("stages[0].offset_minutes", "must_equal_grace") in codes(errors)


def test_stages_must_be_in_order_and_far_enough_apart() -> None:
    errors = validate_plan(
        grace_minutes=180, stages=[stage(180), stage(200), stage(190)], rules=PREMIUM
    )
    assert codes(errors) == [
        ("stages[1].offset_minutes", "too_close"),
        ("stages[2].offset_minutes", "too_close"),
    ]
    assert validate_plan(grace_minutes=180, stages=[stage(180), stage(210)], rules=PREMIUM) == []


def test_a_stage_cannot_be_later_than_thirty_days() -> None:
    errors = validate_plan(grace_minutes=180, stages=[stage(180), stage(43201)], rules=PREMIUM)
    assert codes(errors) == [("stages[1].offset_minutes", "too_large")]
    assert validate_plan(grace_minutes=180, stages=[stage(180), stage(43200)], rules=PREMIUM) == []


@pytest.mark.parametrize("grace", [0, 59, 4321, -5])
def test_grace_is_bounded(grace: int) -> None:
    errors = validate_plan(grace_minutes=grace, stages=[stage(grace)], rules=PREMIUM)
    assert ("grace_minutes", "out_of_range") in codes(errors)


@pytest.mark.parametrize("grace", [60, 4320])
def test_grace_bounds_are_inclusive(grace: int) -> None:
    assert validate_plan(grace_minutes=grace, stages=[stage(grace)], rules=PREMIUM) == []


def test_a_free_plan_uses_the_suggested_times_only() -> None:
    errors = validate_plan(grace_minutes=200, stages=[stage(200), stage(1000)], rules=FREE)
    assert ("grace_minutes", "not_a_preset") in codes(errors)
    assert ("stages[1].offset_minutes", "not_a_preset") in codes(errors)
    for preset in PRESET_OFFSETS:
        assert validate_plan(grace_minutes=preset, stages=[stage(preset)], rules=FREE) == []


def test_a_downgraded_account_keeps_the_values_it_has() -> None:
    kept = frozenset({200, 1000})
    stages = [stage(200), stage(1000)]
    assert validate_plan(grace_minutes=200, stages=stages, rules=FREE, kept_offsets=kept) == []
    assert codes(validate_plan(grace_minutes=200, stages=stages, rules=FREE)) != []
    # but cannot choose a new custom value
    other = validate_plan(
        grace_minutes=200, stages=[stage(200), stage(1100)], rules=FREE, kept_offsets=kept
    )
    assert ("stages[1].offset_minutes", "not_a_preset") in codes(other)


def test_a_premium_plan_may_use_any_time() -> None:
    assert validate_plan(grace_minutes=95, stages=[stage(95), stage(777)], rules=PREMIUM) == []


def test_a_stage_that_shares_information_stays_at_least_a_day_out() -> None:
    sid = uuid.uuid4()
    errors = validate_plan(
        grace_minutes=180,
        stages=[stage(180), stage(360, id=sid)],
        rules=PREMIUM,
        release_stage_ids=frozenset({sid}),
    )
    assert codes(errors) == [("stages[1].offset_minutes", "release_too_early")]
    assert (
        validate_plan(
            grace_minutes=180,
            stages=[stage(180), stage(1440, id=sid)],
            rules=PREMIUM,
            release_stage_ids=frozenset({sid}),
        )
        == []
    )


def test_a_plan_needs_a_stage() -> None:
    assert codes(validate_plan(grace_minutes=180, stages=[], rules=FREE)) == [
        ("stages", "too_short")
    ]


def test_duplicates_are_reported() -> None:
    sid = uuid.uuid4()
    errors = validate_plan(
        grace_minutes=180,
        stages=[stage(180, id=sid, contacts=(C1, C1)), stage(1440, id=sid)],
        rules=FREE,
    )
    assert ("stages[1].id", "duplicate") in codes(errors)
    assert ("stages[0].notify_contact_ids", "duplicate") in codes(errors)


def test_every_problem_is_reported_at_once() -> None:
    errors = validate_plan(
        grace_minutes=10, stages=[stage(20), stage(25), stage(99999)], rules=FREE
    )
    assert len(errors) >= 4
    assert all(e.field and e.code and e.message for e in errors)
