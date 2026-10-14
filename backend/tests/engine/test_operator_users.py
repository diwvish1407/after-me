"""The operator's per-account commands (``python -m cli.admin user set-tier | suspend |
unsuspend``) against the real database, as the ``afterme_worker`` role the CLI connects as
(DEPLOYMENT §9; SECURITY §13, T37; TEST_PLAN SEC-26).

What is asserted, and why:

* ``set-tier`` changes ``users.tier`` and nothing else, is idempotent, and a downgrade deletes
  nothing (PRD §10): the person keeps what they have and cannot add more;
* ``suspend`` ends every session (app and web), makes login, refresh and old bearer tokens fail
  (``401``), voids no incident and sends nothing; ``unsuspend`` only ever goes ``suspended`` to
  ``active``;
* every change is one audit row with an operator actor, never visible to the account holder, and
  the operator's reason is in that row only: not in a log;
* a closing account (``pending_deletion``) and an unknown one are refused with a clear message.
"""

from __future__ import annotations

import io
import logging
import uuid
from collections.abc import Iterator
from datetime import timedelta
from typing import Any

import pytest

from app.core.logging import build_formatter
from app.ops import users
from cli.admin import _parser, _user_command
from tests.engine.test_web_checkin import _sign_in
from tests.support import PASSWORD, bearer, problem
from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")
STAGE_1 = DUE + timedelta(minutes=180)
REASON = "ticket OPS-4412: beta tester, premium until the end of the beta"


@pytest.fixture
def captured() -> Iterator[io.StringIO]:
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(build_formatter(json=True))
    handler.setLevel(logging.DEBUG)
    root = logging.getLogger()
    previous = root.level
    root.addHandler(handler)
    root.setLevel(logging.DEBUG)
    try:
        yield stream
    finally:
        root.removeHandler(handler)
        root.setLevel(previous)


def _id(person: Person) -> uuid.UUID:
    return uuid.UUID(person.user_id)


def _audit(world: World, action: str, person: Person) -> list[dict[str, Any]]:
    return [
        dict(r)
        for r in world.db.execute(
            "SELECT * FROM audit_logs WHERE action = %s AND subject_user_id = %s ORDER BY id",
            (action, person.user_id),
        ).fetchall()
    ]


def _user_row(world: World, person: Person) -> dict[str, Any]:
    row = world.db.execute("SELECT * FROM users WHERE id = %s", (person.user_id,)).fetchone()
    assert row is not None
    return dict(row)


def _open_sessions(world: World, person: Person) -> list[dict[str, Any]]:
    return [
        dict(r)
        for r in world.db.execute(
            "SELECT id, kind, revoked_at, revoke_reason FROM sessions WHERE user_id = %s "
            "ORDER BY created_at, id",
            (person.user_id,),
        ).fetchall()
    ]


async def _entitlements(world: World, person: Person) -> dict[str, Any]:
    await world.login(person)
    response = await world.h.client.get("/v1/me/entitlements", headers=person.headers)
    assert response.status_code == 200, response.text
    body: dict[str, Any] = response.json()
    return body


# --- the role --------------------------------------------------------------------------------


async def test_the_commands_run_as_the_worker_role_without_any_new_grant(world: World) -> None:
    services = world.engine.services
    assert await services.db.current_role() == "afterme_worker"
    person = await world.ready("role@example.com", premium=False)
    # all three, as that role, on a real account with a schedule, a plan and a contact
    assert (
        await users.set_tier(
            services, operator="alex", user_id=_id(person), tier="premium", reason=REASON
        )
    ).changed
    assert (
        await users.suspend(services, operator="alex", user_id=_id(person), reason=REASON)
    ).changed
    assert (
        await users.unsuspend(services, operator="alex", user_id=_id(person), reason=REASON)
    ).changed


# --- set-tier --------------------------------------------------------------------------------


async def test_set_tier_changes_the_tier_and_nothing_else(world: World) -> None:
    person = await world.ready("holder@example.com", premium=False)
    before = _user_row(world, person)
    assert before["tier"] == "free"

    change = await users.set_tier(
        world.engine.services,
        operator="alex",
        user_id=_id(person),
        tier="premium",
        reason=REASON,
    )

    assert (change.changed, change.before, change.after) == (True, "free", "premium")
    after = _user_row(world, person)
    assert after["tier"] == "premium"
    for column, value in before.items():
        if column not in ("tier", "updated_at"):
            assert after[column] == value, column
    # the limits are those of the new tier, for the person
    body = await _entitlements(world, person)
    assert body["tier"] == "premium"
    assert body["limits"]["contacts"] == 25
    # and take effect: a second contact, impossible on the free tier, is accepted
    response = await world.h.add_contact(person.tokens, "second.contact@example.com", name="Dad")
    assert response.status_code == 201, response.text


async def test_set_tier_is_audited_with_an_operator_actor_and_is_not_shown_to_the_holder(
    world: World,
) -> None:
    person = await world.ready("holder@example.com", premium=False)
    await users.set_tier(
        world.engine.services, operator="alex", user_id=_id(person), tier="premium", reason=REASON
    )

    [row] = _audit(world, "operator.set_tier", person)
    assert row["actor_type"] == "operator"
    assert row["actor_id"] is None
    assert row["resource_type"] == "user"
    assert str(row["resource_id"]) == person.user_id
    assert row["user_visible"] is False
    assert row["metadata"] == {
        "operator": "alex",
        "from_tier": "free",
        "to_tier": "premium",
        "reason_length": len(REASON),
        "operator_note": REASON,
    }
    # the person's Activity feed does not carry it
    await world.login(person)
    feed = await world.h.client.get("/v1/activity", headers=person.headers)
    assert feed.status_code == 200
    assert "operator" not in feed.text
    assert REASON not in feed.text


async def test_set_tier_twice_is_one_change(world: World) -> None:
    person = await world.ready("holder@example.com", premium=False)
    services = world.engine.services
    first = await users.set_tier(
        services, operator="alex", user_id=_id(person), tier="premium", reason=REASON
    )
    again = await users.set_tier(
        services, operator="alex", user_id=_id(person), tier="premium", reason=REASON
    )
    assert (first.changed, again.changed) == (True, False)
    assert len(_audit(world, "operator.set_tier", person)) == 1  # a no-op is not an event
    assert _user_row(world, person)["tier"] == "premium"


async def test_a_downgrade_deletes_nothing_and_only_stops_further_additions(
    world: World,
) -> None:
    person = await world.ready(
        "heavy@example.com",
        contacts=("Mom", "Dad", "Sis"),
        stages=((180, ("Mom",)), (1440, ("Dad",)), (2880, ("Sis",))),
        premium=True,
    )
    live_before = world.db.execute(
        "SELECT count(*) AS n FROM trusted_contacts WHERE user_id = %s AND deleted_at IS NULL",
        (person.user_id,),
    ).fetchone()
    steps_before = world.db.execute(
        "SELECT count(*) AS n FROM escalation_steps WHERE user_id = %s", (person.user_id,)
    ).fetchone()
    assert live_before == {"n": 3}
    assert steps_before == {"n": 3}

    change = await users.set_tier(
        world.engine.services, operator="alex", user_id=_id(person), tier="free", reason=REASON
    )

    assert change.changed
    [note] = change.notes
    assert "contacts 3 of 1" in note
    assert "stages 3 of 2" in note
    assert "nothing is deleted" in note
    # nothing was removed ...
    assert world.db.execute(
        "SELECT count(*) AS n FROM trusted_contacts WHERE user_id = %s AND deleted_at IS NULL",
        (person.user_id,),
    ).fetchone() == {"n": 3}
    assert world.db.execute(
        "SELECT count(*) AS n FROM escalation_steps WHERE user_id = %s", (person.user_id,)
    ).fetchone() == {"n": 3}
    assert world.config(person)["status"] == "active"  # the safety net is still on
    body = await _entitlements(world, person)
    assert body["tier"] == "free"
    assert body["usage"]["contacts"] == 3
    assert body["limits"]["contacts"] == 1
    # ... they can still read it, and nothing more can be added
    listed = await world.h.client.get("/v1/contacts", headers=person.headers)
    assert len(listed.json()["items"]) == 3
    refused = await world.h.add_contact(person.tokens, "fourth@example.com", name="Four")
    assert refused.status_code == 403
    assert problem(refused)["code"] == "plan_limit_reached"
    # and the escalation still works for what they have
    await world.advance_to(STAGE_1 + timedelta(minutes=10))
    assert len(world.mail.to(f"mom.{person.user_id[:6]}@example.com", "contact_alert")) == 1


async def test_set_tier_to_an_unknown_tier_is_refused(world: World) -> None:
    person = await world.ready("holder@example.com", premium=False)
    with pytest.raises(users.UserCommandError, match="tier must be one of"):
        await users.set_tier(
            world.engine.services, operator="alex", user_id=_id(person), tier="gold", reason=REASON
        )
    assert _user_row(world, person)["tier"] == "free"
    assert _audit(world, "operator.set_tier", person) == []


# --- suspend and unsuspend ---------------------------------------------------------------------


@pytest.mark.no_rate_limit
async def test_suspend_ends_every_session_and_nothing_signs_in_again(world: World) -> None:
    person = await world.ready("holder@example.com")
    first = dict(person.tokens)  # the app session made at sign-up
    await world.login(person)  # a second app session (another phone)
    second = dict(person.tokens)
    assert (await _sign_in(world, person)).status_code == 303  # and a web session
    sessions = _open_sessions(world, person)
    assert {s["kind"] for s in sessions} == {"app", "web"}
    live = [s for s in sessions if s["revoked_at"] is None]
    assert len(live) >= 3
    for tokens in (first, second):  # the control: both work before
        ok = await world.h.client.get("/v1/me", headers=bearer(tokens))
        assert ok.status_code == 200

    change = await users.suspend(
        world.engine.services, operator="alex", user_id=_id(person), reason=REASON
    )

    assert (change.changed, change.before, change.after) == (True, "active", "suspended")
    assert change.sessions_revoked == len(live)
    assert _user_row(world, person)["status"] == "suspended"
    after = _open_sessions(world, person)
    assert all(s["revoked_at"] is not None for s in after)
    assert {s["revoke_reason"] for s in after} == {"operator"}
    assert {s["kind"] for s in after} == {"app", "web"}
    # the bearer tokens of both app sessions stop working at once ...
    for tokens in (first, second):
        gone = await world.h.client.get("/v1/me", headers=bearer(tokens))
        assert gone.status_code == 401
    # ... the refresh tokens cannot be exchanged ...
    for tokens in (first, second):
        refreshed = await world.h.refresh(tokens["refresh_token"])
        assert refreshed.status_code == 401
    # ... the password buys nothing, in the app or on the web page ...
    assert (await world.h.login(person.email)).status_code == 401
    web = await _sign_in(world, person, PASSWORD)
    assert web.status_code == 401
    # ... and the web cookie of the session that was open is dead
    page = await world.h.client.get("/a/checkin")
    assert "I'M OK" not in page.text


@pytest.mark.no_rate_limit
async def test_suspend_twice_is_one_change_and_unsuspend_restores_only_the_status(
    world: World,
) -> None:
    person = await world.ready("holder@example.com")
    services = world.engine.services
    old = dict(person.tokens)

    first = await users.suspend(services, operator="alex", user_id=_id(person), reason=REASON)
    again = await users.suspend(services, operator="alex", user_id=_id(person), reason=REASON)
    assert (first.changed, again.changed) == (True, False)
    assert again.sessions_revoked == 0
    assert len(_audit(world, "operator.suspend_user", person)) == 1

    back = await users.unsuspend(services, operator="alex", user_id=_id(person), reason=REASON)
    assert (back.changed, back.before, back.after) == (True, "suspended", "active")
    assert _user_row(world, person)["status"] == "active"
    # nothing is restored: the old sessions stay revoked, the person signs in again
    assert (await world.h.client.get("/v1/me", headers=bearer(old))).status_code == 401
    fresh = await world.h.login(person.email)
    assert fresh.status_code == 200
    assert (await world.h.client.get("/v1/me", headers=bearer(fresh.json()))).status_code == 200
    # unsuspending an account that is not suspended changes nothing and is not an event
    noop = await users.unsuspend(services, operator="alex", user_id=_id(person), reason=REASON)
    assert (noop.changed, noop.before) == (False, "active")
    assert len(_audit(world, "operator.unsuspend_user", person)) == 1


async def test_suspend_and_unsuspend_are_audited_as_the_operator(world: World) -> None:
    person = await world.ready("holder@example.com")
    services = world.engine.services
    await users.suspend(services, operator="alex", user_id=_id(person), reason="abuse report")
    await users.unsuspend(services, operator="sam", user_id=_id(person), reason="reviewed, fine")

    [suspended] = _audit(world, "operator.suspend_user", person)
    assert suspended["actor_type"] == "operator"
    assert suspended["user_visible"] is False
    assert suspended["metadata"]["operator"] == "alex"
    assert suspended["metadata"]["from_status"] == "active"
    assert suspended["metadata"]["sessions_revoked"] >= 1
    assert suspended["metadata"]["operator_note"] == "abuse report"
    [restored] = _audit(world, "operator.unsuspend_user", person)
    assert restored["actor_type"] == "operator"
    assert restored["user_visible"] is False
    assert restored["metadata"]["operator"] == "sam"
    assert restored["metadata"]["operator_note"] == "reviewed, fine"


async def test_suspending_voids_no_incident_and_sends_nothing(world: World) -> None:
    person = await world.ready("holder@example.com")
    await world.advance_to(DUE + timedelta(minutes=30))
    incident = world.open_incident(person)
    assert incident is not None
    assert incident["status"] == "grace"
    mail_before = len(world.mail.messages)
    queued_before = len(world.notifications(person))
    actions_before = [
        (a["id"], a["status"]) for a in world.actions(person) if a["kind"] == "execute_stage"
    ]

    change = await users.suspend(
        world.engine.services, operator="alex", user_id=_id(person), reason=REASON
    )

    # the command itself: the incident is as it was, nothing was queued or sent
    assert change.changed
    [note] = change.notes
    assert str(incident["id"]) in note
    assert "incident void" in note  # tells the operator how, and that it did not
    still = world.open_incident(person)
    assert still is not None
    assert (still["id"], still["status"]) == (incident["id"], "grace")
    assert len(world.notifications(person)) == queued_before
    assert len(world.mail.messages) == mail_before
    assert [
        (a["id"], a["status"]) for a in world.actions(person) if a["kind"] == "execute_stage"
    ] == actions_before

    # what the engine does with a suspended account afterwards is the existing rule: the stage
    # is cancelled at its time (G5), nobody is alerted, and the incident is left open
    await world.advance_to(STAGE_1 + timedelta(minutes=10))
    stage = world.actions(person, kind="execute_stage")[0]
    assert (stage["status"], stage["outcome"]) == ("cancelled", {"cancelled_by_gate": "G5"})
    assert world.notifications(person, template_key="contact_alert") == []
    assert world.mail.to(f"mom.{person.user_id[:6]}@example.com", "contact_alert") == []
    assert world.open_incident(person) is not None


async def test_a_deadline_that_passes_while_suspended_is_reported_on_unsuspend(
    world: World,
) -> None:
    person = await world.ready("holder@example.com")
    services = world.engine.services
    await users.suspend(services, operator="alex", user_id=_id(person), reason=REASON)

    await world.advance_to(DUE + timedelta(minutes=20))
    assert world.incidents(person) == []  # nothing opens for a suspended account

    change = await users.unsuspend(services, operator="alex", user_id=_id(person), reason=REASON)
    [note] = change.notes
    assert "deadline" in note
    assert world.incidents(person) == []  # the command opens nothing itself
    await world.tick()
    incident = world.open_incident(person)
    assert incident is not None
    # the anchor rule: a full grace period from when it really opened, not from the deadline
    assert incident["opened_at"] >= DUE + timedelta(minutes=20)
    assert incident["anchor_at"] == incident["opened_at"]


# --- refusals ----------------------------------------------------------------------------------


async def _apply(world: World, command: str, user_id: uuid.UUID) -> users.UserChange:
    """One of the three commands by name, so that a refusal test holds a single statement."""
    services = world.engine.services
    if command == "set_tier":
        return await users.set_tier(
            services, operator="alex", user_id=user_id, tier="premium", reason=REASON
        )
    if command == "suspend":
        return await users.suspend(services, operator="alex", user_id=user_id, reason=REASON)
    return await users.unsuspend(services, operator="alex", user_id=user_id, reason=REASON)


@pytest.mark.parametrize("command", ["set_tier", "suspend", "unsuspend"])
async def test_an_unknown_user_is_refused_with_a_clear_message(world: World, command: str) -> None:
    with pytest.raises(users.UserCommandError, match="no such user"):
        await _apply(world, command, uuid.uuid4())
    count = world.db.execute(
        "SELECT count(*) AS n FROM audit_logs WHERE action LIKE 'operator.%%_user' "
        "OR action = 'operator.set_tier'"
    ).fetchone()
    assert count == {"n": 0}


@pytest.mark.parametrize("command", ["set_tier", "suspend", "unsuspend"])
async def test_an_account_that_is_closing_is_refused_and_left_alone(
    world: World, command: str
) -> None:
    person = await world.ready("closing@example.com", premium=False)
    world.db.execute(
        "UPDATE users SET status = 'pending_deletion', deletion_requested_at = now() WHERE id = %s",
        (person.user_id,),
    )
    before = _user_row(world, person)
    with pytest.raises(users.UserCommandError, match="pending deletion"):
        await _apply(world, command, _id(person))
    assert _user_row(world, person) == before
    sessions = _open_sessions(world, person)
    assert all(s["revoke_reason"] != "operator" for s in sessions)
    for action in ("operator.set_tier", "operator.suspend_user", "operator.unsuspend_user"):
        assert _audit(world, action, person) == []


@pytest.mark.parametrize(
    "reason", ["", "   ", "x" * 201, "two\nlines", "bell\x07", "bidi " + chr(0x202E)]
)
async def test_a_reason_that_is_not_one_short_printable_line_is_refused(
    world: World, reason: str
) -> None:
    person = await world.ready("holder@example.com", premium=False)
    with pytest.raises(users.UserCommandError):
        await users.suspend(
            world.engine.services, operator="alex", user_id=_id(person), reason=reason
        )
    assert _user_row(world, person)["status"] == "active"
    assert _audit(world, "operator.suspend_user", person) == []


# --- what is logged -----------------------------------------------------------------------------


async def test_the_reason_and_the_person_never_reach_a_log(
    world: World, captured: io.StringIO
) -> None:
    person = await world.ready("holder@example.com", premium=False)
    services = world.engine.services
    marker = "zebra-reason-marker-4412"
    await users.set_tier(
        services, operator="alex", user_id=_id(person), tier="premium", reason=f"{marker} one"
    )
    await users.suspend(services, operator="alex", user_id=_id(person), reason=f"{marker} two")
    await users.unsuspend(services, operator="alex", user_id=_id(person), reason=f"{marker} three")

    output = captured.getvalue()
    assert "operator.user_tier_set" in output
    assert "operator.user_suspended" in output
    assert "operator.user_unsuspended" in output
    assert person.user_id in output  # the pseudonymous id is what a log carries
    for secret in (marker, person.email, "Test User", PASSWORD):
        assert secret not in output, f"leaked into logs: {secret[:12]}"
    # and the reason is where it belongs: in the audit rows, as the operator's own text
    notes = [
        r["metadata"]["operator_note"]
        for r in world.db.execute(
            "SELECT metadata FROM audit_logs WHERE action IN "
            "('operator.set_tier', 'operator.suspend_user', 'operator.unsuspend_user') ORDER BY id"
        ).fetchall()
    ]
    assert notes == [f"{marker} one", f"{marker} two", f"{marker} three"]


# --- the command line ----------------------------------------------------------------------------


async def test_the_command_line_says_what_happened_and_exits_2_when_refused(
    world: World, capsys: pytest.CaptureFixture[str]
) -> None:
    person = await world.ready("holder@example.com", premium=False)
    services = world.engine.services

    async def run(*argv: str) -> tuple[int, str]:
        args = _parser().parse_args(["--operator", "alex", *argv])
        code = await _user_command(args, services, "alex")
        return code, capsys.readouterr().out

    code, out = await run("user", "set-tier", person.user_id, "premium", "--reason", REASON)
    assert (code, out.strip()) == (0, "tier set: free -> premium")
    code, out = await run("user", "set-tier", person.user_id, "premium", "--reason", REASON)
    assert (code, out.strip()) == (0, "tier is already premium; nothing changed")

    code, out = await run("user", "suspend", person.user_id, "--reason", REASON)
    assert code == 0
    assert out.startswith("suspended (was active); sessions revoked: ")
    code, out = await run("user", "unsuspend", person.user_id, "--reason", REASON)
    assert code == 0
    assert out.startswith("unsuspended: the account is active again")
    code, out = await run("user", "unsuspend", person.user_id, "--reason", REASON)
    assert (code, out.strip()) == (
        0,
        "the account is not suspended (status active); nothing changed",
    )

    code, out = await run("user", "suspend", str(uuid.uuid4()), "--reason", REASON)
    assert (code, out.strip()) == (2, "refused: no such user")
    world.db.execute(
        "UPDATE users SET status = 'pending_deletion', deletion_requested_at = now() WHERE id = %s",
        (person.user_id,),
    )
    code, out = await run("user", "suspend", person.user_id, "--reason", REASON)
    assert code == 2
    assert out.startswith("refused: the account is closed (pending deletion)")


# --- an open incident and a suspension (Phase 10 review, USR-1) ---------------------------------


async def test_unsuspend_is_refused_while_the_account_has_an_open_incident(world: World) -> None:
    """Gate G5 cancels an incident's actions while its owner is not active and nothing brings
    them back: unsuspending would leave a dead incident that also keeps every future incident
    from opening. The operator must void it first."""
    from app.ops import admin

    person = await world.ready("holder@example.com")
    services = world.engine.services
    await world.advance_to(DUE + timedelta(minutes=30))
    incident = world.open_incident(person)
    assert incident is not None
    await users.suspend(services, operator="alex", user_id=_id(person), reason=REASON)

    # status says so, as a warning that names the incident
    status = await admin.engine_status(services)
    assert f"suspended account with an open incident {incident['id']}" in status.warnings

    with pytest.raises(users.UserCommandError) as refused:
        await users.unsuspend(services, operator="alex", user_id=_id(person), reason=REASON)
    assert str(incident["id"]) in str(refused.value)
    assert f"incident void {incident['id']}" in str(refused.value)
    # nothing changed: still suspended, no event recorded, the incident untouched
    assert _user_row(world, person)["status"] == "suspended"
    assert _audit(world, "operator.unsuspend_user", person) == []
    assert world.open_incident(person)["id"] == incident["id"]  # type: ignore[index]

    # the way out the message names: void it (a normal void: the schedule restarts), then unsuspend
    assert await admin.void_incident(services, operator="alex", incident_id=incident["id"])
    back = await users.unsuspend(services, operator="alex", user_id=_id(person), reason=REASON)
    assert (back.before, back.after, back.changed) == ("suspended", "active", True)
    status = await admin.engine_status(services)
    assert not [w for w in status.warnings if w.startswith("suspended account")]


async def test_unsuspend_with_an_open_incident_exits_2_on_the_command_line(
    world: World, capsys: pytest.CaptureFixture[str]
) -> None:
    person = await world.ready("holder@example.com")
    services = world.engine.services
    await world.advance_to(DUE + timedelta(minutes=30))
    incident_id = world.open_incident(person)["id"]  # type: ignore[index]
    await users.suspend(services, operator="alex", user_id=_id(person), reason=REASON)

    args = _parser().parse_args(
        ["--operator", "alex", "user", "unsuspend", person.user_id, "--reason", REASON]
    )
    code = await _user_command(args, services, "alex")
    out = capsys.readouterr().out
    assert code == 2
    assert out.startswith("refused: incident ")
    assert str(incident_id) in out
    assert "incident void" in out
