"""Several check-in events: the pure deadline bookkeeping in app/checkins/slots.py."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, time, timedelta

import pytest

from app.checkins.models import CheckinConfiguration, CheckinSlot
from app.checkins.slots import clear_all, restart_all, satisfy, start_slot, sync_due

pytestmark = pytest.mark.no_db

TZ = "Asia/Kolkata"
# 2026-11-17 10:00 IST
NOW = datetime(2026, 11, 17, 4, 30, tzinfo=UTC)


def _ist(day: int, hour: int, minute: int = 0) -> datetime:
    return datetime(2026, 11, day, hour, minute, tzinfo=UTC) - timedelta(hours=5, minutes=30)


def _cfg(status: str = "active") -> CheckinConfiguration:
    return CheckinConfiguration(
        user_id=uuid.uuid4(),
        interval_days=1,
        interval_minutes=None,
        due_local_time=time(20, 0),
        reminder_lead_minutes=60,
        status=status,
    )


def _slot(cfg: CheckinConfiguration, at: time, label: str = "Morning") -> CheckinSlot:
    return CheckinSlot(
        id=uuid.uuid4(),
        user_id=cfg.user_id,
        label=label,
        interval_days=1,
        interval_minutes=None,
        due_local_time=at,
        deleted_at=None,
    )


def test_restart_gives_every_event_its_next_occurrence_and_picks_the_earliest() -> None:
    cfg = _cfg()
    morning = _slot(cfg, time(9, 0))
    due = restart_all(cfg, [morning], TZ, NOW)
    assert cfg.primary_due_at == _ist(18, 20)
    assert morning.next_due_at == _ist(18, 9)
    assert due == cfg.next_due_at == _ist(18, 9)
    assert cfg.due_slot_id == morning.id
    assert cfg.baseline_at == NOW


def test_a_checkin_satisfies_only_the_event_that_is_due_first() -> None:
    cfg = _cfg()
    morning = _slot(cfg, time(9, 0))
    restart_all(cfg, [morning], TZ, NOW)
    at = _ist(18, 8, 30)  # the next morning, before 09:00
    due = satisfy(cfg, [morning], TZ, at)
    assert morning.next_due_at == _ist(19, 9)  # moved to the following morning
    assert cfg.primary_due_at == _ist(18, 20)  # the evening event still stands
    assert due == _ist(18, 20)
    assert cfg.due_slot_id is None
    assert cfg.baseline_at == at  # the check-in is always absorbed


def test_events_due_within_an_hour_of_each_other_are_answered_together() -> None:
    cfg = _cfg()
    early = _slot(cfg, time(19, 30), "Evening walk")
    restart_all(cfg, [early], TZ, NOW)
    satisfy(cfg, [early], TZ, _ist(18, 19, 0))
    assert early.next_due_at == _ist(19, 19, 30)
    assert cfg.primary_due_at == _ist(19, 20)


def test_a_removed_event_never_holds_the_deadline() -> None:
    cfg = _cfg()
    morning = _slot(cfg, time(9, 0))
    restart_all(cfg, [morning], TZ, NOW)
    morning.deleted_at = NOW
    sync_due(cfg, [morning])
    assert cfg.next_due_at == cfg.primary_due_at
    assert cfg.due_slot_id is None


def test_an_inactive_schedule_has_no_deadline_and_new_events_wait_for_activation() -> None:
    cfg = _cfg(status="inactive")
    morning = _slot(cfg, time(9, 0))
    start_slot(cfg, morning, [morning], TZ, NOW)
    assert morning.next_due_at is None
    assert cfg.next_due_at is None


def test_switching_off_clears_every_deadline() -> None:
    cfg = _cfg()
    morning = _slot(cfg, time(9, 0))
    restart_all(cfg, [morning], TZ, NOW)
    clear_all(cfg, [morning])
    assert (cfg.next_due_at, cfg.primary_due_at, morning.next_due_at, cfg.due_slot_id) == (
        None,
        None,
        None,
        None,
    )


def test_a_custom_minutes_event_is_counted_from_the_checkin() -> None:
    cfg = _cfg()
    pills = _slot(cfg, time(0, 0), "Medicine")
    pills.interval_minutes = 240
    restart_all(cfg, [pills], TZ, NOW)
    assert pills.next_due_at == NOW + timedelta(minutes=240)
    assert cfg.due_slot_id == pills.id
