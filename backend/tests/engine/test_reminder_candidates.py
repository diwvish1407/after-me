"""A pre-deadline reminder is looked at once per deadline, not on every tick of its window
(PERF-02: with 100,000 people about 5,000 are inside their reminder window at any time; each was
read, locked and re-checked every tick until its deadline, and a full last page kept the worker
from ever sleeping)."""

from __future__ import annotations

from datetime import timedelta
from typing import get_args

from app.checkins.schemas import ReminderLead
from app.engine.store import MAX_REMINDER_LEAD_MINUTES, EngineStore
from tests.world import World, ist


async def _candidates(world: World) -> list[str]:
    services = world.engine.services
    async with services.db.sessionmaker() as session:
        now = world.clock.current
        rows = await EngineStore.reminder_candidates(session, now, 200)
    return [str(r[0]) for r in rows]


async def test_a_person_is_a_candidate_until_the_reminder_is_queued_and_not_after(
    world: World,
) -> None:
    world.clock.set(ist("2026-10-13T19:00"))
    person = await world.ready()
    world.clock.set(ist("2026-10-13T19:30"))
    await world.checkin(person)  # the next deadline: 2026-10-14 20:00 IST

    world.clock.set(ist("2026-10-14T18:59"))
    assert await _candidates(world) == []  # one minute before the window opens

    world.clock.set(ist("2026-10-14T19:00"))
    assert await _candidates(world) == [person.user_id]

    report = await world.tick()
    assert report.pre_reminders >= 1
    assert await _candidates(world) == []  # queued: not looked at again
    assert len(world.notifications(person, template_key="checkin_pre_reminder")) >= 1

    world.clock.advance(timedelta(minutes=10))
    again = await world.tick()
    assert again.pre_reminders == 0
    assert len(world.mail.to(person.email, "checkin_pre_reminder")) == 1


async def test_a_new_deadline_is_a_new_reminder(world: World) -> None:
    world.clock.set(ist("2026-10-13T19:00"))
    person = await world.ready()
    world.clock.set(ist("2026-10-13T19:30"))
    await world.checkin(person)
    await world.advance_to(ist("2026-10-14T19:05"))
    assert len(world.mail.to(person.email, "checkin_pre_reminder")) == 1
    world.clock.set(ist("2026-10-14T19:10"))
    await world.checkin(person)  # the deadline moves a day on
    await world.advance_to(ist("2026-10-15T19:05"))
    assert len(world.mail.to(person.email, "checkin_pre_reminder")) == 2


def test_the_scan_bound_is_the_largest_lead_the_schedule_allows() -> None:
    assert max(get_args(ReminderLead)) == MAX_REMINDER_LEAD_MINUTES
