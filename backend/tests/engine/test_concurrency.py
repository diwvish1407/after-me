"""Concurrency (ESCALATION_ENGINE §6.2, §9.3; TEST_PLAN ENG-CONC-01...05, ENG-FS-22).

The pauses are injected *inside* the worker's or dispatcher's transaction, after it holds the
per-user lock, so the request really has to wait for it.
"""

from __future__ import annotations

import asyncio
from datetime import timedelta
from typing import Any

import pytest

from app.api.container import build_worker_services
from app.engine.dispatcher import Dispatcher
from app.engine.executor import ActionExecutor
from app.engine.runtime import Engine
from app.notifications.push import RecordingPushProvider
from tests.support import problem
from tests.world import World, ist

DUE = ist("2026-10-09T20:00")
STAGE_1 = DUE + timedelta(minutes=180)


def mom(person: Any) -> str:
    return f"mom.{person.user_id[:6]}@example.com"


class Pause:
    """Make an awaited method wait on an event once it has been entered."""

    def __init__(self) -> None:
        self.entered = asyncio.Event()
        self.release = asyncio.Event()


async def test_conc01_a_checkin_waits_for_a_stage_in_flight_and_then_wins(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The worker is inside the stage (it holds the user lock); the check-in arrives meanwhile.
    It waits, then sees the committed stage: contacts are not yet messaged, so I'M OK resolves
    it and the queued message is cancelled before anyone could see it."""
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))
    pause = Pause()
    real = ActionExecutor._stage

    async def paused(self: ActionExecutor, *args: Any, **kwargs: Any) -> None:
        pause.entered.set()
        await pause.release.wait()
        await real(self, *args, **kwargs)

    monkeypatch.setattr(ActionExecutor, "_stage", paused)
    world.clock.set(STAGE_1)
    worker = asyncio.create_task(world.engine.tick())
    await asyncio.wait_for(pause.entered.wait(), 5)

    checkin = asyncio.create_task(world.checkin(person))
    try:
        await asyncio.sleep(0.4)
        assert not checkin.done()  # it is waiting for the user lock
    finally:
        pause.release.set()  # never leave a transaction open behind a failed assertion
    await worker
    response = await checkin

    assert response.json()["incident_resolved"] is True
    incident = world.incidents(person)[0]
    assert incident["status"] == "resolved"
    assert incident["contacts_messaged_at"] is None
    await world.advance_to(STAGE_1 + timedelta(minutes=10))
    assert world.mail.to(mom(person), "contact_alert") == []
    alert = world.notifications(person, template_key="contact_alert")[0]
    assert alert["status"] == "cancelled"


async def test_conc01b_a_checkin_that_commits_first_cancels_the_stage(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))
    world.clock.set(STAGE_1 - timedelta(seconds=30))
    await world.checkin(person)
    world.clock.set(STAGE_1)
    await world.tick()
    assert world.notifications(person, audience="contact") == []
    assert world.mail.to(mom(person), "contact_alert") == []


async def test_conc02a_a_dispatch_in_flight_makes_the_checkin_use_im_safe(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The dispatcher's tx A has marked the contacts as messaged but has not committed. The
    check-in waits, and then finds that I'M OK no longer settles it: 409 safe_required."""
    person = await world.ready()
    await world.advance_to(STAGE_1)
    pause = Pause()
    real = Dispatcher._build

    async def paused(self: Dispatcher, session: Any, row: Any, *args: Any, **kwargs: Any) -> Any:
        # The batch also holds the user's stage summary, which takes no user lock: it is the
        # contact alert's tx A that has to be caught in flight.
        if row.template_key == "contact_alert":
            pause.entered.set()
            await pause.release.wait()
        return await real(self, session, row, *args, **kwargs)

    monkeypatch.setattr(Dispatcher, "_build", paused)
    world.clock.set(STAGE_1 + timedelta(minutes=6))
    dispatch = asyncio.create_task(world.dispatch())
    try:
        await asyncio.wait_for(pause.entered.wait(), 5)
        checkin = asyncio.create_task(world.checkin(person, expect=409))
        await asyncio.sleep(0.4)
        assert not checkin.done()
    finally:
        pause.release.set()  # never leave a transaction open behind a failed assertion
    await dispatch
    refused = await checkin

    assert problem(refused)["code"] == "safe_required"
    assert len(world.mail.to(mom(person), "contact_alert")) == 1  # it did go out
    assert world.open_incident(person)["contacts_messaged_at"] is not None  # type: ignore[index]
    assert world.open_incident(person) is not None  # still open: nothing was recorded


async def test_conc02b_a_checkin_that_commits_first_stops_the_dispatch(world: World) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1)  # the alert is queued, inside the settle delay
    world.clock.set(STAGE_1 + timedelta(minutes=4, seconds=59))
    await world.checkin(person)
    world.clock.set(STAGE_1 + timedelta(minutes=6))
    await world.dispatch()
    assert world.mail.to(mom(person), "contact_alert") == []


async def test_conc03_two_checkins_on_an_open_incident_resolve_it_once(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))
    await world.login(person)
    results = await asyncio.gather(
        world.checkin(person, key="concurrent-key-0000001"),
        world.checkin(person, key="concurrent-key-0000002"),
    )
    assert {r.status_code for r in results} == {200}
    assert sorted(r.json()["incident_resolved"] for r in results) == [False, True]
    assert [i["status"] for i in world.incidents(person)] == ["resolved"]
    events = world.db.execute(
        "SELECT count(*) AS n FROM checkin_events WHERE user_id = %s", (person.user_id,)
    ).fetchone()["n"]
    assert events == 2


@pytest.mark.no_rate_limit
async def test_fs22_four_workers_over_many_users_each_effect_exactly_once(
    world: World,
) -> None:
    """Four worker replicas with their own connections and dispatchers; every incident, action
    and message appears once (SKIP LOCKED plus dedupe keys)."""
    people = [await world.ready(f"person{i:02d}@example.com") for i in range(24)]
    services = [
        build_worker_services(world.h.settings, clock=world.clock, email_provider=world.mail)
        for _ in range(4)
    ]
    engines = [Engine(s, instance_id=f"replica-{i}") for i, s in enumerate(services)]
    dispatchers = [Dispatcher(s, push=RecordingPushProvider()) for s in services]
    try:
        for target in (DUE, STAGE_1, STAGE_1 + timedelta(minutes=6)):
            world.clock.set(target)
            for _ in range(2):
                reports = await asyncio.gather(*(e.tick() for e in engines))
                assert sum(r.errors for r in reports) == 0
                await asyncio.gather(*(d.dispatch() for d in dispatchers))
    finally:
        for s in services:
            await s.db.dispose()

    assert len(world.incidents(people[0])) == 1
    total_incidents = world.db.execute("SELECT count(*) AS n FROM escalation_incidents").fetchone()[
        "n"
    ]
    assert total_incidents == len(people)
    stage_actions = world.db.execute(
        "SELECT count(*) AS n FROM incident_actions WHERE kind = 'execute_stage' "
        "AND status = 'executed'"
    ).fetchone()["n"]
    assert stage_actions == len(people)
    alerts = world.db.execute(
        "SELECT count(*) AS n, count(DISTINCT dedupe_key) AS d FROM notifications "
        "WHERE template_key = 'contact_alert'"
    ).fetchone()
    assert alerts["n"] == alerts["d"] == len(people)
    contact_mail = [m for m in world.mail.messages if m.template == "contact_alert"]
    assert len(contact_mail) == len(people)  # one email each, from whichever replica got it
    assert len({m.to for m in contact_mail}) == len(people)
