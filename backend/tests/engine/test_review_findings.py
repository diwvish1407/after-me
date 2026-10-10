"""Regression tests for the independent review of the Phase 5 engine.

Each test names the review finding it closes (F-nn). They drive the real API, engine and
dispatcher through the :class:`~tests.world.World`, as the rest of ``tests/engine`` does.
"""

from __future__ import annotations

import asyncio
import json
import uuid
from datetime import timedelta
from typing import Any

import psycopg
import pytest
from psycopg.rows import dict_row
from sqlalchemy.exc import OperationalError

from app.engine import dispatcher as dispatcher_module
from app.engine import runtime as runtime_module
from app.engine.hold import HoldMonitor
from app.engine.store import EngineStore
from app.ops import admin
from tests.support import API_PASSWORD, conninfo
from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")
STAGE_1 = DUE + timedelta(minutes=180)
STAGE_2 = DUE + timedelta(minutes=1440)


def address(person: Person, label: str) -> str:
    return f"{label.lower()}.{person.user_id[:6]}@example.com"


def forge(world: World, person: Person, **overrides: Any) -> uuid.UUID:
    """A ``contact_escalation`` notification the engine did not write (the API role may insert
    notifications), pointing at the open incident's executed stage."""
    incident = world.open_incident(person)
    assert incident is not None
    action = world.actions(person, kind="execute_stage")[0]
    values: dict[str, Any] = {
        "audience": "contact",
        "category": "contact_escalation",
        "contact_id": person.contacts["Mom"],
        "channel": "email",
        "template_key": "contact_alert",
        "send_after": world.clock.current,
        **overrides,
    }
    if "dedupe_key" not in values:
        # the shape the engine uses (a forger can read it), with a different instant so that
        # it does not collide with the real row
        stamp = int(action["scheduled_for"].timestamp()) + 1
        values["dedupe_key"] = f"notif:{action['id']}:{stamp}:contact:{values['contact_id']}:email"
    row = world.db.execute(
        "INSERT INTO notifications (user_id, audience, category, contact_id, channel, "
        "template_key, params, incident_id, action_id, status, send_after, dedupe_key) "
        "VALUES (%s, %s, %s, %s, %s, %s, %s::jsonb, %s, %s, 'queued', %s, %s) RETURNING id",
        (
            person.user_id,
            values["audience"],
            values["category"],
            values["contact_id"],
            values["channel"],
            values["template_key"],
            json.dumps({"stage_position": 1, "missed_due_at": DUE.isoformat()}),
            incident["id"],
            action["id"],
            values["send_after"],
            values["dedupe_key"],
        ),
    ).fetchone()
    assert row is not None
    return uuid.UUID(str(row["id"]))


def status_of(world: World, notification_id: uuid.UUID) -> dict[str, Any]:
    found = world.db.execute(
        "SELECT * FROM notifications WHERE id = %s", (notification_id,)
    ).fetchone()
    assert found is not None
    return dict(found)


# --- F-01: an operator void must not leave the person unmonitored -----------------------------


async def test_f01_a_void_with_nobody_told_puts_the_schedule_back_and_tells_the_person(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))
    incident = world.open_incident(person)
    assert incident is not None
    before = world.config(person)
    assert before["status"] == "incident_open"

    assert await admin.void_incident(
        world.engine.services, operator="alex", incident_id=incident["id"]
    )

    after = world.config(person)
    assert after["status"] == "active"
    assert after["next_due_at"] > world.clock.current  # a full interval ahead
    assert after["last_checkin_at"] == before["last_checkin_at"]  # a void is not a check-in
    assert world.open_incident(person) is None
    await world.tick()
    assert len(world.mail.to(person.email, "service_interruption")) == 1
    assert world.mail.to(address(person, "Mom"), "contact_alert") == []
    assert world.mail.to(address(person, "Mom"), "contact_all_clear") == []

    # ... and they are watched again: the next missed deadline opens an incident as usual
    await world.advance_to(after["next_due_at"] + timedelta(minutes=1))
    assert world.open_incident(person) is not None


async def test_f01_a_void_after_contacts_were_told_clears_them_and_restarts_the_schedule(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    incident = world.open_incident(person)
    assert incident is not None
    assert len(world.mail.to(address(person, "Mom"), "contact_alert")) == 1
    assert await admin.void_incident(
        world.engine.services, operator="alex", incident_id=incident["id"]
    )
    await world.tick()
    assert len(world.mail.to(address(person, "Mom"), "contact_all_clear")) == 1
    config = world.config(person)
    assert config["status"] == "active"
    assert config["next_due_at"] > world.clock.current
    # the all-clear confirmation already reaches the person: no second, contradictory notice
    assert world.mail.to(person.email, "service_interruption") == []


async def test_f01_a_void_never_says_nobody_was_contacted_when_someone_was(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    incident = world.open_incident(person)
    assert incident is not None
    assert len(world.mail.to(address(person, "Mom"), "contact_alert")) == 1
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204  # F-12
    response = await world.h.client.delete(
        f"/v1/contacts/{person.contacts['Mom']}", headers=person.headers
    )
    assert response.status_code == 204  # the only person who was told is gone

    assert await admin.void_incident(
        world.engine.services, operator="alex", incident_id=incident["id"]
    )
    await world.tick()
    assert world.mail.to(person.email, "service_interruption") == []  # it would be false
    assert world.config(person)["status"] == "active"  # but the schedule did restart


# --- F-02: if Hold cannot be evaluated, nothing contact-facing leaves -------------------------


async def test_f02_a_stage_does_not_run_while_hold_cannot_be_evaluated(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))  # incident open, in grace

    async def broken(self: HoldMonitor, now: Any) -> Any:
        msg = "probe watermark unreadable"
        raise RuntimeError(msg)

    monkeypatch.setattr(HoldMonitor, "evaluate", broken)
    await world.advance_to(STAGE_1 + timedelta(minutes=30))
    assert world.actions(person, kind="execute_stage")[0]["status"] == "pending"
    assert world.mail.to(address(person, "Mom"), "contact_alert") == []
    status = await admin.engine_status(world.engine.services)
    assert "hold evaluation failing" in status.pages

    monkeypatch.undo()  # Hold evaluation works again
    # Our own fail-safe kept it back for half an hour: it is put back once more and the person
    # warned again (F-03), then it runs on time.
    world.clock.set(STAGE_1 + timedelta(minutes=45))
    await world.tick()
    stage = world.actions(person, kind="execute_stage")[0]
    assert stage["status"] == "pending"
    assert stage["scheduled_for"] == world.clock.current + timedelta(minutes=30)
    await world.advance_to(stage["scheduled_for"] + timedelta(minutes=6))
    assert world.actions(person, kind="execute_stage")[0]["status"] == "executed"
    assert len(world.mail.to(address(person, "Mom"), "contact_alert")) == 1
    assert "hold evaluation failing" not in (await admin.engine_status(world.engine.services)).pages


async def test_f02_a_queued_alert_is_not_sent_while_hold_cannot_be_evaluated(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1)  # the stage ran; the alert waits out the settle delay
    assert world.notifications(person, template_key="contact_alert")[0]["status"] == "queued"

    async def broken(self: HoldMonitor, now: Any) -> Any:
        msg = "statement timeout"
        raise RuntimeError(msg)

    monkeypatch.setattr(HoldMonitor, "evaluate", broken)
    world.clock.set(STAGE_1 + timedelta(minutes=10))
    report = await world.tick()
    assert report.hold_unknown is True
    assert world.mail.to(address(person, "Mom"), "contact_alert") == []
    # "Mom has been notified" is only true together with the alert: it waits with it
    assert world.mail.to(person.email, "stage_executed") == []
    assert world.notifications(person, template_key="contact_alert")[0]["status"] == "queued"


# --- F-04: a notification the engine did not write is not trusted -----------------------------


async def test_f04_a_forged_alert_for_a_contact_outside_the_stage_is_cancelled(
    world: World,
) -> None:
    person = await world.ready(contacts=("Mom", "Dad"), stages=((180, ("Mom",)), (1440, ("Dad",))))
    await world.advance_to(STAGE_1)
    forged = forge(world, person, contact_id=person.contacts["Dad"])  # Dad is stage 2's
    await world.dispatch()
    row = status_of(world, forged)
    assert row["status"] == "cancelled"
    assert row["cancelled_reason"] == "contact_not_in_stage"
    assert world.mail.to(address(person, "Dad"), "contact_alert") == []


async def test_f04_a_row_that_does_not_carry_the_engines_key_is_cancelled(world: World) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1)
    forged = forge(world, person, dedupe_key=f"forged:{uuid.uuid4()}")
    await world.dispatch()
    row = status_of(world, forged)
    assert (row["status"], row["cancelled_reason"]) == ("cancelled", "dedupe_key_mismatch")


async def test_f04_a_forged_alert_cannot_beat_the_settle_delay(world: World) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1)
    forged = forge(world, person)  # Mom, in stage 1, send_after = now: no settle delay
    await world.dispatch()
    assert status_of(world, forged)["status"] == "queued"
    assert world.mail.to(address(person, "Mom"), "contact_alert") == []


async def test_f04_a_row_with_a_template_the_engine_never_writes_is_cancelled(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1)
    forged = forge(world, person, template_key="contact_all_clear")
    await world.dispatch()
    row = status_of(world, forged)
    assert (row["status"], row["cancelled_reason"]) == ("cancelled", "unexpected_template")


# --- F-07: a Hold must not starve the messages that continue ----------------------------------


async def test_f07_queued_alerts_do_not_fill_the_batch_while_hold_is_open(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1)
    world.clock.set(STAGE_1 + timedelta(minutes=10))
    await admin.hold_enter(world.engine.services, operator="alex", reason="investigating")
    world.db.execute(
        "INSERT INTO notifications (user_id, audience, category, channel, template_key, "
        "status, send_after, dedupe_key) VALUES (%s, 'user', 'user', 'email', "
        "'service_interruption', 'queued', %s, %s)",
        (person.user_id, world.clock.current, f"test-notice:{uuid.uuid4()}"),
    )
    monkeypatch.setattr(dispatcher_module, "BATCH", 1)
    await world.dispatch()
    assert len(world.mail.to(person.email, "service_interruption")) == 1
    assert world.mail.to(address(person, "Mom"), "contact_alert") == []


# --- F-08: "Mom has been notified" is never sent when nobody was --------------------------------


async def test_f08_the_summary_is_cancelled_when_the_incident_closes_inside_the_settle_delay(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1)
    incident = world.open_incident(person)
    assert incident is not None
    world.clock.set(STAGE_1 + timedelta(minutes=1))
    await world.safe(person, str(incident["id"]))  # I'M SAFE inside the settle delay
    await world.advance_to(STAGE_1 + timedelta(minutes=20))
    assert world.mail.to(person.email, "stage_executed") == []
    assert world.mail.to(address(person, "Mom"), "contact_alert") == []
    assert world.mail.to(address(person, "Mom"), "contact_all_clear") == []  # nobody was told
    summary = world.notifications(person, template_key="stage_executed")
    assert {n["status"] for n in summary} == {"cancelled"}
    assert {n["cancelled_reason"] for n in summary} == {"incident_closed_before_contact"}


# --- F-09: a contact who may have received the alert is owed the all-clear --------------------


async def test_f09_an_attempt_with_an_unclear_outcome_still_gets_an_all_clear(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1)
    world.db.execute(
        "UPDATE notifications SET status = 'sent' WHERE template_key = 'stage_executed'"
    )
    incident = world.open_incident(person)
    assert incident is not None
    world.mail.fail_next = True  # the provider call errors: it may or may not have gone out
    world.clock.set(STAGE_1 + timedelta(minutes=6))
    await world.dispatch()
    alert = world.notifications(person, template_key="contact_alert")[0]
    assert (alert["status"], alert["attempt_count"]) == ("queued", 1)

    await world.safe(person, str(incident["id"]))
    await world.tick()
    assert len(world.mail.to(address(person, "Mom"), "contact_all_clear")) == 1
    assert world.mail.to(address(person, "Mom"), "contact_alert") == []  # and no late alert


# --- F-10 (and Hold vs the summary): what was still in the settle delay is taken back ---------


async def test_f10_a_stage_still_in_its_settle_delay_when_a_hold_begins_is_rolled_back(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1)  # ran; the alert leaves at +5 minutes
    world.clock.set(STAGE_1 + timedelta(minutes=2))
    await admin.hold_enter(world.engine.services, operator="alex", reason="investigating")
    await world.advance_to(STAGE_1 + timedelta(minutes=62))
    assert world.mail.to(address(person, "Mom"), "contact_alert") == []
    assert world.mail.to(person.email, "stage_executed") == []  # waits with the alert

    assert await admin.hold_exit(world.engine.services, operator="alex") == 1
    await world.tick()
    original = world.notifications(person, template_key="contact_alert")[0]
    assert (original["status"], original["cancelled_reason"]) == ("cancelled", "hold_rollback")
    assert world.mail.to(address(person, "Mom"), "contact_alert") == []
    assert world.mail.to(person.email, "stage_executed") == []
    stage = world.actions(person, kind="execute_stage")[0]
    assert stage["status"] == "pending"
    assert stage["scheduled_for"] == STAGE_1 + timedelta(minutes=90)  # 60 min window + 30

    await world.advance_to(STAGE_1 + timedelta(minutes=100))
    assert len(world.mail.to(address(person, "Mom"), "contact_alert")) == 1


# --- F-11: giving up is visible, and counted from the first attempt ---------------------------


async def test_f11_a_message_given_up_on_pages_an_operator(world: World) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1)
    world.db.execute(
        "UPDATE notifications SET status = 'failed' WHERE template_key = 'contact_alert' "
        "AND user_id = %s",
        (person.user_id,),
    )
    status = await admin.engine_status(world.engine.services)
    assert status.failed_messages_7d == 1
    assert "messages given up on" in status.pages


async def test_f11_a_message_that_waited_long_is_not_given_up_on_its_first_error(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1)
    world.db.execute(
        "UPDATE notifications SET status = 'sent' WHERE template_key = 'stage_executed'"
    )
    world.db.execute(
        "UPDATE notifications SET created_at = created_at - interval '30 hours' "
        "WHERE template_key = 'contact_alert'"
    )
    world.mail.fail_next = True
    world.clock.set(STAGE_1 + timedelta(minutes=6))
    await world.dispatch()
    alert = world.notifications(person, template_key="contact_alert")[0]
    assert (alert["status"], alert["attempt_count"]) == ("queued", 1)  # retried, not failed


# --- F-13: infrastructure errors do not permanently hold an action; an operator can retry -----


def _boom(error: Exception) -> Any:
    async def raiser(session: Any, incident_id: Any) -> int:
        raise error

    return staticmethod(raiser)


async def test_f13_infrastructure_errors_never_hold_an_action(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))
    monkeypatch.setattr(
        EngineStore,
        "pending_stage_count",
        _boom(OperationalError("SELECT 1", {}, ConnectionError("connection lost"))),
    )
    world.clock.set(STAGE_1)
    for _ in range(world.engine.settings.action_max_attempts + 3):
        report = await world.engine.tick()
        assert report.errors >= 1
    stage = world.actions(person, kind="execute_stage")[0]
    assert (stage["status"], stage["attempt_count"]) == ("pending", 0)

    monkeypatch.undo()
    await world.engine.tick()
    assert world.actions(person, kind="execute_stage")[0]["status"] == "executed"


async def test_f13_a_held_action_can_be_put_back_by_an_operator(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))
    monkeypatch.setattr(EngineStore, "pending_stage_count", _boom(RuntimeError("a bug")))
    world.clock.set(STAGE_1)
    for _ in range(world.engine.settings.action_max_attempts):
        await world.engine.tick()
    stage = world.actions(person, kind="execute_stage")[0]
    assert stage["status"] == "held"
    assert "held actions" in (await admin.engine_status(world.engine.services)).pages

    monkeypatch.undo()
    services = world.engine.services
    assert await admin.retry_action(services, operator="alex", action_id=stage["id"]) == "retried"
    assert await admin.retry_action(services, operator="alex", action_id=stage["id"]) == "not_held"
    await world.engine.tick()
    assert world.actions(person, kind="execute_stage")[0]["status"] == "executed"
    audit = world.db.execute(
        "SELECT actor_type FROM audit_logs WHERE action = 'operator.retry_action'"
    ).fetchall()
    assert [a["actor_type"] for a in audit] == ["operator"]


# --- F-14: rows that cannot be opened do not starve the users behind them ---------------------


async def test_f14_every_due_user_is_reached_in_one_tick_whatever_the_batch_size(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    people = [await world.ready(f"batch{i}@example.com") for i in range(3)]
    monkeypatch.setattr(runtime_module, "BATCH", 1)
    world.clock.set(DUE + timedelta(seconds=1))
    report = await world.engine.tick()
    assert report.opened == 3
    assert report.backlog is False
    assert all(world.open_incident(p) is not None for p in people)


async def test_f14_a_backlog_is_reported_so_the_worker_does_not_sleep(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    for i in range(3):
        await world.ready(f"backlog{i}@example.com")
    monkeypatch.setattr(runtime_module, "BATCH", 1)
    monkeypatch.setattr(runtime_module, "MAX_PAGES", 2)
    world.clock.set(DUE + timedelta(seconds=1))
    report = await world.engine.tick()
    assert report.opened == 2
    assert report.backlog is True
    report = await world.engine.tick()  # the rest is taken on the next pass
    assert report.opened == 1


# --- F-17: G8 is evaluated at execution ------------------------------------------------------


async def _instruct(world: World, person: Person, recipient: str = "Sam") -> str:
    """A real instruction, released to ``recipient`` at stage 2 (made before the deadline, so it
    is in the incident's snapshot)."""
    await world.login(person)
    assert (
        await world.h.reauth(person.tokens)
    ).status_code == 204  # a route, while check-ins are on
    plan = await world.h.client.get("/v1/plan", headers=person.headers)
    made = await world.h.client.post(
        "/v1/instructions",
        json={
            "category": "home",
            "title": "House emergency",
            "body": "The spare key is with a neighbour.",
            "recipients": [
                {
                    "contact_id": person.contacts[recipient],
                    "release_stage_id": plan.json()["stages"][1]["id"],
                }
            ],
        },
        headers=person.headers,
    )
    assert made.status_code == 201, made.text
    return str(made.json()["id"])


async def _releasing(world: World) -> tuple[Person, str]:
    person = await world.ready(
        contacts=("Mom", "Dad", "Sam"), stages=((180, ("Mom",)), (1440, ("Dad",)))
    )
    return person, await _instruct(world, person)


async def test_f17_a_valid_release_adds_its_contact_to_the_stage(world: World) -> None:
    person, _ = await _releasing(world)
    await world.advance_to(STAGE_2 + timedelta(minutes=10))
    assert len(world.mail.to(address(person, "Dad"), "contact_alert")) == 1
    # Sam is told only because an instruction is released to them, so it is the alert that
    # carries the release
    assert len(world.mail.to(address(person, "Sam"), "contact_alert_with_release")) == 1
    outcome = world.actions(person, kind="execute_stage")[1]["outcome"]
    assert [r["result"] for r in outcome["releases"]] == ["valid"]
    sam = next(t for t in outcome["targets"] if t["contact_id"] == person.contacts["Sam"])
    assert sam.get("releases") == 1


async def test_f17_a_release_that_failed_g8_is_skipped_and_its_contact_is_not_told(
    world: World,
) -> None:
    person, instruction_id = await _releasing(world)
    await world.advance_to(DUE + timedelta(minutes=10))  # the incident (and its snapshot) exist
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204  # switching a route off
    switched = await world.h.client.patch(
        f"/v1/instructions/{instruction_id}", json={"status": "inactive"}, headers=person.headers
    )
    assert switched.status_code == 200
    await world.advance_to(STAGE_2 + timedelta(minutes=10))
    assert len(world.mail.to(address(person, "Dad"), "contact_alert")) == 1  # notified anyway
    assert world.mail.to(address(person, "Sam"), "contact_alert") == []  # release only: narrowed
    assert world.mail.to(address(person, "Sam"), "contact_alert_with_release") == []
    outcome = world.actions(person, kind="execute_stage")[1]["outcome"]
    assert outcome["releases"][0]["result"] == "skipped"
    assert outcome["releases"][0]["reason"] == "instruction_inactive"
    assert world.db.execute("SELECT count(*) AS n FROM release_events").fetchone()["n"] == 0  # type: ignore[index]


# --- Hold: re-entry after an operator exit, and two workers ------------------------------------


@pytest.mark.settings(anomaly_floor_per_hour=3)
async def test_f05_an_operator_exit_does_not_walk_straight_back_into_the_same_burst(
    world: World,
) -> None:
    for i in range(5):
        await world.ready(f"burst{i}@example.com")
    await world.advance_to(DUE + timedelta(seconds=5))
    await world.tick()
    anomalies = world.db.execute("SELECT * FROM system_holds WHERE reason = 'anomaly'").fetchall()
    assert len(anomalies) == 1

    world.clock.set(DUE + timedelta(minutes=10))  # well inside the hour of the burst
    assert await admin.hold_exit(world.engine.services, operator="alex") == 1
    for _ in range(4):
        await world.advance(minutes=2)
    anomalies = world.db.execute("SELECT * FROM system_holds WHERE reason = 'anomaly'").fetchall()
    assert len(anomalies) == 1  # not re-entered over incidents the first Hold already covered


@pytest.mark.settings(anomaly_floor_per_hour=3)
async def test_f06_two_workers_deciding_at_once_enter_one_hold(world: World) -> None:
    for i in range(5):
        await world.ready(f"twin{i}@example.com")
    world.clock.set(DUE + timedelta(seconds=1))
    await world.engine.tick()  # opens the five incidents
    now = world.clock.current
    other = HoldMonitor(world.engine.services)
    await asyncio.gather(world.engine.hold.evaluate(now), other.evaluate(now))
    anomalies = world.db.execute("SELECT * FROM system_holds WHERE reason = 'anomaly'").fetchall()
    assert len(anomalies) == 1


async def test_entering_an_operator_hold_twice_is_one_hold(world: World) -> None:
    await world.ready()
    services = world.engine.services
    first = await admin.hold_enter(services, operator="alex", reason="one")
    second = await admin.hold_enter(services, operator="sam", reason="two")
    assert first == second
    rows = world.db.execute("SELECT * FROM system_holds WHERE reason = 'operator'").fetchall()
    assert len(rows) == 1


# --- F-04, at the database: the API role cannot write what only the engine may ----------------


def _api() -> psycopg.Connection[dict[str, Any]]:
    return psycopg.connect(
        conninfo("afterme_api", API_PASSWORD), autocommit=True, row_factory=dict_row
    )


async def test_f04_the_api_role_cannot_resurrect_a_closed_incident(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))
    await world.checkin(person)  # I'M OK: the incident is resolved
    assert world.open_incident(person) is None
    with _api() as api, pytest.raises(psycopg.errors.InsufficientPrivilege):
        api.execute(
            "UPDATE escalation_incidents SET status = 'grace', closed_at = NULL, "
            "closed_by = NULL WHERE user_id = %s",
            (person.user_id,),
        )
    assert world.open_incident(person) is None


async def test_f04_the_api_role_cannot_forge_requeue_or_run_anything(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))
    incident = world.open_incident(person)
    assert incident is not None
    action = world.actions(person, kind="execute_stage")[0]
    with _api() as api:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):  # an action never "executed"
            api.execute(
                "UPDATE incident_actions SET status = 'executed' WHERE id = %s", (action["id"],)
            )
        with pytest.raises(psycopg.errors.InsufficientPrivilege):  # a forged alert
            api.execute(
                "INSERT INTO notifications (user_id, audience, category, contact_id, channel, "
                "template_key, incident_id, action_id, status, send_after, dedupe_key) "
                "VALUES (%s, 'contact', 'contact_escalation', %s, 'email', 'contact_alert', "
                "%s, %s, 'queued', now(), 'api-forged')",
                (person.user_id, person.contacts["Mom"], incident["id"], action["id"]),
            )
        # ... but it still may do its own job: cancel a pending action, enqueue a plain message
        api.execute(
            "INSERT INTO notifications (user_id, audience, category, channel, template_key, "
            "status, send_after, dedupe_key) VALUES (%s, 'user', 'user', 'email', "
            "'service_interruption', 'queued', now(), 'api-own-message')",
            (person.user_id,),
        )
        api.execute(
            "UPDATE incident_actions SET status = 'cancelled' WHERE id = %s", (action["id"],)
        )
    assert world.actions(person, kind="execute_stage")[0]["status"] == "cancelled"


async def test_f04_the_api_role_cannot_requeue_a_sent_message_but_can_cancel_a_queued_one(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1)  # the alert and the summary are queued
    world.db.execute(
        "UPDATE notifications SET status = 'sent' WHERE template_key = 'stage_executed'"
    )
    with _api() as api:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            api.execute(
                "UPDATE notifications SET status = 'queued' WHERE user_id = %s "
                "AND template_key = 'stage_executed'",
                (person.user_id,),
            )
        api.execute(
            "UPDATE notifications SET status = 'cancelled', cancelled_reason = 'test' "
            "WHERE user_id = %s AND template_key = 'contact_alert'",
            (person.user_id,),
        )
    assert world.notifications(person, template_key="contact_alert")[0]["status"] == "cancelled"


async def test_f04_the_worker_reads_the_plan_but_cannot_change_it(world: World) -> None:
    await world.ready()
    row = world.db.execute(
        "SELECT has_table_privilege('afterme_worker', 'escalation_plans', 'SELECT') AS read, "
        "has_table_privilege('afterme_worker', 'escalation_plans', 'UPDATE') AS write, "
        "has_table_privilege('afterme_worker', 'notifications', 'DELETE') AS purge"
    ).fetchone()
    assert row == {"read": True, "write": False, "purge": False}
