"""Opening incidents and executing their timeline (ESCALATION_ENGINE §4-§6, §14)."""

from __future__ import annotations

from datetime import timedelta
from typing import Any

import pytest

from app.engine.executor import ActionExecutor
from tests.world import World, ist

DUE = ist("2026-10-09T20:00")  # the default deadline of a user activated at T0 (daily, 20:00 IST)


def _by_kind(actions: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {f"{a['kind']}:{a['variant'] or ''}": a for a in actions}


# --- opening ----------------------------------------------------------------------------------


async def test_nothing_happens_before_the_deadline(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE - timedelta(minutes=1))
    assert world.incidents(person) == []
    assert world.config(person)["status"] == "active"


async def test_a_missed_deadline_opens_one_incident_with_its_whole_timeline(
    world: World,
) -> None:
    person = await world.ready(stages=((180, ("Mom",)), (1440, ("Mom",))))
    await world.advance_to(DUE + timedelta(seconds=20))

    incident = world.open_incident(person)
    assert incident is not None
    assert incident["status"] == "grace"
    assert incident["missed_due_at"] == DUE
    assert incident["anchor_at"] == DUE
    assert incident["grace_ends_at"] == DUE + timedelta(minutes=180)
    assert incident["contacts_messaged_at"] is None
    assert world.config(person)["status"] == "incident_open"

    actions = world.actions(person)
    kinds = sorted(a["kind"] for a in actions)
    assert kinds == [
        "execute_stage",
        "execute_stage",
        "user_reminder",
        "user_reminder",
        "user_reminder",
    ]
    stages = [a for a in actions if a["kind"] == "execute_stage"]
    assert [a["scheduled_for"] for a in stages] == [
        DUE + timedelta(minutes=180),
        DUE + timedelta(minutes=1440),
    ]
    reminders = _by_kind(actions)
    assert reminders["user_reminder:missed"]["scheduled_for"] == DUE
    assert reminders["user_reminder:midpoint"]["scheduled_for"] == DUE + timedelta(minutes=90)
    assert reminders["user_reminder:last_chance"]["scheduled_for"] == DUE + timedelta(minutes=165)
    # the first reminder was due immediately and already ran
    assert reminders["user_reminder:missed"]["status"] == "executed"
    audit = world.db.execute(
        "SELECT * FROM audit_logs WHERE action = 'incident.opened' AND subject_user_id = %s",
        (person.user_id,),
    ).fetchall()
    assert len(audit) == 1
    assert audit[0]["user_visible"] is True
    assert audit[0]["actor_type"] == "system"


async def test_the_snapshot_holds_identifiers_only(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(seconds=20))
    snapshot = world.open_incident(person)["plan_snapshot"]  # type: ignore[index]
    assert snapshot["schema"] == 1
    assert snapshot["grace_minutes"] == 180
    stage = snapshot["stages"][0]
    assert stage["notify_contact_ids"] == [person.contacts["Mom"]]
    assert stage["releases"] == []
    text = str(snapshot).lower()
    for forbidden in ("mom.", "@", "display", "name"):
        assert forbidden not in text


async def test_ticking_again_changes_nothing(world: World) -> None:
    """INV-5: running the engine twice on the same state produces no new rows."""
    person = await world.ready()
    await world.advance_to(DUE + timedelta(seconds=20))

    def snapshot() -> dict[str, Any]:
        return {
            "incidents": world.incidents(person),
            "actions": world.actions(person),
            "notifications": world.notifications(person),
            "config": world.config(person),
        }

    before = snapshot()
    for _ in range(5):
        await world.tick()
    assert snapshot() == before


async def test_a_late_opening_still_gives_the_full_grace_period(world: World) -> None:
    """INV-8 / FS-08: the workers were down for six hours; the clock for the user starts when
    the incident actually exists."""
    person = await world.ready()
    late = DUE + timedelta(hours=6)
    world.clock.set(late)
    await world.tick()

    incident = world.open_incident(person)
    assert incident is not None
    assert incident["missed_due_at"] == DUE
    assert incident["opened_at"] == late
    assert incident["anchor_at"] == late
    assert incident["grace_ends_at"] == late + timedelta(minutes=180)
    stage = world.actions(person, kind="execute_stage")[0]
    assert stage["scheduled_for"] == late + timedelta(minutes=180)
    assert stage["status"] == "pending"


async def test_hold_stops_incidents_from_opening_and_they_open_after_it(world: World) -> None:
    """INV-10: deadlines simply wait while the system is in Hold."""
    person = await world.ready()
    world.db.execute(
        "INSERT INTO system_holds (reason, started_at, detected_at, created_by) "
        "VALUES ('operator', %s, %s, 'test')",
        (DUE - timedelta(minutes=5), DUE),
    )
    await world.advance_to(DUE + timedelta(hours=1))
    assert world.incidents(person) == []
    assert world.config(person)["status"] == "active"

    world.db.execute("UPDATE system_holds SET ended_at = %s", (world.clock.current,))
    await world.tick()
    incident = world.open_incident(person)
    assert incident is not None
    assert incident["opened_at"] == world.clock.current  # full grace from now


async def test_an_unabsorbed_checkin_is_never_escalated_over(world: World) -> None:
    """FS-25: a check-in the schedule did not absorb means the data is inconsistent."""
    person = await world.ready()
    world.db.execute(
        "INSERT INTO checkin_events (user_id, kind, source, received_at, idempotency_key, "
        "response_snapshot) VALUES (%s, 'ok', 'app', %s, 'bypassed-the-service-1', '{}')",
        (person.user_id, DUE - timedelta(minutes=1)),
    )
    await world.advance_to(DUE + timedelta(minutes=30))
    assert world.incidents(person) == []
    assert world.config(person)["status"] == "active"
    violations = world.db.execute(
        "SELECT * FROM audit_logs WHERE action = 'system.consistency_violation' "
        "AND subject_user_id = %s",
        (person.user_id,),
    ).fetchall()
    assert len(violations) == 1  # written once, however many ticks saw it
    assert violations[0]["metadata"] == {"reason": "unabsorbed_checkin"}


@pytest.mark.parametrize("status", ["pending_deletion", "suspended"])
async def test_an_account_that_is_not_active_is_not_escalated(world: World, status: str) -> None:
    person = await world.ready()
    world.db.execute("UPDATE users SET status = %s WHERE id = %s", (status, person.user_id))
    await world.advance_to(DUE + timedelta(hours=1))
    assert world.incidents(person) == []


async def test_one_users_deadline_does_not_affect_another(world: World) -> None:
    alice = await world.ready("alice@example.com")
    bob = await world.ready("bob@example.com")
    # Bob checks in at 19:30; Alice does not.
    world.clock.set(DUE - timedelta(minutes=30))
    await world.checkin(bob)
    await world.advance_to(DUE + timedelta(minutes=5))
    assert world.open_incident(alice) is not None
    assert world.open_incident(bob) is None
    assert world.config(bob)["status"] == "active"


# --- executing --------------------------------------------------------------------------------


async def test_stage_one_queues_the_contact_alert_behind_the_settle_delay(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=180, seconds=20))

    incident = world.open_incident(person)
    assert incident is not None
    assert incident["status"] == "escalated"  # the only stage has run
    alerts = world.notifications(person, template_key="contact_alert")
    assert len(alerts) == 1
    alert = alerts[0]
    assert alert["audience"] == "contact"
    assert alert["category"] == "contact_escalation"
    assert alert["contact_id"] is not None
    assert str(alert["contact_id"]) == person.contacts["Mom"]
    assert alert["channel"] == "email"
    assert alert["status"] == "queued"
    stage_action = world.actions(person, kind="execute_stage")[0]
    assert alert["action_id"] == stage_action["id"]
    assert alert["send_after"] == stage_action["executed_at"] + timedelta(seconds=300)
    assert incident["contacts_messaged_at"] is None  # only the dispatcher sets it (§4.2)
    outcome = stage_action["outcome"]
    assert outcome["targets"] == [{"contact_id": person.contacts["Mom"], "result": "messaged"}]
    summary = world.notifications(person, template_key="stage_executed")
    assert {n["channel"] for n in summary} == {"email"}  # no device has a push token here


async def test_status_moves_through_escalating_to_escalated(world: World) -> None:
    person = await world.ready(
        contacts=("Mom", "Dad"),
        stages=((180, ("Mom",)), (1440, ("Dad",))),
    )
    await world.advance_to(DUE + timedelta(minutes=181))
    assert world.open_incident(person)["status"] == "escalating"  # type: ignore[index]
    await world.advance_to(DUE + timedelta(minutes=1441))
    assert world.open_incident(person)["status"] == "escalated"  # type: ignore[index]
    assert len(world.notifications(person, template_key="contact_alert")) == 2


async def test_contacts_that_are_not_verified_are_skipped_with_a_reason(world: World) -> None:
    """INV-6: pending, declined, opted-out and bounced contacts are never messaged."""
    person = await world.person(premium=True)
    statuses = {
        "Pending": "pending",
        "Declined": "declined",
        "OptedOut": "opted_out",
        "Bounced": "bounced",
        "Verified": "verified",
    }
    for label in statuses:
        await world.contact(person, label, verified=False)
    for label, status in statuses.items():
        world.db.execute(
            "UPDATE trusted_contacts SET verification_status = %s WHERE id = %s",
            (status, person.contacts[label]),
        )
    await world.plan(person, [(180, list(statuses))])
    await world.activate(person)
    await world.advance_to(DUE + timedelta(minutes=181))

    alerts = world.notifications(person, template_key="contact_alert")
    assert [str(a["contact_id"]) for a in alerts] == [person.contacts["Verified"]]
    outcome = {
        t["contact_id"]: t
        for t in world.actions(person, kind="execute_stage")[0]["outcome"]["targets"]
    }
    assert outcome[person.contacts["Pending"]]["reason"] == "not_verified_pending"
    assert outcome[person.contacts["Declined"]]["reason"] == "not_verified_declined"
    assert outcome[person.contacts["OptedOut"]]["reason"] == "not_verified_opted_out"
    assert outcome[person.contacts["Bounced"]]["reason"] == "not_verified_bounced"
    assert outcome[person.contacts["Verified"]]["result"] == "messaged"


async def test_a_contact_switched_off_or_deleted_after_opening_is_not_messaged(
    world: World,
) -> None:
    """INV-7: later changes can only narrow what happens."""
    person = await world.ready(contacts=("Mom", "Dad"), stages=((180, ("Mom", "Dad")),))
    await world.advance_to(DUE + timedelta(seconds=20))
    assert world.open_incident(person) is not None
    await world.login(person)  # taking people out of a live plan needs the password (F-12)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    away = await world.h.client.patch(
        f"/v1/contacts/{person.contacts['Mom']}", json={"is_active": False}, headers=person.headers
    )
    assert away.status_code == 200
    gone = await world.h.client.delete(
        f"/v1/contacts/{person.contacts['Dad']}", headers=person.headers
    )
    assert gone.status_code == 204
    await world.advance_to(DUE + timedelta(minutes=181))
    assert world.notifications(person, template_key="contact_alert") == []
    outcome = world.actions(person, kind="execute_stage")[0]["outcome"]
    assert {t["result"] for t in outcome["targets"]} == {"skipped"}
    assert {t["reason"] for t in outcome["targets"]} == {"inactive", "deleted"}


async def test_a_contact_added_after_opening_is_never_added(world: World) -> None:
    """INV-7: execution uses the snapshot intersected with live data, never a union."""
    person = await world.ready(contacts=("Mom",), stages=((180, ("Mom",)),))
    await world.advance_to(DUE + timedelta(seconds=20))
    newcomer = await world.contact(person, "Newcomer")
    world.db.execute(
        "INSERT INTO escalation_step_contacts (step_id, contact_id, user_id) "
        "SELECT id, %s, user_id FROM escalation_steps WHERE user_id = %s",
        (newcomer, person.user_id),
    )
    await world.advance_to(DUE + timedelta(minutes=181))
    alerts = world.notifications(person, template_key="contact_alert")
    assert [str(a["contact_id"]) for a in alerts] == [person.contacts["Mom"]]


async def test_a_suppressed_address_is_never_messaged(world: World) -> None:
    person = await world.ready()
    row = world.db.execute(
        "SELECT email_normalized FROM trusted_contacts WHERE id = %s", (person.contacts["Mom"],)
    ).fetchone()
    pepper = world.engine.services.pepper
    from app.contacts.tokens import suppression_hash_candidates

    [current, *_] = suppression_hash_candidates(pepper, row["email_normalized"])
    world.db.execute(
        "INSERT INTO email_suppressions (email_hash, reason) VALUES (%s, 'contact_block_all')",
        (current,),
    )
    await world.advance_to(DUE + timedelta(minutes=181))
    assert world.notifications(person, template_key="contact_alert") == []
    outcome = world.actions(person, kind="execute_stage")[0]["outcome"]
    assert outcome["targets"][0]["reason"] == "suppressed"


async def test_a_stage_with_nobody_left_runs_as_a_recorded_no_op(world: World) -> None:
    """ENG-LC-06: an empty stage is allowed and simply does nothing."""
    person = await world.ready()
    assert (await world.h.reauth(person.tokens)).status_code == 204  # F-12
    gone = await world.h.client.delete(
        f"/v1/contacts/{person.contacts['Mom']}", headers=person.headers
    )
    assert gone.status_code == 204
    await world.advance_to(DUE + timedelta(minutes=181))
    stage = world.actions(person, kind="execute_stage")[0]
    assert stage["status"] == "executed"
    assert stage["outcome"] == {"targets": []}
    assert world.notifications(person, template_key="contact_alert") == []
    assert world.open_incident(person)["status"] == "escalated"  # type: ignore[index]


async def test_reminders_stop_being_true_once_the_first_stage_has_run(world: World) -> None:
    """The workers were down: the midpoint reminder is only found after stage 1 ran. Saying
    "Mom will be notified at 11:00 PM" then would be false, so it is superseded."""
    person = await world.ready()
    await world.advance_to(DUE + timedelta(seconds=20))
    world.clock.set(DUE + timedelta(minutes=181))  # the worker comes back late
    await world.tick()
    actions = _by_kind(world.actions(person))
    assert actions["execute_stage:"]["status"] == "executed"
    assert actions["user_reminder:midpoint"]["status"] == "cancelled"
    assert actions["user_reminder:midpoint"]["outcome"] == {"reason": "superseded"}
    assert actions["user_reminder:last_chance"]["status"] == "cancelled"


# --- the gate holds back what is inconsistent -------------------------------------------------


async def test_a_checkin_that_slipped_past_the_api_holds_the_action_and_alerts(
    world: World,
) -> None:
    """G3: even if an incident is open, a check-in after the missed deadline stops everything."""
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))
    assert world.open_incident(person) is not None
    world.db.execute(
        "INSERT INTO checkin_events (user_id, kind, source, received_at, idempotency_key, "
        "response_snapshot) VALUES (%s, 'ok', 'app', %s, 'slipped-past-the-api-01', '{}')",
        (person.user_id, DUE + timedelta(minutes=5)),
    )
    await world.advance_to(DUE + timedelta(minutes=181))

    stage = world.actions(person, kind="execute_stage")[0]
    assert stage["status"] == "held"
    assert stage["outcome"] == {"held_by_gate": "G3"}
    assert world.notifications(person, template_key="contact_alert") == []
    held = world.db.execute(
        "SELECT * FROM audit_logs WHERE action = 'escalation.action_held'"
    ).fetchall()
    assert held
    assert held[0]["user_visible"] is False


async def test_a_snapshot_this_release_does_not_understand_is_held(world: World) -> None:
    """G6: fail safe on an unrecognised schema."""
    person = await world.ready()
    await world.advance_to(DUE + timedelta(seconds=20))
    world.db.execute(
        "UPDATE escalation_incidents "
        "SET plan_snapshot = jsonb_set(plan_snapshot, '{schema}', '99') WHERE user_id = %s",
        (person.user_id,),
    )
    await world.advance_to(DUE + timedelta(minutes=181))
    stage = world.actions(person, kind="execute_stage")[0]
    assert stage["status"] == "held"
    assert world.notifications(person, template_key="contact_alert") == []


async def test_an_action_that_keeps_failing_is_held_after_five_attempts(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    """FS-23: after ACTION_MAX_ATTEMPTS the action is held and never auto-executed again."""
    person = await world.ready()
    await world.advance_to(DUE + timedelta(seconds=20))

    async def broken(self: ActionExecutor, *args: Any, **kwargs: Any) -> None:
        raise RuntimeError("provider exploded with secrets in its message")

    monkeypatch.setattr(ActionExecutor, "_stage", broken)
    world.clock.set(DUE + timedelta(minutes=181))
    for attempt in range(1, 5):
        report = await world.tick()
        assert report.errors == 1
        stage = world.actions(person, kind="execute_stage")[0]
        assert (stage["status"], stage["attempt_count"]) == ("pending", attempt)
        assert stage["last_error_class"] == "RuntimeError"
    await world.tick()  # the fifth
    stage = world.actions(person, kind="execute_stage")[0]
    assert stage["status"] == "held"
    assert stage["attempt_count"] == 5
    # no partial effect survived the rollbacks
    assert world.notifications(person, template_key="contact_alert") == []
    assert world.open_incident(person)["status"] == "grace"  # type: ignore[index]

    monkeypatch.undo()
    for _ in range(3):
        await world.tick()
    assert world.actions(person, kind="execute_stage")[0]["status"] == "held"  # never retried
    assert world.notifications(person, template_key="contact_alert") == []
    audit = world.db.execute(
        "SELECT metadata FROM audit_logs WHERE action = 'escalation.action_held'"
    ).fetchall()
    assert audit[0]["metadata"]["error_class"] == "RuntimeError"
    assert "secrets" not in str(audit)


# --- pre-deadline reminder --------------------------------------------------------------------


async def test_the_pre_deadline_reminder_is_queued_once_per_deadline(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE - timedelta(minutes=59))
    reminders = world.notifications(person, template_key="checkin_pre_reminder")
    assert {n["channel"] for n in reminders} == {"email"}
    assert len(reminders) == 1
    assert reminders[0]["params"] == {"due_at": DUE.isoformat()}
    for _ in range(3):
        await world.tick()
    assert len(world.notifications(person, template_key="checkin_pre_reminder")) == 1


async def test_no_pre_reminder_after_the_person_checked_in(world: World) -> None:
    person = await world.ready()
    world.clock.set(DUE - timedelta(minutes=90))
    await world.checkin(person)
    await world.advance_to(DUE + timedelta(minutes=5))
    assert world.notifications(person, template_key="checkin_pre_reminder") == []
    assert world.incidents(person) == []
