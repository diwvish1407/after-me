"""Failure scenarios (ESCALATION_ENGINE §11; TEST_PLAN ENG-FS-*). The engine must fail safe:
a crash, an outage or a bad provider delays an alert; it never causes a wrongful one."""

from __future__ import annotations

from datetime import timedelta
from typing import Any

import pytest

from app.engine.dispatcher import Dispatcher
from app.engine.store import EngineStore
from tests.world import World, ist

DUE = ist("2026-10-09T20:00")
STAGE_1 = DUE + timedelta(minutes=180)


def mom(person: Any) -> str:
    return f"mom.{person.user_id[:6]}@example.com"


async def test_fs05_a_crash_inside_the_unit_rolls_back_and_the_retry_applies_one_effect(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The worker dies after the stage's messages were written but before COMMIT."""
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))
    real = EngineStore.pending_stage_count
    crashed = {"n": 0}

    async def crash_once(session: Any, incident_id: Any) -> int:
        if crashed["n"] == 0:
            crashed["n"] += 1
            msg = "simulated crash after the effects were written"
            raise RuntimeError(msg)
        return await real(session, incident_id)

    monkeypatch.setattr(EngineStore, "pending_stage_count", staticmethod(crash_once))
    world.clock.set(STAGE_1)
    report = await world.engine.tick()
    assert report.errors == 1
    # nothing survived the rollback
    assert world.notifications(person, template_key="contact_alert") == []
    assert world.notifications(person, template_key="stage_executed") == []
    assert world.actions(person, kind="execute_stage")[0]["status"] == "pending"
    assert world.open_incident(person)["status"] == "grace"  # type: ignore[index]

    await world.engine.tick()
    assert len(world.notifications(person, template_key="contact_alert")) == 1
    assert len(world.notifications(person, template_key="stage_executed")) == 1
    assert world.actions(person, kind="execute_stage")[0]["status"] == "executed"


async def test_fs06_the_outbox_survives_a_worker_that_died_before_dispatch(
    world: World,
) -> None:
    person = await world.ready()
    world.clock.set(DUE)
    await world.engine.tick()  # open the incident: no dispatcher running
    world.clock.set(STAGE_1)
    await world.engine.tick()  # stage executes: messages are only queued
    assert world.notifications(person, template_key="contact_alert")[0]["status"] == "queued"
    assert world.mail.to(mom(person), "contact_alert") == []
    # a fresh dispatcher process (the old one is gone) picks the queue up, after the delay
    world.clock.set(STAGE_1 + timedelta(minutes=6))
    await world.dispatch()
    assert len(world.mail.to(mom(person), "contact_alert")) == 1


async def test_fs07_a_dispatcher_that_dies_after_the_provider_accepted_resends_with_the_same_key(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    """At-least-once at the provider boundary, and never a *different* message: the same
    idempotency key lets the provider suppress the duplicate."""
    person = await world.ready()
    await world.advance_to(STAGE_1)
    real = Dispatcher._settle
    dead = {"n": 0}

    async def die_once(self: Dispatcher, out: Any, *args: Any, **kwargs: Any) -> None:
        # the batch also holds the user's stage summary; only the contact alert's tx B dies
        if out.template_key == "contact_alert" and dead["n"] == 0:
            dead["n"] += 1
            msg = "simulated crash between the provider call and tx B"
            raise RuntimeError(msg)
        await real(self, out, *args, **kwargs)

    monkeypatch.setattr(Dispatcher, "_settle", die_once)
    world.clock.set(STAGE_1 + timedelta(minutes=6))
    await world.dispatch()
    assert len(world.mail.to(mom(person), "contact_alert")) == 1  # the provider did accept it
    stuck = world.notifications(person, template_key="contact_alert")[0]
    assert stuck["status"] == "sending"

    world.clock.set(STAGE_1 + timedelta(minutes=13))  # past the recovery interval
    await world.dispatch()
    sent = world.mail.to(mom(person), "contact_alert")
    assert len(sent) == 2
    keys = [
        k
        for m, k in zip(world.mail.messages, world.mail.keys, strict=True)
        if m.template == "contact_alert"
    ]
    assert keys[0] == keys[1] == str(stuck["id"])
    assert world.notifications(person, template_key="contact_alert")[0]["status"] == "sent"


async def test_fs08_workers_down_for_hours_still_give_the_full_grace(world: World) -> None:
    person = await world.ready()
    world.clock.set(DUE + timedelta(hours=6))  # six hours with no worker at all
    await world.tick()
    incident = world.open_incident(person)
    assert incident is not None
    assert incident["grace_ends_at"] == world.clock.current + timedelta(minutes=180)
    assert world.mail.to(mom(person), "contact_alert") == []
    await world.advance_to(world.clock.current + timedelta(minutes=179))
    assert world.mail.to(mom(person), "contact_alert") == []  # still inside the full grace


async def test_fs11_push_down_the_user_is_still_reached_by_email(world: World) -> None:
    person = await world.ready()
    world.db.execute(
        "UPDATE devices SET push_token = 'fcm-token-for-the-test' WHERE id = "
        "(SELECT id FROM devices WHERE user_id = %s ORDER BY created_at, id LIMIT 1)",
        (person.user_id,),
    )
    world.push.fail_next = 100  # FCM is down
    await world.advance_to(DUE + timedelta(minutes=170))
    assert len(world.mail.to(person.email, "incident_missed")) == 1
    assert len(world.mail.to(person.email, "incident_last_chance")) == 1
    assert world.push.messages == []
    # escalation timing is unaffected
    assert world.open_incident(person)["status"] == "grace"  # type: ignore[index]
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    assert len(world.mail.to(mom(person), "contact_alert")) == 1


async def test_fs12_email_provider_down_delays_contact_alerts_and_pages(world: World) -> None:
    from app.ops import admin

    person = await world.ready()
    await world.advance_to(STAGE_1)
    world.db.execute(
        "UPDATE notifications SET status = 'sent' WHERE template_key = 'stage_executed'"
    )
    world.mail.fail_next = True
    await world.advance_to(STAGE_1 + timedelta(minutes=5))  # the send, which fails
    alert = world.notifications(person, template_key="contact_alert")[0]
    assert alert["status"] == "queued"  # delayed, not lost
    assert alert["next_attempt_at"] == STAGE_1 + timedelta(minutes=6)
    world.clock.set(STAGE_1 + timedelta(minutes=15))
    status = await admin.engine_status(world.engine.services)
    assert "queued message past send_after for 5 minutes" in status.pages


async def test_fs21_a_stage_the_snapshot_does_not_list_is_skipped_and_recorded(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))
    world.db.execute(
        "UPDATE escalation_incidents "
        "SET plan_snapshot = jsonb_set(plan_snapshot, '{stages}', '[]') WHERE user_id = %s",
        (person.user_id,),
    )
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    stage = world.actions(person, kind="execute_stage")[0]
    assert stage["status"] == "executed"
    assert stage["outcome"] == {"targets": [], "reason": "stage_not_in_snapshot"}
    assert world.notifications(person, template_key="contact_alert") == []


async def test_fs26_a_subscription_that_lapses_changes_nothing_mid_incident(world: World) -> None:
    person = await world.ready(
        contacts=("Mom", "Dad", "Sam"),
        stages=((180, ("Mom",)), (1440, ("Dad",)), (2880, ("Sam",))),
    )
    await world.advance_to(DUE + timedelta(minutes=10))
    world.db.execute("UPDATE users SET tier = 'free' WHERE id = %s", (person.user_id,))
    await world.advance_to(DUE + timedelta(minutes=2900))
    for label in ("Mom", "Dad", "Sam"):
        assert (
            len(world.mail.to(f"{label.lower()}.{person.user_id[:6]}@example.com", "contact_alert"))
            == 1
        )


async def test_a_deadline_never_opens_an_incident_twice(world: World) -> None:
    """The unique ``(user_id, missed_due_at)`` and the one-open-incident index are the last
    line: even a second engine that did not see the first one's commit cannot add another."""
    person = await world.ready()
    world.clock.set(DUE + timedelta(seconds=1))
    await world.engine.tick()
    config = world.config(person)
    assert config["status"] == "incident_open"
    # force the schedule back to "active, overdue" as a lost update could
    world.db.execute(
        "UPDATE checkin_configurations SET status = 'active' WHERE user_id = %s", (person.user_id,)
    )
    report = await world.engine.tick()
    assert len(world.incidents(person)) == 1
    assert report.errors == 1  # refused by the database, logged, nothing opened
    assert report.opened == 0
