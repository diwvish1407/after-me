"""``GET`` and ``PUT /v1/plan`` (API_SPEC §8; TEST_PLAN PLAN-01…15)."""

from __future__ import annotations

import uuid
from typing import Any

import httpx
import psycopg
import pytest

from tests.support import Harness, bearer, make_premium, problem, rows

Db = psycopg.Connection[dict[str, Any]]

OWNER = "owner@example.com"


async def _get(h: Harness, tokens: dict[str, Any]) -> httpx.Response:
    return await h.client.get("/v1/plan", headers=bearer(tokens))


async def _put(
    h: Harness, tokens: dict[str, Any], body: Any, if_match: str | None
) -> httpx.Response:
    headers = bearer(tokens)
    if if_match is not None:
        headers["If-Match"] = if_match
    return await h.client.put("/v1/plan", json=body, headers=headers)


def _body(grace: int, *stages: tuple[int, list[str]], ids: list[str | None] | None = None) -> dict:
    return {
        "grace_minutes": grace,
        "stages": [
            {
                "id": (ids[i] if ids else None),
                "offset_minutes": offset,
                "notify_contact_ids": contacts,
            }
            for i, (offset, contacts) in enumerate(stages)
        ],
    }


async def _premium_with_contacts(h: Harness, owner_db: Db, n: int = 3) -> tuple[dict, list[str]]:
    tokens = await h.signup(OWNER)
    make_premium(owner_db, OWNER)
    ids = []
    for index in range(n):
        response = await h.add_contact(tokens, f"c{index}@example.com", name=f"Contact {index}")
        assert response.status_code == 201, response.text
        ids.append(response.json()["id"])
    return tokens, ids


# --- read -------------------------------------------------------------------------------------


async def test_a_new_account_has_an_empty_default_plan(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    response = await _get(h, tokens)
    assert response.status_code == 200
    body = response.json()
    assert body["version"] == 1
    assert body["grace_minutes"] == 180
    assert body["stages"] == []
    assert response.headers["etag"] == '"plan-1"'
    assert body["rules"] == {
        "grace_min": 60,
        "grace_max": 4320,
        "stage_gap_min": 30,
        "offset_max": 43200,
        "release_offset_min": 1440,
        "max_stages": 2,
        "custom_offsets": False,
        "presets": [180, 360, 720, 1440, 2880, 4320],
    }


async def test_premium_rules_allow_more_stages_and_custom_times(h: Harness, owner_db: Db) -> None:
    tokens, _ = await _premium_with_contacts(h, owner_db, 0)
    rules = (await _get(h, tokens)).json()["rules"]
    assert rules["max_stages"] == 10
    assert rules["custom_offsets"] is True


async def test_the_plan_belongs_to_the_caller(h: Harness) -> None:
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    mom = (await h.add_contact(alice, "mom@example.com")).json()
    await h.plan_for_contacts(alice)
    assert (await _get(h, alice)).json()["stages"][0]["notify_contact_ids"] == [mom["id"]]
    assert (await _get(h, bob)).json()["stages"] == []


# --- replace ----------------------------------------------------------------------------------


async def test_put_needs_if_match_and_a_current_version(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    mom = (await h.add_contact(tokens, "mom@example.com")).json()
    body = _body(180, (180, [mom["id"]]))
    missing = await _put(h, tokens, body, None)
    assert missing.status_code == 428
    assert problem(missing)["code"] == "precondition_required"
    for stale in ('"plan-9"', "plan-1", "*", 'W/"plan-1"'):
        response = await _put(h, tokens, body, stale)
        assert response.status_code == 412, stale
        assert problem(response)["code"] == "precondition_failed"
    assert (await _get(h, tokens)).json()["stages"] == []


async def test_put_saves_the_plan_and_numbers_the_stages(h: Harness, owner_db: Db) -> None:
    tokens, ids = await _premium_with_contacts(h, owner_db, 2)
    response = await _put(
        h,
        tokens,
        _body(180, (180, [ids[0]]), (1440, [ids[1]]), (2880, [ids[0], ids[1]])),
        '"plan-1"',
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["version"] == 2
    assert response.headers["etag"] == '"plan-2"'
    assert [s["position"] for s in body["stages"]] == [1, 2, 3]
    assert [s["offset_minutes"] for s in body["stages"]] == [180, 1440, 2880]
    assert body["stages"][0]["notify_contact_ids"] == [ids[0]]
    assert sorted(body["stages"][2]["notify_contact_ids"]) == sorted([ids[0], ids[1]])
    assert all(s["release_count"] == 0 for s in body["stages"])
    assert (await _get(h, tokens)).json() == body
    (event,) = rows(owner_db, "SELECT * FROM audit_logs WHERE action = 'plan.updated'")
    assert event["metadata"] == {"stages": 3, "removed": 0}
    assert event["user_visible"] is True


async def test_an_identical_put_changes_nothing(h: Harness, owner_db: Db) -> None:
    tokens, ids = await _premium_with_contacts(h, owner_db, 1)
    first = await _put(h, tokens, _body(180, (180, [ids[0]])), '"plan-1"')
    stage_id = first.json()["stages"][0]["id"]
    again = await _put(h, tokens, _body(180, (180, [ids[0]]), ids=[stage_id]), '"plan-2"')
    assert again.status_code == 200
    assert again.json()["version"] == 2
    assert len(rows(owner_db, "SELECT 1 FROM audit_logs WHERE action = 'plan.updated'")) == 1


async def test_existing_stages_keep_their_ids_when_reordered_or_retimed(
    h: Harness, owner_db: Db
) -> None:
    tokens, ids = await _premium_with_contacts(h, owner_db, 2)
    first = (
        await _put(h, tokens, _body(180, (180, [ids[0]]), (1440, [ids[1]])), '"plan-1"')
    ).json()
    s1, s2 = first["stages"][0]["id"], first["stages"][1]["id"]
    # swap who is notified, and move the second stage; the ids must survive
    second = await _put(
        h, tokens, _body(180, (180, [ids[1]]), (2880, [ids[0]]), ids=[s1, s2]), '"plan-2"'
    )
    assert second.status_code == 200, second.text
    stages = second.json()["stages"]
    assert [s["id"] for s in stages] == [s1, s2]
    assert [s["offset_minutes"] for s in stages] == [180, 2880]
    assert stages[0]["notify_contact_ids"] == [ids[1]]


async def test_a_stage_missing_from_the_request_is_deleted(h: Harness, owner_db: Db) -> None:
    tokens, ids = await _premium_with_contacts(h, owner_db, 2)
    first = (
        await _put(h, tokens, _body(180, (180, [ids[0]]), (1440, [ids[1]])), '"plan-1"')
    ).json()
    keep = first["stages"][0]["id"]
    response = await _put(h, tokens, _body(180, (180, [ids[0]]), ids=[keep]), '"plan-2"')
    assert response.status_code == 200
    assert len(response.json()["stages"]) == 1
    assert rows(owner_db, "SELECT count(*) AS n FROM escalation_steps")[0]["n"] == 1
    (event,) = rows(
        owner_db, "SELECT * FROM audit_logs WHERE action = 'plan.updated' ORDER BY id DESC LIMIT 1"
    )
    assert event["metadata"]["removed"] == 1


@pytest.mark.parametrize(
    ("body", "field", "code"),
    [
        ({"grace_minutes": 180, "stages": []}, "stages", "too_short"),
        (
            {"grace_minutes": 30, "stages": [{"offset_minutes": 30, "notify_contact_ids": []}]},
            "grace_minutes",
            "out_of_range",
        ),
        (
            {"grace_minutes": 180, "stages": [{"offset_minutes": 360, "notify_contact_ids": []}]},
            "stages[0].offset_minutes",
            "must_equal_grace",
        ),
        (
            {"grace_minutes": 200, "stages": [{"offset_minutes": 200, "notify_contact_ids": []}]},
            "grace_minutes",
            "not_a_preset",
        ),
    ],
)
async def test_put_validates_the_plan(h: Harness, body: dict, field: str, code: str) -> None:
    tokens = await h.signup(OWNER)
    response = await _put(h, tokens, body, '"plan-1"')
    assert response.status_code == 422, response.text
    error = problem(response)
    assert error["code"] == "validation_failed"
    assert any(e["field"] == field and e["code"] == code for e in error["errors"]), error
    assert (await _get(h, tokens)).json()["version"] == 1


async def test_free_stages_must_be_close_enough_in_order_and_from_the_presets(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    mom = (await h.add_contact(tokens, "mom@example.com")).json()
    response = await _put(
        h, tokens, _body(180, (180, [mom["id"]]), (1000, [mom["id"]])), '"plan-1"'
    )
    assert response.status_code == 422
    assert any(
        e["field"] == "stages[1].offset_minutes" and e["code"] == "not_a_preset"
        for e in problem(response)["errors"]
    )


async def test_the_stage_limit_is_the_tier_limit(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    mom = (await h.add_contact(tokens, "mom@example.com")).json()
    three = _body(180, (180, [mom["id"]]), (360, [mom["id"]]), (720, [mom["id"]]))
    response = await _put(h, tokens, three, '"plan-1"')
    assert response.status_code == 403
    error = problem(response)
    assert error["code"] == "plan_limit_reached"
    assert (error["resource"], error["limit"], error["current"]) == ("stages", 2, 3)


async def test_a_downgraded_account_keeps_its_stages_but_cannot_add(
    h: Harness, owner_db: Db
) -> None:
    tokens, ids = await _premium_with_contacts(h, owner_db, 1)
    stages = [(180, [ids[0]]), (360, [ids[0]]), (777, [ids[0]])]
    saved = await _put(h, tokens, _body(180, *stages), '"plan-1"')
    assert saved.status_code == 200, saved.text
    owner_db.execute("UPDATE users SET tier = 'free'")
    ids_now = [s["id"] for s in saved.json()["stages"]]
    # editing what it has (three stages, one custom time) is still allowed...
    again = await _put(h, tokens, _body(180, *stages, ids=ids_now), '"plan-2"')
    assert again.status_code == 200
    # ...adding a fourth is not
    four = await _put(
        h, tokens, _body(180, *stages, (1440, [ids[0]]), ids=[*ids_now, None]), '"plan-2"'
    )
    assert four.status_code == 403
    assert problem(four)["code"] == "plan_limit_reached"


async def test_a_contact_that_is_not_yours_is_not_found(h: Harness) -> None:
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    alices = (await h.add_contact(alice, "alices.mom@example.com", name="Alice's Mom")).json()
    response = await _put(h, bob, _body(180, (180, [alices["id"]])), '"plan-1"')
    assert response.status_code == 404
    assert problem(response)["code"] == "not_found"
    assert alices["id"] not in response.text
    unknown = await _put(h, bob, _body(180, (180, [str(uuid.uuid4())])), '"plan-1"')
    assert unknown.status_code == 404


async def test_a_stage_that_is_not_yours_is_not_found(h: Harness) -> None:
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    mom = (await h.add_contact(alice, "mom@example.com")).json()
    plan = await h.plan_for_contacts(alice)
    bobs_contact = (await h.add_contact(bob, "bobs.mom@example.com")).json()
    response = await _put(
        h,
        bob,
        _body(180, (180, [bobs_contact["id"]]), ids=[plan["stages"][0]["id"]]),
        '"plan-1"',
    )
    assert response.status_code == 404
    assert (await _get(h, alice)).json()["stages"][0]["notify_contact_ids"] == [mom["id"]]


async def test_a_stage_may_be_empty(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    response = await _put(h, tokens, _body(180, (180, [])), '"plan-1"')
    assert response.status_code == 200
    assert response.json()["stages"][0]["notify_contact_ids"] == []


async def test_the_plan_cannot_change_during_an_incident(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    mom = (await h.add_contact(tokens, "mom@example.com")).json()
    await h.plan_for_contacts(tokens)
    owner_db.execute(
        "UPDATE checkin_configurations SET status = 'incident_open', baseline_at = now(), "
        "next_due_at = now() WHERE user_id = %s",
        (tokens["user"]["id"],),
    )
    before = (await _get(h, tokens)).json()
    response = await _put(h, tokens, _body(360, (360, [mom["id"]])), f'"plan-{before["version"]}"')
    assert response.status_code == 409
    assert problem(response)["code"] == "incident_open"
    assert (await _get(h, tokens)).json() == before


# --- links to contacts ------------------------------------------------------------------------


async def test_deleting_a_contact_removes_it_from_the_stages_and_bumps_the_version(
    h: Harness, owner_db: Db
) -> None:
    tokens, ids = await _premium_with_contacts(h, owner_db, 2)
    saved = await _put(h, tokens, _body(180, (180, [ids[0], ids[1]])), '"plan-1"')
    assert saved.json()["version"] == 2
    deleted = await h.client.delete(f"/v1/contacts/{ids[0]}", headers=bearer(tokens))
    assert deleted.status_code == 204
    after = (await _get(h, tokens)).json()
    assert after["stages"][0]["notify_contact_ids"] == [ids[1]]
    assert after["version"] == 3
    # a client that was editing is told, not silently overwritten
    stale = await _put(h, tokens, _body(180, (180, [ids[0], ids[1]])), '"plan-2"')
    assert stale.status_code == 412


async def test_deleting_the_only_contact_leaves_an_empty_stage(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    mom = (await h.add_contact(tokens, "mom@example.com")).json()
    await h.plan_for_contacts(tokens)
    await h.client.delete(f"/v1/contacts/{mom['id']}", headers=bearer(tokens))
    stage = (await _get(h, tokens)).json()["stages"][0]
    assert stage["notify_contact_ids"] == []


async def test_entitlements_count_the_stages(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    await h.add_contact(tokens, "mom@example.com")
    await h.plan_for_contacts(tokens)
    usage = (await h.client.get("/v1/me/entitlements", headers=bearer(tokens))).json()["usage"]
    assert usage["stages"] == 1


async def test_the_plan_requires_a_session(h: Harness) -> None:
    assert (await h.client.get("/v1/plan")).status_code == 401
    assert (await h.client.put("/v1/plan", json={})).status_code == 401
