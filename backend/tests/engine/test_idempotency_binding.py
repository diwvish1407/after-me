"""An idempotency key belongs to one operation (Phase 9 review F-01; SECURITY T7, T39).

A retry of a tap is answered from what was stored. Before Phase 9 the lookup was by ``(user,
key)`` alone, so an I'M OK sent under the key of an I'M SAFE (or the reverse, or an I'M SAFE for
another incident) was answered ``200`` with the *other* operation's result and did nothing. For
the one action that takes an alarm back, "done" that was not done is the worst answer.
"""

from __future__ import annotations

import uuid
from datetime import timedelta

from tests.support import problem
from tests.world import World, ist

DUE = ist("2026-10-09T20:00")
STAGE_1 = DUE + timedelta(minutes=180)
KEY = "binding-key-0123456789abcdef"


async def test_a_key_used_for_im_ok_is_not_an_answer_for_im_safe(world: World) -> None:
    person = await world.ready()
    first = await world.checkin(person, key=KEY)
    assert first.status_code == 200

    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    wrong_operation = await world.h.client.post(
        f"/v1/incidents/{uuid.uuid4()}/safe",
        headers={**person.headers, "Idempotency-Key": KEY},
    )
    assert wrong_operation.status_code == 409
    assert problem(wrong_operation)["code"] == "idempotency_key_reused"

    # the positive control: the same operation under the same key is still a replay
    await world.login(person)
    replay = await world.h.client.post(
        "/v1/checkins", headers={**person.headers, "Idempotency-Key": KEY}
    )
    assert replay.status_code == 200
    assert replay.headers.get("idempotent-replayed") == "true"


async def test_a_key_used_for_im_safe_is_not_an_answer_for_im_ok_or_another_incident(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    incident = world.open_incident(person)
    assert incident is not None
    incident_id = str(incident["id"])
    first = await world.safe(person, incident_id, key=KEY)
    assert first.status_code == 200

    await world.login(person)
    as_checkin = await world.h.client.post(
        "/v1/checkins", headers={**person.headers, "Idempotency-Key": KEY}
    )
    assert as_checkin.status_code == 409
    assert problem(as_checkin)["code"] == "idempotency_key_reused"

    assert (await world.h.reauth(person.tokens)).status_code == 204
    another_incident = await world.h.client.post(
        f"/v1/incidents/{uuid.uuid4()}/safe",
        headers={**person.headers, "Idempotency-Key": KEY},
    )
    assert another_incident.status_code == 409
    assert problem(another_incident)["code"] == "idempotency_key_reused"

    replay = await world.h.client.post(
        f"/v1/incidents/{incident_id}/safe",
        headers={**person.headers, "Idempotency-Key": KEY},
    )
    assert replay.status_code == 200
    assert replay.headers.get("idempotent-replayed") == "true"
