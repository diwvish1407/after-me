"""Snapshot, timeline and safety gate (ESCALATION_ENGINE §5, §6.4; TEST_PLAN ENG-PBT-02,
ENG-INV-4). Pure: no database."""

from __future__ import annotations

import uuid
from dataclasses import replace
from datetime import UTC, datetime, timedelta

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from app.engine.gate import ContactFacts, Decision, GateFacts, contact_problem, decide
from app.engine.timeline import anchor_for, materialise
from app.incidents.snapshot import (
    PlanSnapshot,
    SnapshotError,
    SnapshotRelease,
    SnapshotStage,
    build_snapshot,
    parse_snapshot,
)

pytestmark = pytest.mark.no_db

T0 = datetime(2026, 10, 14, 14, 30, tzinfo=UTC)
WARNING_LEAD = timedelta(minutes=60)


def snapshot_of(grace: int, *offsets: int, releases_at: tuple[int, ...] = ()) -> PlanSnapshot:
    stages = []
    for index, offset in enumerate(offsets, start=1):
        rel = (SnapshotRelease(uuid.uuid4(), uuid.uuid4()),) if offset in releases_at else ()
        stages.append(SnapshotStage(uuid.uuid4(), index, offset, (uuid.uuid4(),), releases=rel))
    return PlanSnapshot(uuid.uuid4(), 3, grace, tuple(stages))


# --- snapshot ---------------------------------------------------------------------------------


def test_a_snapshot_round_trips_and_holds_only_identifiers() -> None:
    original = snapshot_of(180, 180, 1440, releases_at=(1440,))
    raw = build_snapshot(
        plan_id=original.plan_id,
        plan_version=original.plan_version,
        grace_minutes=original.grace_minutes,
        stages=original.stages,
    )
    assert parse_snapshot(raw) == original
    # only IDs, numbers and the schema marker: no free text anywhere
    flat = str(raw)
    for forbidden in ("@", "name", "title", "body"):
        assert forbidden not in flat


@pytest.mark.parametrize(
    "mutate",
    [
        lambda r: {**r, "schema": 2},
        lambda r: {k: v for k, v in r.items() if k != "stages"},
        lambda r: {**r, "grace_minutes": 0},
        lambda r: {**r, "grace_minutes": True},
        lambda r: {**r, "plan_id": "not-a-uuid"},
        lambda r: {**r, "stages": [{**r["stages"][0], "position": 0}]},
        lambda r: {**r, "stages": [r["stages"][1], r["stages"][0]]},
        lambda r: {**r, "stages": "nope"},
        lambda r: "just a string",
    ],
)
def test_a_snapshot_this_release_does_not_understand_is_refused(mutate) -> None:
    original = snapshot_of(180, 180, 1440)
    raw = build_snapshot(
        plan_id=original.plan_id,
        plan_version=original.plan_version,
        grace_minutes=original.grace_minutes,
        stages=original.stages,
    )
    with pytest.raises(SnapshotError):
        parse_snapshot(mutate(raw))


# --- timeline (ENG-PBT-02) --------------------------------------------------------------------


def test_the_worked_example_timeline() -> None:
    snap = snapshot_of(180, 180, 1440, releases_at=(1440,))
    incident_id = uuid.uuid4()
    actions = materialise(
        incident_id=incident_id, snapshot=snap, anchor_at=T0, final_warning_lead=WARNING_LEAD
    )
    by_key = {(a.kind, a.variant or str(a.step_id)): a.scheduled_for for a in actions}
    assert by_key[("user_reminder", "missed")] == T0
    assert by_key[("user_reminder", "midpoint")] == T0 + timedelta(minutes=90)
    assert by_key[("user_reminder", "last_chance")] == T0 + timedelta(minutes=165)
    first, second = snap.stages
    assert by_key[("execute_stage", str(first.stage_id))] == T0 + timedelta(minutes=180)
    assert by_key[("execute_stage", str(second.stage_id))] == T0 + timedelta(minutes=1440)
    assert by_key[("user_final_warning", str(second.stage_id))] == T0 + timedelta(minutes=1380)
    assert ("user_final_warning", str(first.stage_id)) not in by_key  # no release, no warning
    assert len(actions) == 6


def test_the_anchor_is_the_later_of_the_deadline_and_the_opening() -> None:
    due = T0
    assert anchor_for(due, due + timedelta(hours=6)) == due + timedelta(hours=6)
    assert anchor_for(due, due - timedelta(seconds=1)) == due


@settings(max_examples=300, deadline=None)
@given(
    grace=st.integers(60, 4320),
    gaps=st.lists(st.integers(30, 3000), min_size=0, max_size=8),
    release_picks=st.lists(st.booleans(), min_size=8, max_size=8),
    late=st.integers(0, 86_400),
)
def test_timeline_properties(
    grace: int, gaps: list[int], release_picks: list[bool], late: int
) -> None:
    offsets = [grace]
    for gap in gaps:
        offsets.append(offsets[-1] + gap)
    releases = tuple(o for o, pick in zip(offsets, release_picks, strict=False) if pick)
    snap = snapshot_of(grace, *offsets, releases_at=releases)
    anchor = anchor_for(T0, T0 + timedelta(seconds=late))
    actions = materialise(
        incident_id=uuid.uuid4(), snapshot=snap, anchor_at=anchor, final_warning_lead=WARNING_LEAD
    )
    # dedupe keys are unique, so a second materialisation can never add an action (INV-5)
    assert len({a.dedupe_key for a in actions}) == len(actions)
    grace_end = anchor + timedelta(minutes=grace)
    reminders = [a for a in actions if a.kind == "user_reminder"]
    assert {a.variant for a in reminders} == {"missed", "midpoint", "last_chance"}
    for reminder in reminders:  # reminders inside the grace period, in order
        assert anchor <= reminder.scheduled_for < grace_end
    ordered = sorted(reminders, key=lambda a: a.scheduled_for)
    assert [a.variant for a in ordered] == ["missed", "midpoint", "last_chance"]
    stages = {a.step_id: a for a in actions if a.kind == "execute_stage"}
    for stage in snap.stages:  # stages at anchor + offset, never before grace ends (INV-8)
        planned = stages[stage.stage_id]
        assert planned.scheduled_for == anchor + timedelta(minutes=stage.offset_minutes)
        assert planned.scheduled_for >= grace_end
    warnings = {a.step_id: a for a in actions if a.kind == "user_final_warning"}
    for stage in snap.stages:  # a warning exactly 60 min before each releasing stage (INV-9)
        if stage.releases:
            assert (
                warnings[stage.stage_id].scheduled_for
                == stages[stage.stage_id].scheduled_for - WARNING_LEAD
            )
        else:
            assert stage.stage_id not in warnings


# --- the gate (ENG-INV-4: each check, forced to fail on its own, prevents execution) ----------


def facts(**overrides) -> GateFacts:
    base = GateFacts(
        kind="execute_stage",
        now=T0 + timedelta(hours=4),
        scheduled_for=T0 + timedelta(hours=3),
        grace_ends_at=T0 + timedelta(hours=3),
        hold_active=False,
        incident_open=True,
        user_active=True,
        snapshot_recognised=True,
        ownership_consistent=True,
        checkin_after_missed_due=False,
        release_offset_ok=True,
        needs_final_warning=False,
        final_warning_executed=False,
        final_warning_wait_exceeded=False,
    )
    return replace(base, **overrides)


def test_a_clean_stage_runs() -> None:
    result = decide(facts())
    assert result.runs
    assert result.gate == "ok"


@pytest.mark.parametrize(
    ("overrides", "decision", "gate"),
    [
        ({"hold_active": True}, Decision.LEAVE_PENDING, "G1"),
        ({"incident_open": False}, Decision.CANCEL, "G2"),
        ({"checkin_after_missed_due": True}, Decision.HOLD_AND_ALERT, "G3"),
        ({"scheduled_for": T0 + timedelta(hours=9)}, Decision.LEAVE_PENDING, "G4"),
        ({"scheduled_for": T0 + timedelta(hours=2)}, Decision.HOLD_AND_ALERT, "G4"),
        ({"release_offset_ok": False}, Decision.HOLD_AND_ALERT, "G4"),
        ({"user_active": False}, Decision.CANCEL, "G5"),
        ({"snapshot_recognised": False}, Decision.HOLD_AND_ALERT, "G6"),
        ({"ownership_consistent": False}, Decision.HOLD_AND_ALERT, "G6"),
        ({"needs_final_warning": True}, Decision.LEAVE_PENDING, "G9"),
        (
            {"needs_final_warning": True, "final_warning_wait_exceeded": True},
            Decision.HOLD_AND_ALERT,
            "G9",
        ),
    ],
)
def test_every_gate_stops_a_stage_on_its_own(overrides, decision: Decision, gate: str) -> None:
    result = decide(facts(**overrides))
    assert not result.runs
    assert (result.decision, result.gate) == (decision, gate)


def test_a_satisfied_final_warning_lets_the_release_stage_run() -> None:
    assert decide(facts(needs_final_warning=True, final_warning_executed=True)).runs


def test_hold_does_not_stop_user_reminders() -> None:
    reminder = facts(kind="user_reminder", hold_active=True, scheduled_for=T0)
    assert decide(reminder).runs


def test_reminders_are_not_bound_by_the_grace_floor_or_the_release_minimum() -> None:
    early = facts(
        kind="user_reminder", scheduled_for=T0, release_offset_ok=False, needs_final_warning=True
    )
    assert decide(early).runs


@pytest.mark.parametrize("kind", ["user_reminder", "user_final_warning"])
def test_inconsistency_stops_user_actions_too(kind: str) -> None:
    result = decide(facts(kind=kind, scheduled_for=T0, checkin_after_missed_due=True))
    assert result.decision is Decision.HOLD_AND_ALERT
    assert result.gate == "G3"


def test_an_action_never_runs_before_its_time() -> None:
    result = decide(facts(kind="user_reminder", scheduled_for=T0 + timedelta(hours=5)))
    assert result.decision is Decision.LEAVE_PENDING


# --- per-target narrowing (G7) ----------------------------------------------------------------


def contact(**overrides) -> ContactFacts:
    base = ContactFacts(
        exists=True,
        belongs_to_user=True,
        deleted=False,
        is_active=True,
        verification_status="verified",
        suppressed=False,
    )
    return replace(base, **overrides)


def test_a_verified_active_contact_may_be_messaged() -> None:
    assert contact_problem(contact()) is None


@pytest.mark.parametrize(
    ("overrides", "reason"),
    [
        ({"exists": False}, "not_found"),
        ({"belongs_to_user": False}, "not_found"),
        ({"deleted": True}, "deleted"),
        ({"is_active": False}, "inactive"),
        ({"verification_status": "pending"}, "not_verified_pending"),
        ({"verification_status": "declined"}, "not_verified_declined"),
        ({"verification_status": "opted_out"}, "not_verified_opted_out"),
        ({"verification_status": "bounced"}, "not_verified_bounced"),
        ({"suppressed": True}, "suppressed"),
    ],
)
def test_everyone_else_is_skipped_with_a_reason(overrides, reason: str) -> None:
    assert contact_problem(contact(**overrides)) == reason
