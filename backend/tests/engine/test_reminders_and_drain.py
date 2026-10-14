"""Phase 11/12 review fixes in the engine (E-2, E-4, the gaps around concurrent units).

* E-2: the reminder scan skips a person once their reminder is queued. A phone whose push token
  arrives later in the window must still get its push: the skip needs the e-mail AND a push for
  every device that currently has a token.
* A suspended account inside its window is never reminded, so it must not be a candidate on
  every tick until its deadline either.
* ``run_units``: one unit that fails leaves the others running, and the tick completes.
* E-4: ``drain_outbox`` with the real dispatcher: a Hold that starts mid-drain stops every
  contact-facing send at once, and a full batch of rows that only "wait" is not a backlog (no
  busy loop until the next tick).
"""

from __future__ import annotations

import asyncio
import uuid
from datetime import timedelta
from typing import Any

import psycopg
import pytest

from app.engine import dispatcher as dispatch_module
from app.engine import runtime
from app.engine.dispatcher import DispatchReport
from app.engine.store import EngineStore
from app.ops import admin
from tests.support import conninfo
from tests.world import Person, World, ist
from workers.engine import drain_outbox

DUE = ist("2026-10-09T20:00")
STAGE_1 = DUE + timedelta(minutes=180)
SETTLED = STAGE_1 + timedelta(seconds=300)


async def _candidates(world: World) -> list[str]:
    async with world.engine.services.db.sessionmaker() as session:
        rows = await EngineStore.reminder_candidates(session, world.clock.current, 200)
    return [str(r[0]) for r in rows]


def _device(world: World, person: Person) -> uuid.UUID:
    row = world.db.execute(
        "SELECT id FROM devices WHERE user_id = %s ORDER BY created_at, id LIMIT 1",
        (person.user_id,),
    ).fetchone()
    assert row is not None
    return uuid.UUID(str(row["id"]))


# =========================================================================== E-2


async def test_a_push_token_registered_later_in_the_window_still_gets_the_push(
    world: World,
) -> None:
    world.clock.set(ist("2026-10-13T19:00"))
    person = await world.ready()
    world.clock.set(ist("2026-10-13T19:30"))
    await world.checkin(person)  # next deadline 2026-10-14 20:00 IST, reminder lead 60 min
    device = _device(world, person)
    world.db.execute("UPDATE devices SET push_token = NULL WHERE user_id = %s", (person.user_id,))

    world.clock.set(ist("2026-10-14T19:00"))
    await world.tick()  # the e-mail reminder; no device has a token yet
    assert len(world.mail.to(person.email, "checkin_pre_reminder")) == 1
    assert world.notifications(person, template_key="checkin_pre_reminder", channel="push") == []
    assert await _candidates(world) == []

    # T-30: permission granted, the app uploads its token
    world.clock.set(ist("2026-10-14T19:30"))
    world.db.execute(
        "UPDATE devices SET push_token = 'fcm-late-token-0123456789', "
        "push_token_updated_at = %s WHERE id = %s",
        (world.clock.current, device),
    )
    assert await _candidates(world) == [person.user_id]  # a device without its push
    await world.tick()
    pushes = world.notifications(person, template_key="checkin_pre_reminder", channel="push")
    assert [(str(p["device_id"]), p["status"]) for p in pushes] == [(str(device), "sent")]
    assert len(world.push.of_type("checkin_pre_reminder")) == 1
    assert len(world.mail.to(person.email, "checkin_pre_reminder")) == 1  # not a second e-mail

    # done: every current device has its push, so nobody is rescanned
    assert await _candidates(world) == []
    world.clock.advance(timedelta(minutes=5))
    again = await world.tick()
    assert again.pre_reminders == 0


async def test_a_suspended_account_in_its_window_is_not_a_candidate_every_tick(
    world: World,
) -> None:
    world.clock.set(ist("2026-10-13T19:00"))
    person = await world.ready()
    world.clock.set(ist("2026-10-13T19:30"))
    await world.checkin(person)
    world.db.execute("UPDATE users SET status = 'suspended' WHERE id = %s", (person.user_id,))

    world.clock.set(ist("2026-10-14T19:00"))
    assert await _candidates(world) == []  # nothing would be queued for it: not looked at
    report = await world.tick()
    assert report.pre_reminders == 0
    assert world.notifications(person, template_key="checkin_pre_reminder") == []

    world.db.execute("UPDATE users SET status = 'active' WHERE id = %s", (person.user_id,))
    assert await _candidates(world) == [person.user_id]  # reinstated inside the window


# =========================================================================== run_units


@pytest.mark.no_db
async def test_run_units_runs_every_unit_at_most_n_at_a_time_even_when_one_raises() -> None:
    running = 0
    peak = 0
    done: list[int] = []

    async def work(item: int) -> None:
        nonlocal running, peak
        running += 1
        peak = max(peak, running)
        try:
            await asyncio.sleep(0.01)
            if item == 2:
                raise RuntimeError("one unit fails")
            done.append(item)
        finally:
            running -= 1

    with pytest.raises(RuntimeError, match="one unit fails"):
        await runtime.run_units(range(10), work)
    # nothing is left running in the background after run_units returns
    assert running == 0
    assert sorted(done) == [0, 1, 3, 4, 5, 6, 7, 8, 9]
    assert peak == runtime.UNIT_CONCURRENCY


async def test_one_failing_unit_leaves_the_others_running_and_the_tick_completes(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    people = [await world.ready(f"unit{i}@example.com") for i in range(5)]
    broken = people[2].user_id
    real = runtime.open_incident

    async def open_or_fail(session: Any, **kwargs: Any) -> Any:
        if str(kwargs["user_id"]) == broken:
            raise RuntimeError("this one person's unit fails")
        return await real(session, **kwargs)

    monkeypatch.setattr(runtime, "open_incident", open_or_fail)
    world.clock.set(DUE + timedelta(seconds=5))
    report = await world.engine.tick()
    assert report.errors == 1
    assert report.opened == len(people) - 1
    for person in people:
        expected = 0 if person.user_id == broken else 1
        assert len(world.incidents(person)) == expected, person.email
    # the tick went on to its later steps
    assert report.hold_unknown is False

    monkeypatch.setattr(runtime, "open_incident", real)
    retry = await world.engine.tick()  # retried next tick
    assert retry.opened == 1


# =========================================================================== drain_outbox (E-4)


@pytest.fixture
def small_batch(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(dispatch_module, "BATCH", 1)


async def _three_alerts_due(world: World) -> list[Person]:
    """Three people escalated; their contact alerts are queued and past the settle delay, and
    nothing has dispatched them yet."""
    people = [await world.ready(f"drain{i}@example.com") for i in range(3)]
    await world.advance_to(STAGE_1)  # the stage ran; its alerts wait out the settle delay
    for person in people:
        [alert] = world.notifications(person, template_key="contact_alert")
        assert alert["status"] == "queued"
    # only the contact alerts stay queued (the person's own messages would take the batch of 1)
    world.db.execute(
        "UPDATE notifications SET status = 'cancelled', cancelled_reason = 'test' "
        "WHERE status = 'queued' AND category <> 'contact_escalation'"
    )
    world.clock.set(SETTLED + timedelta(seconds=1))
    return people


def _alerts_sent(world: World, people: list[Person]) -> int:
    return sum(
        len(world.mail.to(f"mom.{p.user_id[:6]}@example.com", "contact_alert")) for p in people
    )


async def test_a_hold_that_starts_mid_drain_stops_every_contact_facing_send(
    world: World, small_batch: None
) -> None:
    people = await _three_alerts_due(world)
    real = world.dispatcher.dispatch
    passes: list[DispatchReport] = []

    async def dispatch_then_hold(*, contact_facing: bool = True) -> DispatchReport:
        report = await real(contact_facing=contact_facing)
        passes.append(report)
        if len(passes) == 1:  # an operator enters Hold while the worker is draining
            await admin.hold_enter(world.engine.services, operator="alex", reason="mid-drain")
        return report

    world.dispatcher.dispatch = dispatch_then_hold  # type: ignore[method-assign]
    first = await world.dispatcher.dispatch(contact_facing=True)
    assert first.sent == 1
    assert first.backlog is True
    last = await drain_outbox(
        world.dispatcher,
        first,
        contact_facing=True,  # the tick's decision was made before the Hold
        until=float("inf"),
        stopping=lambda: False,
    )
    assert _alerts_sent(world, people) == 1  # nothing contact-facing after the Hold began
    assert last.sent == 0
    assert last.backlog is False  # the drain ended: it did not spin on what the Hold holds
    assert len(passes) == 2
    queued = [
        n
        for p in people
        for n in world.notifications(p, template_key="contact_alert")
        if n["status"] == "queued"
    ]
    assert len(queued) == 2


async def test_a_full_batch_of_rows_that_only_wait_is_not_a_backlog(
    world: World, small_batch: None
) -> None:
    people = await _three_alerts_due(world)
    holder = psycopg.connect(conninfo("afterme_owner", "afterme_owner_dev"))
    try:
        for person in people:  # every person's lock is busy: each alert comes back "wait"
            holder.execute(
                "SELECT 1 FROM checkin_configurations WHERE user_id = %s FOR UPDATE",
                (person.user_id,),
            )
        first = await world.dispatcher.dispatch(contact_facing=True)
        assert (first.sent, first.left_queued) == (0, 1)
        assert first.backlog is False  # nothing moved: going straight on would only spin

        passes = 0
        real = world.dispatcher.dispatch

        async def counted(*, contact_facing: bool = True) -> DispatchReport:
            nonlocal passes
            passes += 1
            return await real(contact_facing=contact_facing)

        world.dispatcher.dispatch = counted  # type: ignore[method-assign]
        ticks = iter(range(10_000))
        await drain_outbox(
            world.dispatcher,
            first,
            contact_facing=True,
            until=50.0,
            stopping=lambda: False,
            clock=lambda: float(next(ticks)),
        )
        assert passes == 0  # before the fix: a pass per clock reading until the next tick
    finally:
        holder.rollback()
        holder.close()
    world.dispatcher.dispatch = real  # type: ignore[method-assign]
    report = await world.dispatcher.dispatch(contact_facing=True)
    assert report.sent == 1  # the lock is free again: they go out
    assert report.backlog is True  # and a batch that moved something is a backlog again


@pytest.mark.no_db
async def test_the_candidate_query_reads_checkin_configurations_once() -> None:
    """The device test is two levels deep; correlated to the outer rows it costs a few index
    probes per person. Uncorrelated it joined every configuration again and timed out at
    10,000 people (scripts/perf.py, PERF-02)."""
    from datetime import UTC, datetime

    from sqlalchemy.dialects import postgresql

    seen: list[str] = []

    class Recorder:
        async def execute(self, stmt: Any) -> Any:
            seen.append(str(stmt.compile(dialect=postgresql.dialect())))

            class Rows:
                def all(self) -> list[Any]:
                    return []

            return Rows()

    await EngineStore.reminder_candidates(Recorder(), datetime.now(UTC), 10)  # type: ignore[arg-type]
    [sql] = seen
    import re

    # a table in a FROM list (not ``EXTRACT(epoch FROM checkin_configurations.next_due_at)``)
    assert len(re.findall(r"checkin_configurations(?![.\w])", sql)) == 1
