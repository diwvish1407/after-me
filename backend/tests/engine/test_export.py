"""``POST /v1/me/export`` (API_SPEC §3): the whole account as one document, behind a password."""

from __future__ import annotations

from typing import Any

from tests.engine.test_release import BODY, TITLE, Portal, _released, _setup
from tests.world import Person, World


async def _export(world: World, person: Person, *, reauth: bool = True) -> Any:
    await world.login(person)
    if reauth:
        assert (await world.h.reauth(person.tokens)).status_code == 204
    return await world.h.client.post("/v1/me/export", headers=person.headers)


async def test_export_needs_a_fresh_password_and_is_refused_without_it(world: World) -> None:
    person = await _setup(world)
    refused = await _export(world, person, reauth=False)
    assert refused.status_code == 403
    assert refused.json()["code"] == "reauth_required"
    assert refused.headers.get("content-disposition") is None
    exported = world.db.execute("SELECT 1 FROM audit_logs WHERE action = 'account.exported'")
    assert exported.fetchall() == []


async def test_export_holds_everything_decrypted_and_nothing_secret(world: World) -> None:
    person = await _released(world)
    other = await _setup_other(world)
    assert TITLE in (await Portal(world).reach_content(person)).text

    response = await _export(world, person)
    assert response.status_code == 200
    assert response.headers["content-disposition"] == 'attachment; filename="afterme-export.json"'
    assert response.headers["cache-control"] == "no-store"
    doc = response.json()

    assert doc["format_version"] == 1
    assert doc["account"]["email"] == person.email
    assert {c["display_name"] for c in doc["contacts"]} == {"Mom", "Brother"}
    assert doc["schedule"]["status"] == "incident_open"
    assert len(doc["plan"]["stages"]) == 2
    [instruction] = doc["instructions"]
    assert instruction["title"] == TITLE
    assert instruction["body"] == BODY
    assert instruction["recipients"][0]["display_name"] == "Brother"
    assert doc["checkins"] == []
    [incident] = doc["incidents"]
    assert incident["releases"][0]["instruction_title"] == TITLE
    assert incident["releases"][0]["view_count"] == 1
    actions = {a["action"] for a in doc["activity"]}
    assert {"incident.opened", "release.viewed", "escalation.stage_executed"} <= actions
    assert doc["truncated"] == {"checkins": False, "incidents": False, "activity": False}

    # what must never be in it
    text = response.text
    assert other.email not in text
    for forbidden in ("password_hash", "content_ciphertext", "wrapped_dek", "token_hash"):
        assert forbidden not in text
    row = world.db.execute(
        "SELECT user_visible, metadata FROM audit_logs WHERE action = 'account.exported'"
    ).fetchone()
    assert row["user_visible"] is True
    assert row["metadata"] == {}


async def test_export_is_limited_to_three_an_hour(world: World) -> None:
    person = await _setup(world)
    for _ in range(3):
        assert (await _export(world, person)).status_code == 200
    again = await _export(world, person)
    assert again.status_code == 429
    assert "retry-after" in again.headers


async def test_an_instruction_that_cannot_be_opened_is_listed_not_dropped(world: World) -> None:
    person = await _setup(world)
    # one flipped byte: the ciphertext no longer authenticates
    world.db.execute(
        "UPDATE instructions SET content_ciphertext = overlay(content_ciphertext "
        "placing '\\xff'::bytea from 20 for 1) WHERE user_id = %s",
        (person.user_id,),
    )
    doc = (await _export(world, person)).json()
    [instruction] = doc["instructions"]
    assert instruction["error"] == "content_unavailable"
    assert "title" not in instruction
    assert "body" not in instruction


async def _setup_other(world: World) -> Person:
    return await world.person("other.owner@example.com")


async def test_the_password_must_be_fresh_for_this_and_is_spent_by_an_export(
    world: World,
) -> None:
    person = await _setup(world)
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204

    # a confirmation older than a minute (the other step-up routes accept five) is not enough
    world.clock.advance(seconds=61)
    stale = await world.h.client.post("/v1/me/export", headers=person.headers)
    assert stale.status_code == 403
    assert stale.json()["code"] == "reauth_required"

    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    assert (await world.h.client.post("/v1/me/export", headers=person.headers)).status_code == 200
    # spent: the same confirmation does not open a second export
    again = await world.h.client.post("/v1/me/export", headers=person.headers)
    assert again.status_code == 403
