"""SEC-02: nobody can assign somebody else's contact or stage as a recipient (TEST_PLAN §5.2).

Two layers, both tested: the service answers ``404`` (nothing is created, nothing leaks), and, for
a bug or a hand-written statement that gets past the service, the composite same-owner foreign
keys of DATABASE §3 refuse the row. The API tests cover the create paths (``test_instructions.py``,
``test_plan.py``); this file adds the database half and the PATCH path.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from dataclasses import dataclass
from typing import Any

import psycopg
import pytest

from tests.security.sec_support import snapshot
from tests.support import API_PASSWORD, OWNER_PASSWORD, connect, problem
from tests.world import Person, World

Conn = psycopg.Connection[dict[str, Any]]

TITLE = "Alpha instruction"


@dataclass
class Owner:
    person: Person
    instruction: str
    steps: list[str]
    contacts: dict[str, str]


async def _owner(world: World, email: str) -> Owner:
    person = await world.ready(
        email, contacts=("Mom", "Dad"), stages=((180, ("Mom",)), (1440, ("Dad",)))
    )
    await world.login(person)
    made = await world.h.client.post(
        "/v1/instructions",
        json={"category": "home", "title": TITLE, "body": "Where the key is."},
        headers=person.headers,
    )
    assert made.status_code == 201, made.text
    steps = [
        str(r["id"])
        for r in world.db.execute(
            "SELECT id FROM escalation_steps WHERE user_id = %s ORDER BY position",
            (person.user_id,),
        ).fetchall()
    ]
    assert len(steps) == 2
    return Owner(person, str(made.json()["id"]), steps, dict(person.contacts))


@pytest.fixture(params=["afterme_api", "afterme_owner"])
def writer(request: pytest.FixtureRequest, migrated_database: str) -> Iterator[Conn]:
    """The role the application really writes with, and the owner role (which would also be
    refused: the constraint belongs to the table, not to a grant)."""
    password = API_PASSWORD if request.param == "afterme_api" else OWNER_PASSWORD
    with connect(request.param, password, migrated_database) as conn:
        yield conn


def _refused(conn: Conn, statement: str, params: tuple[Any, ...], column: str) -> None:
    with pytest.raises(psycopg.errors.ForeignKeyViolation) as caught:
        conn.execute(statement, params)  # type: ignore[arg-type]
    # it is the *same-owner* key that fired, not some other constraint
    assert column in (caught.value.diag.constraint_name or ""), caught.value.diag.constraint_name


RECIPIENT = (
    "INSERT INTO instruction_recipients (instruction_id, contact_id, release_step_id, user_id) "
    "VALUES (%s, %s, %s, %s)"
)
STEP_CONTACT = (
    "INSERT INTO escalation_step_contacts (step_id, contact_id, user_id) VALUES (%s, %s, %s)"
)


async def test_the_database_refuses_a_recipient_that_belongs_to_another_owner(
    world: World, writer: Conn
) -> None:
    alice = await _owner(world, "alice@example.com")
    bob = await _owner(world, "bob@example.com")
    a_user = alice.person.user_id

    before = snapshot(world.db)
    # Bob's contact on Alice's instruction and stage
    _refused(
        writer,
        RECIPIENT,
        (alice.instruction, bob.contacts["Dad"], alice.steps[1], a_user),
        "contact_id",
    )
    # Bob's stage for Alice's instruction and contact
    _refused(
        writer,
        RECIPIENT,
        (alice.instruction, alice.contacts["Dad"], bob.steps[1], a_user),
        "release_step_id",
    )
    # Bob's instruction under Alice's name
    _refused(
        writer,
        RECIPIENT,
        (bob.instruction, alice.contacts["Dad"], alice.steps[1], a_user),
        "instruction_id",
    )
    # the owner column itself cannot be pointed at the other person
    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        writer.execute(
            RECIPIENT,  # type: ignore[arg-type]
            (alice.instruction, alice.contacts["Dad"], alice.steps[1], bob.person.user_id),
        )
    assert snapshot(world.db) == before

    # the same statement with Alice's own contact and stage is accepted, so the refusals above
    # are about ownership and nothing else
    writer.execute(
        RECIPIENT,  # type: ignore[arg-type]
        (alice.instruction, alice.contacts["Dad"], alice.steps[1], a_user),
    )
    count = world.db.execute(
        "SELECT count(*) AS n FROM instruction_recipients WHERE user_id = %s", (a_user,)
    ).fetchone()
    assert count == {"n": 1}


async def test_the_database_refuses_a_plan_stage_that_notifies_another_owners_contact(
    world: World, writer: Conn
) -> None:
    alice = await _owner(world, "alice@example.com")
    bob = await _owner(world, "bob@example.com")
    a_user = alice.person.user_id

    before = snapshot(world.db)
    _refused(
        writer, STEP_CONTACT, (alice.steps[0], bob.contacts["Mom"], a_user), "contact_id"
    )  # Bob's contact at Alice's stage
    _refused(
        writer, STEP_CONTACT, (bob.steps[0], alice.contacts["Dad"], a_user), "step_id"
    )  # Alice's contact at Bob's stage, under Alice's name
    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        writer.execute(
            STEP_CONTACT,  # type: ignore[arg-type]
            (alice.steps[0], alice.contacts["Dad"], bob.person.user_id),
        )
    assert snapshot(world.db) == before

    writer.execute(
        STEP_CONTACT,  # type: ignore[arg-type]
        (alice.steps[0], alice.contacts["Dad"], a_user),  # her own, at her own stage
    )
    count = world.db.execute(
        "SELECT count(*) AS n FROM escalation_step_contacts WHERE step_id = %s",
        (alice.steps[0],),
    ).fetchone()
    assert count == {"n": 2}  # Mom (from the plan) and now Dad


async def test_patching_recipients_with_someone_elses_contact_or_stage_is_a_404(
    world: World,
) -> None:
    alice = await _owner(world, "alice@example.com")
    bob = await _owner(world, "bob@example.com")
    person = bob.person
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204  # the step-up is not in play
    path = f"/v1/instructions/{bob.instruction}"

    before = snapshot(world.db)
    foreign = (
        {"contact_id": alice.contacts["Dad"], "release_stage_id": bob.steps[1]},  # her contact
        {"contact_id": bob.contacts["Dad"], "release_stage_id": alice.steps[1]},  # her stage
        {"contact_id": alice.contacts["Dad"], "release_stage_id": alice.steps[1]},  # both
        {"contact_id": str(uuid.uuid4()), "release_stage_id": bob.steps[1]},  # unknown
    )
    for recipient in foreign:
        response = await world.h.client.patch(
            path, json={"recipients": [recipient]}, headers=person.headers
        )
        assert response.status_code == 404, recipient
        assert problem(response)["code"] == "not_found"
        for private in (alice.contacts["Dad"], alice.steps[1], alice.person.email):
            assert private not in response.text
    assert snapshot(world.db) == before  # nothing was written, not even an audit row

    # mixed with one of his own, the whole request is refused: no partial assignment
    mixed = await world.h.client.patch(
        path,
        json={
            "recipients": [
                {"contact_id": bob.contacts["Dad"], "release_stage_id": bob.steps[1]},
                {"contact_id": alice.contacts["Dad"], "release_stage_id": bob.steps[1]},
            ]
        },
        headers=person.headers,
    )
    assert mixed.status_code == 404
    assert snapshot(world.db) == before

    # the same route with his own contact and stage works, so the 404s were about ownership
    own = await world.h.client.patch(
        path,
        json={
            "recipients": [{"contact_id": bob.contacts["Dad"], "release_stage_id": bob.steps[1]}]
        },
        headers=person.headers,
    )
    assert own.status_code == 200, own.text
    assert [r["contact_id"] for r in own.json()["recipients"]] == [bob.contacts["Dad"]]
