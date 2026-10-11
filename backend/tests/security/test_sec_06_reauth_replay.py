"""SEC-06: a replayed ``POST /incidents/{id}/safe`` does not outlive the password window.

A replay of an idempotency key is normally answered from the stored result. For I'M SAFE the
step-up is checked *before* the key is looked up, so a stolen session that no longer has a fresh
password cannot read the stored answer (the contacts it names, the next due time) by replaying the
key, and a legitimate retry after re-entering the password still gets the one original answer.
"""

from __future__ import annotations

from datetime import timedelta
from typing import Any

import httpx

from tests.engine.test_release import address
from tests.security.sec_support import assert_unchanged, snapshot
from tests.support import problem
from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")
KEY = "sec06-safe-key-0000000001"


async def _incident_that_needs_i_am_safe(world: World) -> tuple[Person, str]:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=190))
    incident = world.open_incident(person)
    assert incident is not None
    assert incident["contacts_messaged_at"] is not None  # Mom has been told
    return person, str(incident["id"])


async def _safe(world: World, person: Person, incident_id: str, key: str) -> httpx.Response:
    return await world.h.client.post(
        f"/v1/incidents/{incident_id}/safe",
        headers={**person.headers, "Idempotency-Key": key},
    )


def _events(world: World, person: Person, kind: str) -> int:
    row = world.db.execute(
        "SELECT count(*) AS n FROM checkin_events WHERE user_id = %s AND kind = %s",
        (person.user_id, kind),
    ).fetchone()
    assert row is not None
    return int(row["n"])


async def test_a_safe_replayed_after_the_window_is_refused_and_after_a_new_password_is_replayed(
    world: World,
) -> None:
    person, incident_id = await _incident_that_needs_i_am_safe(world)
    mom = address(person, "Mom")
    await world.login(person)

    # without the password the key is not even looked at
    cold = await _safe(world, person, incident_id, KEY)
    assert cold.status_code == 403
    assert problem(cold)["code"] == "reauth_required"
    assert world.open_incident(person) is not None

    assert (await world.h.reauth(person.tokens)).status_code == 204
    first = await _safe(world, person, incident_id, KEY)
    assert first.status_code == 200, first.text
    original = first.json()
    assert original["status"] == "cancelled"
    assert original["incident_id"] == incident_id
    assert [t["display_name"] for t in original["all_clear_sent_to"]] == ["Mom"]
    assert "idempotent-replayed" not in first.headers
    assert world.open_incident(person) is None

    # 5 minutes and 1 second later the confirmation has lapsed (the access token has not)
    world.clock.advance(minutes=5, seconds=1)
    settled = snapshot(world.db)
    refused = await _safe(world, person, incident_id, KEY)
    assert refused.status_code == 403
    assert problem(refused)["code"] == "reauth_required"
    # nothing of the stored answer is in the refusal
    assert incident_id not in refused.text
    assert mom not in refused.text
    assert "Mom" not in refused.text
    assert "next_due_at" not in refused.text
    assert "idempotent-replayed" not in refused.headers
    assert_unchanged(settled, snapshot(world.db), "a refused replay")
    # a different key meets the same wall (the route's rule does not depend on the key)
    other = await _safe(world, person, incident_id, "sec06-other-key-000000001")
    assert other.status_code == 403
    assert_unchanged(settled, snapshot(world.db), "a refused safe with another key")

    # the password again: the same key answers from the record, marked as a replay
    assert (await world.h.reauth(person.tokens)).status_code == 204
    replay = await _safe(world, person, incident_id, KEY)
    assert replay.status_code == 200
    assert replay.headers["idempotent-replayed"] == "true"
    assert replay.json() == original

    # exactly one I'M SAFE, one closing, one all-clear
    assert _events(world, person, "safe") == 1
    closed = world.incidents(person)
    assert [i["closed_by"] for i in closed] == ["user_safe"]
    await world.advance(minutes=10)
    assert len(world.mail.to(mom, "contact_all_clear")) == 1


async def test_a_replay_with_a_stale_password_cannot_tell_a_real_key_from_a_made_up_one(
    world: World,
) -> None:
    """Both are the same 403: the refusal is not an oracle for which keys were used."""
    person, incident_id = await _incident_that_needs_i_am_safe(world)
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    assert (await _safe(world, person, incident_id, KEY)).status_code == 200
    world.clock.advance(minutes=6)

    real = await _safe(world, person, incident_id, KEY)
    made_up = await _safe(world, person, incident_id, "sec06-never-used-key-00001")

    def shape(response: httpx.Response) -> dict[str, Any]:
        body = problem(response)
        return {k: v for k, v in body.items() if k != "request_id"}

    assert real.status_code == made_up.status_code == 403
    assert shape(real) == shape(made_up)
