"""A notification row is not trusted for what it says it is (Phase 9 review BD-1; T2).

``afterme_api`` may insert messages (it enqueues all-clears and the person's own notices), so a
compromised API role could try to make the dispatcher send "X has not checked in" to any contact
by choosing a category that skips the escalation gate. Three locks hold, and each is tested alone:

1. the trigger on ``notifications`` allows the API role exactly the (category, audience,
   template) combinations the API process writes;
2. the database says that the alert templates exist only in the escalation category, whoever
   writes, and that a message names a contact of its own account;
3. the dispatcher does not take a row's word for it either, so a row that got past both (the
   owner role, a restore) is cancelled unsent.
"""

from __future__ import annotations

import uuid
from datetime import timedelta
from typing import Any

import psycopg
import pytest

from tests.support import API_PASSWORD, connect
from tests.world import Person, World, ist

Conn = psycopg.Connection[dict[str, Any]]
DUE = ist("2026-10-09T20:00")
STAGE_1 = DUE + timedelta(minutes=180)

INSERT = (
    "INSERT INTO notifications (user_id, audience, category, contact_id, channel, template_key, "
    "params, send_after, dedupe_key) VALUES (%s, %s, %s, %s, %s, %s, %s::jsonb, %s, %s)"
)


def _row(person: Person, contact_id: str | None, **over: Any) -> tuple[Any, ...]:
    """A row due at the frozen clock's now (``over['send_after']``, else the epoch)."""
    values: dict[str, Any] = {
        "audience": "contact",
        "category": "contact_other",
        "channel": "email",
        "template": "contact_all_clear",
        "params": "{}",
        "send_after": ist("2026-01-01T00:00"),
        **over,
    }
    return (
        person.user_id,
        values["audience"],
        values["category"],
        contact_id,
        values["channel"],
        values["template"],
        values["params"],
        values["send_after"],
        f"test:{uuid.uuid4()}",
    )


async def _person(world: World) -> tuple[Person, str]:
    person = await world.ready()
    return person, person.contacts["Mom"]


# --- 1. the trigger -------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("category", "audience", "template"),
    [
        # the forged alert: any category but the escalation one, any audience
        ("user", "contact", "contact_alert"),
        ("contact_other", "contact", "contact_alert"),
        ("contact_other", "contact", "contact_alert_with_release"),
        ("user", "contact", "incident_missed"),
        # a user template aimed at a contact, a contact template aimed at a user
        ("contact_other", "contact", "incident_missed"),
        ("user", "user", "contact_all_clear"),
        # not a template the API writes
        ("contact_other", "contact", "checkin_pre_reminder"),
        ("user", "user", "contact_alert"),
        # the escalation category is the engine's alone
        ("contact_escalation", "contact", "contact_alert"),
    ],
)
async def test_the_api_role_cannot_enqueue_what_the_engine_alone_writes(
    world: World, category: str, audience: str, template: str
) -> None:
    person, contact_id = await _person(world)
    refusals = (psycopg.errors.InsufficientPrivilege, psycopg.errors.CheckViolation)
    row = _row(
        person,
        contact_id if audience == "contact" else None,
        category=category,
        audience=audience,
        template=template,
    )
    with connect("afterme_api", API_PASSWORD) as api, pytest.raises(refusals):
        api.execute(INSERT, row)
    count = world.db.execute(
        "SELECT count(*) AS n FROM notifications WHERE dedupe_key LIKE 'test:%'"
    ).fetchone()
    assert count == {"n": 0}


async def test_the_api_role_still_enqueues_what_it_is_for(world: World) -> None:
    """The positive control: the refusals above are not the trigger refusing everything."""
    person, contact_id = await _person(world)
    with connect("afterme_api", API_PASSWORD) as api:
        api.execute(INSERT, _row(person, contact_id))  # an all-clear to its own contact
        api.execute(
            INSERT,
            _row(
                person,
                None,
                audience="user",
                category="user",
                template="all_clear_confirmation",
            ),
        )
        api.execute(INSERT, _row(person, contact_id, template="contact_release"))
    count = world.db.execute(
        "SELECT count(*) AS n FROM notifications WHERE dedupe_key LIKE 'test:%'"
    ).fetchone()
    assert count == {"n": 3}


# --- 2. the constraints, for every role ------------------------------------------------------


async def test_an_alert_template_exists_only_in_the_escalation_category(world: World) -> None:
    person, contact_id = await _person(world)
    for template in ("contact_alert", "contact_alert_with_release"):
        with pytest.raises(psycopg.errors.CheckViolation):
            world.db.execute(INSERT, _row(person, contact_id, template=template))


async def test_a_message_cannot_name_a_contact_of_another_account(world: World) -> None:
    person, _ = await _person(world)
    other = await world.ready(
        "someone.else@example.com", contacts=("Dad",), stages=((180, ("Dad",)),)
    )
    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        world.db.execute(INSERT, _row(person, other.contacts["Dad"]))


# --- 3. the dispatcher ------------------------------------------------------------------------


async def test_the_dispatcher_cancels_a_row_that_is_not_what_it_claims_to_be(
    world: World,
) -> None:
    """Rows only the owner role can create (a restore, a migration slip) are cancelled unsent:
    a user template aimed at a contact, a contact template aimed at the person, a link kind in
    the user category."""
    person, contact_id = await _person(world)
    forged = (
        _row(person, contact_id, category="user", template="incident_missed"),
        _row(person, contact_id, category="contact_other", template="incident_missed"),
        _row(
            person,
            None,
            audience="user",
            category="user",
            template="contact_all_clear",
        ),
        _row(person, contact_id, category="user", template="contact_all_clear"),
    )
    for row in forged:
        world.db.execute(INSERT, row)
    world.mail.clear()
    await world.tick()

    rows = world.db.execute(
        "SELECT status, cancelled_reason FROM notifications WHERE dedupe_key LIKE 'test:%'"
    ).fetchall()
    assert len(rows) == len(forged)
    assert {(r["status"], r["cancelled_reason"]) for r in rows} == {
        ("cancelled", "unexpected_shape")
    }
    assert world.mail.messages == []


async def test_an_all_clear_goes_only_to_a_contact_who_was_told_something(
    world: World,
) -> None:
    """A well-formed row for a contact nobody ever messaged: there is nothing to take back, and
    "X is safe" to someone who never heard otherwise is itself a message from nowhere."""
    person, contact_id = await _person(world)
    world.db.execute(INSERT, _row(person, contact_id, params='{"reason": "user_safe"}'))
    world.mail.clear()
    await world.tick()
    row = world.db.execute(
        "SELECT status, cancelled_reason FROM notifications WHERE dedupe_key LIKE 'test:%'"
    ).fetchone()
    assert row == {"status": "cancelled", "cancelled_reason": "not_messaged"}
    assert world.mail.messages == []


async def test_a_message_that_cannot_be_built_does_not_starve_the_ones_behind_it(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A row whose processing raises is put back with a backoff, so a hundred of them cannot
    occupy every batch while a real alert waits. It is never marked failed by that alone."""
    from app.engine import dispatcher as module

    person = await world.ready()
    await world.advance_to(STAGE_1 - timedelta(minutes=1))
    original = module.Dispatcher._build

    async def broken(self: Any, session: Any, row: Any, now: Any) -> Any:
        if row.template_key == "contact_unreachable":
            raise RuntimeError("template removed in a deploy")
        return await original(self, session, row, now)

    monkeypatch.setattr(module.Dispatcher, "_build", broken)
    world.db.execute(
        "INSERT INTO notifications (user_id, audience, category, channel, template_key, params, "
        "send_after, dedupe_key) VALUES (%s, 'user', 'user', 'email', 'contact_unreachable', "
        "'{}'::jsonb, %s, 'poison-1')",
        (person.user_id, world.clock.current),
    )
    report = await world.dispatcher.dispatch()
    assert report.errors == 1
    row = world.db.execute(
        "SELECT status, attempt_count, next_attempt_at FROM notifications "
        "WHERE dedupe_key = 'poison-1'"
    ).fetchone()
    assert row is not None
    assert row["status"] == "queued"
    assert row["attempt_count"] == 1
    assert row["next_attempt_at"] > world.clock.current
    # and the next pass does not pick it up again at once
    again = await world.dispatcher.dispatch()
    assert again.errors == 0
    # the alert behind it still goes out
    monkeypatch.undo()
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    assert world.mail.to(f"mom.{person.user_id[:6]}@example.com", "contact_alert")


# --- the retention role ----------------------------------------------------------------------


async def test_the_retention_role_scrubs_only_the_contacts_of_a_closed_account(
    world: World,
) -> None:
    person, contact_id = await _person(world)
    conn = world.db
    conn.execute("SET ROLE afterme_maintenance")
    try:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute(
                "UPDATE trusted_contacts SET is_active = false WHERE id = %s", (contact_id,)
            )
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute(
                "INSERT INTO audit_logs (actor_type, action) VALUES ('operator', 'operator.void')"
            )
        # what it is for
        conn.execute("RESET ROLE")
        conn.execute(
            "UPDATE users SET status = 'pending_deletion', deletion_requested_at = now() "
            "WHERE id = %s",
            (person.user_id,),
        )
        conn.execute("SET ROLE afterme_maintenance")
        conn.execute("UPDATE trusted_contacts SET is_active = false WHERE id = %s", (contact_id,))
        conn.execute(
            "INSERT INTO audit_logs (actor_type, action) VALUES ('system', 'account.purged')"
        )
    finally:
        conn.execute("RESET ROLE")
