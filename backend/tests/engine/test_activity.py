"""The Activity feed (API_SPEC §11): names and titles composed for the owner at read time."""

from __future__ import annotations

from typing import Any

from tests.engine.test_release import TITLE, Portal, _released, _setup
from tests.world import World


async def _feed(world: World, person: Any, **query: Any) -> dict[str, Any]:
    response = await world.h.client.get("/v1/activity", params=query, headers=person.headers)
    assert response.status_code == 200, response.text
    return dict(response.json())


async def test_the_feed_names_who_viewed_what_without_storing_either_in_the_audit_log(
    world: World,
) -> None:
    person = await _released(world)
    await world.login(person)
    assert TITLE in (await Portal(world).reach_content(person)).text
    await world.login(person)

    feed = await _feed(world, person)
    viewed = next(i for i in feed["items"] if i["action"] == "release.viewed")
    assert viewed["params"]["contact_display_name"] == "Brother"
    assert viewed["params"]["instruction_titles"] == [TITLE]
    assert viewed["params"]["release_count"] == 1
    executed = [i for i in feed["items"] if i["action"] == "escalation.stage_executed"]
    assert {i["params"]["stage"] for i in executed} == {1, 2}
    assert all("incident_id" in i["params"] for i in executed)

    # the audit log itself never held the name or the title (SECURITY §9)
    stored = world.db.execute(
        "SELECT metadata::text AS m FROM audit_logs WHERE subject_user_id = %s",
        (person.user_id,),
    ).fetchall()
    assert not any(TITLE in row["m"] or "Brother" in row["m"] for row in stored)


async def test_the_feed_is_newest_first_in_pages_and_only_the_owners(world: World) -> None:
    person = await _released(world)
    other = await world.person("someone.else@example.com")
    await world.login(person)
    await world.login(other)

    everything = await _feed(world, person, limit=100)
    ids = [i["id"] for i in everything["items"]]
    assert ids == sorted(ids, reverse=True)
    assert everything["next_cursor"] is None
    assert len(ids) >= 6

    first = await _feed(world, person, limit=3)
    assert len(first["items"]) == 3
    assert first["next_cursor"] is not None
    second = await _feed(world, person, limit=3, cursor=first["next_cursor"])
    assert [i["id"] for i in first["items"] + second["items"]] == ids[:6]

    theirs = await _feed(world, other, limit=100)
    assert {i["id"] for i in theirs["items"]}.isdisjoint(ids)
    assert all(i["action"].startswith("auth.") for i in theirs["items"])


async def test_a_view_shows_only_what_was_visible_then(world: World) -> None:
    person = await _released(world)
    await world.login(person)
    portal = Portal(world)
    assert TITLE in (await portal.reach_content(person)).text

    # the instruction is taken back afterwards: the record of the view stays as it was
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    gone = await world.h.client.delete(
        f"/v1/instructions/{person.contacts['_instruction']}", headers=person.headers
    )
    assert gone.status_code == 204
    feed = await _feed(world, person, limit=100)
    viewed = next(i for i in feed["items"] if i["action"] == "release.viewed")
    assert viewed["params"]["release_count"] == 1
    assert viewed["params"]["instruction_titles"] == []  # deleted: its text is gone
    assert viewed["params"]["contact_display_name"] == "Brother"


async def test_a_bad_cursor_is_a_validation_error_and_unauthenticated_is_refused(
    world: World,
) -> None:
    person = await _setup(world)
    bad = await world.h.client.get(
        "/v1/activity", params={"cursor": "nonsense"}, headers=person.headers
    )
    assert bad.status_code == 422
    assert bad.json()["errors"][0]["field"] == "cursor"
    assert (await world.h.client.get("/v1/activity")).status_code == 401
