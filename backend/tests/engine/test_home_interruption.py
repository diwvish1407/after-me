"""``GET /v1/home`` tells the app when the service is in a Hold (Phase 10 follow-up).

Until now neither the API nor the app knew: Home went on saying "Mom will be notified at 9:15 pm
unless you check in" with a time that had passed, and the person learned of the interruption from
the email or push after it ended. The flag is the same for everyone, carries no reason and no
time, and stays true until the deadlines have been shifted (the engine's own definition of
"a Hold blocks").
"""

from __future__ import annotations

from datetime import timedelta
from typing import Any

from app.ops import admin
from tests.support import bearer
from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")


async def _home(world: World, person: Person) -> dict[str, Any]:
    await world.login(person)
    response = await world.h.client.get("/v1/home", headers=bearer(person.tokens))
    assert response.status_code == 200, response.text
    body: dict[str, Any] = response.json()
    return body


async def test_home_says_whether_the_service_is_interrupted(world: World) -> None:
    person = await world.ready()
    other = await world.ready("second@example.com", contacts=("Dad",), stages=((180, ("Dad",)),))

    assert (await _home(world, person))["service"] == {"interruption": False}

    await admin.hold_enter(world.engine.services, operator="alex", reason="provider incident")
    for who in (person, other):  # the same for everyone, signed in or not mid-incident
        assert (await _home(world, who))["service"] == {"interruption": True}

    # the flag exposes nothing about the Hold: no reason, no time, no operator
    body = await _home(world, person)
    assert set(body["service"]) == {"interruption"}
    assert "provider incident" not in str(body)
    assert "alex" not in str(body)


async def test_the_flag_stays_up_until_the_exit_has_been_processed(world: World) -> None:
    """Between ``ended_at`` and the rollback/shift a stage could still be about to run, so the
    app must not say the interruption is over (ESCALATION_ENGINE §7.3)."""
    person = await world.ready()
    await admin.hold_enter(world.engine.services, operator="alex", reason="investigating")
    await world.advance_to(DUE + timedelta(minutes=30))
    assert (await _home(world, person))["service"]["interruption"] is True

    assert await admin.hold_exit(world.engine.services, operator="alex") == 1
    ended = world.db.execute("SELECT ended_at, exit_processed_at FROM system_holds").fetchone()
    assert ended is not None
    assert ended["ended_at"] is not None
    assert ended["exit_processed_at"] is None
    assert (await _home(world, person))["service"]["interruption"] is True

    await world.tick()  # the exit is processed: deadlines shifted
    assert (await _home(world, person))["service"] == {"interruption": False}
