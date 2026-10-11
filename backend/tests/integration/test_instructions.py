"""``/v1/instructions`` (API_SPEC §10; TEST_PLAN INS-01…18, SEC-01/02/19/20).

Content exists only as ciphertext in the database, bound to its row and its owner; the list
never carries a body; a recipient needs an owned contact and an owned stage at least a day out.
"""

from __future__ import annotations

import unicodedata
from typing import Any

import psycopg
import pytest

from tests.support import bearer, conninfo, problem
from tests.world import Person, World

TITLE = "House emergency"
BODY = "The spare key is with Mrs. Sharma at flat 3B.\nCall her before you go."


async def _ready(world: World, email: str = "owner@example.com", *, premium: bool = True) -> Person:
    return await world.ready(
        email,
        contacts=("Mom", "Dad"),
        stages=((180, ("Mom",)), (1440, ("Dad",))),
        premium=premium,
    )


async def _stage_ids(world: World, person: Person) -> list[str]:
    await world.login(person)
    plan = await world.h.client.get("/v1/plan", headers=person.headers)
    return [s["id"] for s in plan.json()["stages"]]


async def _create(
    world: World, person: Person, *, expect: int = 201, **overrides: Any
) -> dict[str, Any]:
    await world.login(person)
    # routing something to someone, while check-ins are on, asks for the password (and so do
    # the changes the tests below make to it): confirmed once here, on the session they reuse
    assert (await world.h.reauth(person.tokens)).status_code == 204
    body: dict[str, Any] = {"category": "home", "title": TITLE, "body": BODY, **overrides}
    response = await world.h.client.post("/v1/instructions", json=body, headers=person.headers)
    assert response.status_code == expect, response.text
    return response.json()  # type: ignore[no-any-return]


async def _sign_in_confirmed(world: World, person: Person) -> None:
    """A fresh session that has entered the password: reading an instruction asks for it."""
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204


def _row(world: World, instruction_id: str) -> dict[str, Any]:
    found = world.db.execute(
        "SELECT * FROM instructions WHERE id = %s", (instruction_id,)
    ).fetchone()
    assert found is not None
    return dict(found)


# --- categories, create, read -----------------------------------------------------------------


async def test_the_categories_are_the_eleven_in_order(world: World) -> None:
    person = await _ready(world)
    response = await world.h.client.get("/v1/instruction-categories", headers=person.headers)
    assert response.status_code == 200
    assert [c["id"] for c in response.json()["items"]] == [
        "personal",
        "family",
        "home",
        "work",
        "business",
        "documents",
        "insurance",
        "pets",
        "travel",
        "digital_accounts",
        "other",
    ]


async def test_create_returns_the_instruction_and_reads_it_back(world: World) -> None:
    person = await _ready(world)
    stages = await _stage_ids(world, person)
    made = await _create(
        world,
        person,
        recipients=[{"contact_id": person.contacts["Dad"], "release_stage_id": stages[1]}],
    )
    assert made["title"] == TITLE
    assert made["body"] == BODY
    assert made["status"] == "active"
    assert made["recipients"] == [
        {
            "contact_id": person.contacts["Dad"],
            "display_name": "Dad",
            "release_stage_id": stages[1],
            "stage_position": 2,
        }
    ]
    await _sign_in_confirmed(world, person)
    again = await world.h.client.get(f"/v1/instructions/{made['id']}", headers=person.headers)
    assert again.status_code == 200
    assert again.json() == made


async def test_the_list_never_carries_a_body(world: World) -> None:
    person = await _ready(world)
    await _create(world, person)
    await _create(world, person, category="pets", title="The cat")
    response = await world.h.client.get("/v1/instructions", headers=person.headers)
    assert response.status_code == 200
    items = response.json()["items"]
    assert {i["title"] for i in items} == {TITLE, "The cat"}
    assert all("body" not in i for i in items)
    only_pets = await world.h.client.get("/v1/instructions?category=pets", headers=person.headers)
    assert [i["title"] for i in only_pets.json()["items"]] == ["The cat"]


# --- encryption at rest -----------------------------------------------------------------------


async def test_the_database_holds_only_ciphertext(world: World) -> None:
    person = await _ready(world)
    made = await _create(world, person)
    row = _row(world, made["id"])
    blob = bytes(row["content_ciphertext"])
    assert blob[:1] == b"\x01"  # format version
    assert TITLE.encode() not in blob
    assert b"Sharma" not in blob
    assert row["content_key_version"] == 1
    wrapped = world.db.execute(
        "SELECT wrapped_dek, kek_id FROM user_keys WHERE user_id = %s", (person.user_id,)
    ).fetchone()
    assert wrapped is not None
    assert wrapped["kek_id"].startswith("local-")
    assert len(bytes(wrapped["wrapped_dek"])) == 1 + 12 + 32 + 16  # version, nonce, key, tag


async def test_the_same_text_seals_differently_each_time(world: World) -> None:
    person = await _ready(world)
    a = await _create(world, person)
    b = await _create(world, person)
    assert bytes(_row(world, a["id"])["content_ciphertext"]) != bytes(
        _row(world, b["id"])["content_ciphertext"]
    )


async def test_a_ciphertext_moved_to_another_row_does_not_open(world: World) -> None:
    person = await _ready(world)
    a = await _create(world, person, title="First")
    b = await _create(world, person, title="Second")
    world.db.execute(
        "UPDATE instructions SET content_ciphertext = (SELECT content_ciphertext FROM "
        "instructions WHERE id = %s) WHERE id = %s",
        (a["id"], b["id"]),
    )
    response = await world.h.client.get(f"/v1/instructions/{b['id']}", headers=person.headers)
    assert response.status_code == 500
    assert "First" not in response.text
    assert "Second" not in response.text


async def test_a_ciphertext_moved_to_another_user_does_not_open(world: World) -> None:
    alice = await _ready(world, "alice@example.com")
    bob = await _ready(world, "bob@example.com")
    mine = await _create(world, alice, title="Alice's")
    theirs = await _create(world, bob, title="Bob's")
    world.db.execute(
        "UPDATE instructions SET content_ciphertext = (SELECT content_ciphertext FROM "
        "instructions WHERE id = %s) WHERE id = %s",
        (mine["id"], theirs["id"]),
    )
    await _sign_in_confirmed(world, bob)
    response = await world.h.client.get(f"/v1/instructions/{theirs['id']}", headers=bob.headers)
    assert response.status_code == 500
    assert "Alice" not in response.text


async def test_a_tampered_ciphertext_does_not_open(world: World) -> None:
    person = await _ready(world)
    made = await _create(world, person)
    world.db.execute(
        "UPDATE instructions SET content_ciphertext = set_byte(content_ciphertext, 20, "
        "get_byte(content_ciphertext, 20) # 1) WHERE id = %s",
        (made["id"],),
    )
    response = await world.h.client.get(f"/v1/instructions/{made['id']}", headers=person.headers)
    assert response.status_code == 500


async def test_the_worker_role_cannot_read_content_or_keys(world: World) -> None:
    person = await _ready(world)
    await _create(world, person)
    with psycopg.connect(conninfo("afterme_worker", "afterme_worker_dev")) as worker:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            worker.execute("SELECT content_ciphertext FROM instructions")
        worker.rollback()
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            worker.execute("SELECT * FROM user_keys")
        worker.rollback()
        # ... but it can read everything the engine needs to decide a release
        worker.execute("SELECT id, status, deleted_at, user_id FROM instructions").fetchall()


# --- validation -------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("overrides", "field", "code"),
    [
        ({"title": ""}, "title", "required"),
        ({"title": "   "}, "title", "required"),
        ({"title": "x" * 121}, "title", "too_long"),
        ({"body": ""}, "body", "required"),
        ({"body": "x" * 20_001}, "body", "too_long"),
        ({"title": "bad\x00title"}, "title", "invalid_characters"),
        ({"body": "reversed " + chr(0x202E) + " text"}, "body", "invalid_characters"),
        ({"category": "nonsense"}, "category", "unknown_category"),
    ],
)
async def test_invalid_content_is_refused(
    world: World, overrides: dict[str, Any], field: str, code: str
) -> None:
    person = await _ready(world)
    response = await world.h.client.post(
        "/v1/instructions",
        json={"category": "home", "title": TITLE, "body": BODY, **overrides},
        headers=person.headers,
    )
    assert response.status_code == 422
    errors = problem(response)["errors"]
    assert any(e["field"] == field and e["code"] == code for e in errors), errors


async def test_text_is_normalised_to_nfc_with_unix_line_endings(world: World) -> None:
    person = await _ready(world)
    decomposed = "Café"  # e + combining acute
    made = await _create(world, person, title=decomposed, body="one\r\ntwo\rthree")
    assert made["title"] == unicodedata.normalize("NFC", decomposed)
    assert made["body"] == "one\ntwo\nthree"


async def test_the_largest_body_in_four_byte_characters_is_accepted(world: World) -> None:
    person = await _ready(world)
    made = await _create(world, person, body="\U0001f600" * 20_000)  # 80,000 bytes of UTF-8
    assert len(made["body"]) == 20_000


async def test_unknown_fields_are_refused(world: World) -> None:
    person = await _ready(world)
    for extra in ({"user_id": "x"}, {"status_x": 1}, {"content_ciphertext": "x"}):
        response = await world.h.client.post(
            "/v1/instructions",
            json={"category": "home", "title": TITLE, "body": BODY, **extra},
            headers=person.headers,
        )
        assert response.status_code == 422


# --- recipients -------------------------------------------------------------------------------


async def test_a_release_stage_under_a_day_is_refused(world: World) -> None:
    person = await _ready(world)
    stages = await _stage_ids(world, person)
    response = await world.h.client.post(
        "/v1/instructions",
        json={
            "category": "home",
            "title": TITLE,
            "body": BODY,
            "recipients": [{"contact_id": person.contacts["Mom"], "release_stage_id": stages[0]}],
        },
        headers=person.headers,
    )
    assert response.status_code == 422
    assert problem(response)["errors"][0]["code"] == "release_stage_too_early"


async def test_someone_elses_contact_or_stage_is_a_404_and_nothing_is_created(
    world: World,
) -> None:
    alice = await _ready(world, "alice@example.com")
    bob = await _ready(world, "bob@example.com")
    alice_stages = await _stage_ids(world, alice)
    bob_stages = await _stage_ids(world, bob)
    for recipient in (
        {"contact_id": bob.contacts["Dad"], "release_stage_id": alice_stages[1]},
        {"contact_id": alice.contacts["Dad"], "release_stage_id": bob_stages[1]},
    ):
        await _create(world, alice, expect=404, recipients=[recipient])
    count = world.db.execute("SELECT count(*) AS n FROM instructions").fetchone()
    assert count is not None
    assert count["n"] == 0


async def test_a_person_can_be_a_recipient_once(world: World) -> None:
    person = await _ready(world)
    stages = await _stage_ids(world, person)
    same = {"contact_id": person.contacts["Dad"], "release_stage_id": stages[1]}
    response = await world.h.client.post(
        "/v1/instructions",
        json={"category": "home", "title": TITLE, "body": BODY, "recipients": [same, same]},
        headers=person.headers,
    )
    assert response.status_code == 422
    assert problem(response)["errors"][0]["code"] == "duplicate_recipient"


async def test_an_unverified_contact_may_be_chosen(world: World) -> None:
    person = await _ready(world)
    stages = await _stage_ids(world, person)
    world.db.execute(
        "UPDATE trusted_contacts SET verification_status = 'pending' WHERE id = %s",
        (person.contacts["Dad"],),
    )
    made = await _create(
        world,
        person,
        recipients=[{"contact_id": person.contacts["Dad"], "release_stage_id": stages[1]}],
    )
    assert len(made["recipients"]) == 1


# --- limits ----------------------------------------------------------------------------------


async def test_the_free_plan_allows_three_instructions(world: World) -> None:
    person = await world.ready(premium=False)
    for index in range(3):
        await _create(world, person, title=f"Note {index}")
    response = await world.h.client.post(
        "/v1/instructions",
        json={"category": "home", "title": "One too many", "body": BODY},
        headers=person.headers,
    )
    assert response.status_code == 403
    assert problem(response)["code"] == "plan_limit_reached"
    assert problem(response)["resource"] == "instructions"
    assert problem(response)["limit"] == 3
    # a deleted one frees its place
    first = (await world.h.client.get("/v1/instructions", headers=person.headers)).json()["items"][
        0
    ]
    assert (
        await world.h.client.delete(f"/v1/instructions/{first['id']}", headers=person.headers)
    ).status_code == 204
    await _create(world, person, title="Now it fits")


async def test_usage_shows_in_entitlements_and_home(world: World) -> None:
    person = await _ready(world)
    await _create(world, person, title="Active")
    await _create(world, person, title="Switched off", status="inactive")
    await world.login(person)
    entitlements = await world.h.client.get("/v1/me/entitlements", headers=person.headers)
    assert entitlements.json()["usage"]["instructions"] == 2
    home = await world.h.client.get("/v1/home", headers=person.headers)
    assert home.json()["plan_summary"]["instructions_active"] == 1


# --- update and delete -----------------------------------------------------------------------


async def test_patch_changes_content_status_and_recipients(world: World) -> None:
    person = await _ready(world)
    stages = await _stage_ids(world, person)
    made = await _create(world, person)
    before = bytes(_row(world, made["id"])["content_ciphertext"])
    response = await world.h.client.patch(
        f"/v1/instructions/{made['id']}",
        json={
            "title": "New title",
            "status": "inactive",
            "recipients": [{"contact_id": person.contacts["Dad"], "release_stage_id": stages[1]}],
        },
        headers=person.headers,
    )
    assert response.status_code == 200, response.text
    out = response.json()
    assert out["title"] == "New title"
    assert out["body"] == BODY  # untouched
    assert out["status"] == "inactive"
    assert [r["display_name"] for r in out["recipients"]] == ["Dad"]
    row = _row(world, made["id"])
    assert bytes(row["content_ciphertext"]) != before
    assert row["content_version"] == 2


@pytest.mark.parametrize("body", [{}, {"title": None}, {"recipients": None}, {"unknown": 1}])
async def test_an_empty_or_null_patch_is_refused(world: World, body: dict[str, Any]) -> None:
    person = await _ready(world)
    made = await _create(world, person)
    response = await world.h.client.patch(
        f"/v1/instructions/{made['id']}", json=body, headers=person.headers
    )
    assert response.status_code == 422


async def test_delete_wipes_the_content_and_frees_the_stage(world: World) -> None:
    person = await _ready(world)
    stages = await _stage_ids(world, person)
    made = await _create(
        world,
        person,
        recipients=[{"contact_id": person.contacts["Dad"], "release_stage_id": stages[1]}],
    )
    deleted = await world.h.client.delete(f"/v1/instructions/{made['id']}", headers=person.headers)
    assert deleted.status_code == 204
    row = _row(world, made["id"])
    assert row["content_ciphertext"] is None
    assert row["deleted_at"] is not None
    gone = await world.h.client.get(f"/v1/instructions/{made['id']}", headers=person.headers)
    assert gone.status_code == 404
    assert (await world.h.client.get("/v1/instructions", headers=person.headers)).json() == {
        "items": []
    }
    leftover = world.db.execute("SELECT count(*) AS n FROM instruction_recipients").fetchone()
    assert leftover is not None
    assert leftover["n"] == 0


async def test_a_stage_with_an_instruction_cannot_be_removed(world: World) -> None:
    person = await _ready(world)
    stages = await _stage_ids(world, person)
    made = await _create(
        world,
        person,
        recipients=[{"contact_id": person.contacts["Dad"], "release_stage_id": stages[1]}],
    )
    plan = await world.h.client.get("/v1/plan", headers=person.headers)
    only_first = {
        "grace_minutes": plan.json()["grace_minutes"],
        "stages": [
            {
                "id": plan.json()["stages"][0]["id"],
                "offset_minutes": plan.json()["stages"][0]["offset_minutes"],
                "notify_contact_ids": [person.contacts["Mom"]],
            }
        ],
    }
    assert (await world.h.reauth(person.tokens)).status_code == 204  # the schedule is live
    refused = await world.h.client.put(
        "/v1/plan", json=only_first, headers={**person.headers, "If-Match": plan.headers["etag"]}
    )
    assert refused.status_code == 409, refused.text
    assert problem(refused)["code"] == "stage_in_use"
    assert problem(refused)["instruction_ids"] == [made["id"]]


# --- isolation --------------------------------------------------------------------------------


async def test_another_users_instruction_is_a_404_everywhere(world: World) -> None:
    alice = await _ready(world, "alice@example.com")
    bob = await _ready(world, "bob@example.com")
    mine = await _create(world, alice)
    await _sign_in_confirmed(world, bob)
    for method, body in (("GET", None), ("PATCH", {"title": "x"}), ("DELETE", None)):
        response = await world.h.client.request(
            method, f"/v1/instructions/{mine['id']}", json=body, headers=bob.headers
        )
        assert response.status_code == 404, method
    assert _row(world, mine["id"])["deleted_at"] is None
    assert (await world.h.client.get("/v1/instructions", headers=bob.headers)).json() == {
        "items": []
    }


async def test_instructions_need_a_session(world: World) -> None:
    response = await world.h.client.get("/v1/instructions")
    assert response.status_code == 401
    assert (await world.h.client.get("/v1/instructions", headers=bearer("junk"))).status_code == 401


# --- reading is a step-up (Phase 9 review BD-2 / F2) --------------------------------------------


async def test_reading_asks_for_the_password_and_leaves_a_trail_without_the_text(
    world: World,
) -> None:
    """A stolen access token used to read every decrypted instruction, silently, and made the
    export's fresh-password rule moot. The text is decrypted for the response, so reading
    needs the same five-minute password as the other things that expose or change it."""
    person = await _ready(world)
    made = await _create(world, person)

    await world.login(person)  # a new session: nobody has typed the password on it
    for path in ("/v1/instructions", f"/v1/instructions/{made['id']}"):
        refused = await world.h.client.get(path, headers=person.headers)
        assert refused.status_code == 403, path
        assert problem(refused)["code"] == "reauth_required"
        assert TITLE not in refused.text
        assert BODY not in refused.text
    none_yet = world.db.execute(
        "SELECT count(*) AS n FROM audit_logs WHERE action = 'instruction.viewed'"
    ).fetchone()
    assert none_yet == {"n": 0}  # a refusal reads nothing

    assert (await world.h.reauth(person.tokens)).status_code == 204
    detail = await world.h.client.get(f"/v1/instructions/{made['id']}", headers=person.headers)
    listed = await world.h.client.get("/v1/instructions", headers=person.headers)
    assert detail.status_code == listed.status_code == 200
    assert detail.json()["body"] == BODY

    viewed = world.db.execute(
        "SELECT metadata, resource_id, user_visible FROM audit_logs "
        "WHERE action = 'instruction.viewed' ORDER BY id"
    ).fetchall()
    assert len(viewed) == 2
    assert [v["metadata"]["count"] for v in viewed] == [1, 1]  # one instruction each time
    assert all(v["user_visible"] is False for v in viewed)
    assert TITLE not in str(viewed)
    assert BODY not in str(viewed)

    # five minutes later the window has closed and the next read asks again
    world.clock.advance(minutes=5, seconds=1)
    later = await world.h.client.get(f"/v1/instructions/{made['id']}", headers=person.headers)
    assert later.status_code == 403
