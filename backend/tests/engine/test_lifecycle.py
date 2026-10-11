"""The incident lifecycle through the public API and engine ticks (ESCALATION_ENGINE §14;
TEST_PLAN ENG-LC-01...08). Time moves only when the test moves it."""

from __future__ import annotations

import os
from datetime import timedelta

import pytest

from app.incidents.closing import void_open_incident
from tests.support import problem
from tests.world import World, ist


async def _start_at(world: World, when: str) -> None:
    world.clock.set(ist(when))


def _address(person, label: str) -> str:
    return f"{label.lower()}.{person.user_id[:6]}@example.com"


# The phase exit criterion is 100 consecutive passes (``make engine-gate`` sets 100); a normal
# run repeats it a few times, which is enough to catch an order or leftover-state problem.
LIFECYCLE_REPEATS = int(os.environ.get("LIFECYCLE_REPEATS", "5"))


@pytest.mark.parametrize("run", range(LIFECYCLE_REPEATS))
async def test_the_full_lifecycle_t0_to_t8(world: World, run: int) -> None:
    """ENG-LC-01 (without releases, which arrive with instructions in Phase 6)."""
    await _start_at(world, "2026-10-13T19:00")
    person = await world.ready(
        contacts=("Mom", "Brother"),
        stages=((180, ("Mom",)), (1440, ("Brother",))),
    )
    mom, brother = _address(person, "Mom"), _address(person, "Brother")

    # T0: I'M OK on Day 1 at 19:30
    world.clock.set(ist("2026-10-13T19:30"))
    await world.checkin(person)
    assert world.config(person)["next_due_at"] == ist("2026-10-14T20:00")

    # Day 2, 19:00: the pre-deadline reminder
    await world.advance_to(ist("2026-10-14T19:00"))
    assert len(world.mail.to(person.email, "checkin_pre_reminder")) == 1

    # T1: Day 2 20:00 the deadline passes
    await world.advance_to(ist("2026-10-14T20:00:15"))
    incident = world.open_incident(person)
    assert incident is not None
    assert incident["status"] == "grace"
    assert incident["anchor_at"] == ist("2026-10-14T20:00")
    assert len(world.mail.to(person.email, "incident_missed")) == 1
    assert world.mail.to(mom, "contact_alert") == []
    assert world.mail.to(brother, "contact_alert") == []

    # T2: the last-chance reminder (the midpoint is push only)
    await world.advance_to(ist("2026-10-14T22:45:15"))
    assert len(world.mail.to(person.email, "incident_last_chance")) == 1

    # T3: grace ends, stage 1 runs; the message waits out the settle delay
    await world.advance_to(ist("2026-10-14T23:00:15"))
    assert world.open_incident(person)["status"] == "escalating"  # type: ignore[index]
    assert world.mail.to(mom, "contact_alert") == []

    # T4: five minutes later Mom is emailed and the contacts count as messaged
    await world.advance_to(ist("2026-10-14T23:05:30"))
    (alert,) = world.mail.to(mom, "contact_alert")
    assert "hasn't checked in" in alert.subject
    assert world.open_incident(person)["contacts_messaged_at"] is not None  # type: ignore[index]
    assert len(world.mail.to(person.email, "stage_executed")) == 1

    # T5: Day 3 20:00 stage 2 runs; Brother is emailed after the settle delay
    await world.advance_to(ist("2026-10-15T20:05:30"))
    assert len(world.mail.to(brother, "contact_alert")) == 1
    assert world.open_incident(person)["status"] == "escalated"  # type: ignore[index]

    # T6: the user returns at 21:00. Contacts were messaged, so I'M OK is refused.
    world.clock.set(ist("2026-10-15T21:00"))
    refused = await world.checkin(person, expect=409)
    error = problem(refused)
    assert error["code"] == "safe_required"
    incident_id = error["incident_id"]
    assert incident_id == str(world.open_incident(person)["id"])  # type: ignore[index]

    # T7: password, then I'M SAFE
    world.clock.set(ist("2026-10-15T21:01"))
    safe = await world.safe(person, incident_id)
    body = safe.json()
    assert body["status"] == "cancelled"
    assert {t["display_name"] for t in body["all_clear_sent_to"]} == {"Mom", "Brother"}
    assert body["next_due_at"] == "2026-10-16T14:30:00Z"  # Day 4 20:00 IST
    assert world.open_incident(person) is None
    assert world.config(person)["status"] == "active"
    await world.tick()
    assert len(world.mail.to(mom, "contact_all_clear")) == 1
    assert len(world.mail.to(brother, "contact_all_clear")) == 1
    assert len(world.mail.to(person.email, "all_clear_confirmation")) == 1

    # T8: a week of ticks. Nothing new is sent for that incident.
    before = [
        m for m in world.mail.messages if m.template in ("contact_alert", "contact_all_clear")
    ]
    await world.advance_to(ist("2026-10-16T19:00"))
    after = [m for m in world.mail.messages if m.template in ("contact_alert", "contact_all_clear")]
    assert after == before
    closed = world.incidents(person)[0]
    assert (closed["status"], closed["closed_by"]) == ("cancelled", "user_safe")
    # the schedule resumed: a *new* incident only because Day 4 20:00 was missed too
    await world.advance_to(ist("2026-10-16T20:00:15"))
    newest = world.incidents(person)[-1]
    assert newest["missed_due_at"] == ist("2026-10-16T20:00")
    assert newest["id"] != closed["id"]

    actions = [
        r["action"]
        for r in world.db.execute(
            "SELECT action FROM audit_logs WHERE subject_user_id = %s ORDER BY id",
            (person.user_id,),
        ).fetchall()
    ]
    for expected in (
        "incident.opened",
        "escalation.reminder_sent",
        "escalation.stage_executed",
        "notification.sent",
        "incident.cancelled",
    ):
        assert expected in actions, expected


async def test_a_checkin_during_grace_resolves_and_nobody_is_ever_contacted(world: World) -> None:
    """ENG-LC-02."""
    await _start_at(world, "2026-10-13T19:00")
    person = await world.ready()
    world.clock.set(ist("2026-10-13T19:30"))
    await world.checkin(person)
    await world.advance_to(ist("2026-10-14T20:00:15"))
    assert world.open_incident(person) is not None

    world.clock.set(ist("2026-10-14T22:00"))
    response = await world.checkin(person)
    assert response.json()["incident_resolved"] is True
    assert response.json()["next_due_at"] == "2026-10-15T14:30:00Z"

    incident = world.incidents(person)[0]
    assert (incident["status"], incident["closed_by"]) == ("resolved", "user_checkin")
    assert incident["contacts_messaged_at"] is None
    assert world.config(person)["status"] == "active"
    pending = [a for a in world.actions(person) if a["status"] == "pending"]
    assert pending == []
    assert [a["status"] for a in world.actions(person, kind="execute_stage")] == ["cancelled"]
    # zero contact notifications were ever created
    assert world.notifications(person, audience="contact") == []
    await world.advance_to(ist("2026-10-14T23:30"))
    assert world.mail.to(_address(person, "Mom"), "contact_alert") == []
    event = world.db.execute(
        "SELECT incident_id FROM checkin_events WHERE user_id = %s ORDER BY received_at DESC",
        (person.user_id,),
    ).fetchone()
    assert str(event["incident_id"]) == str(incident["id"])


async def test_a_checkin_inside_the_settle_delay_stops_the_message(world: World) -> None:
    """ENG-LC-03 / INV-2: stage 1 ran, but nobody could have seen anything yet."""
    await _start_at(world, "2026-10-13T19:00")
    person = await world.ready()
    await world.advance_to(ist("2026-10-14T23:00:15"))  # stage ran; message queued
    assert world.notifications(person, template_key="contact_alert")[0]["status"] == "queued"

    world.clock.set(ist("2026-10-14T23:02"))  # inside the five-minute settle delay
    response = await world.checkin(person)
    assert response.status_code == 200
    assert response.json()["incident_resolved"] is True

    alert = world.notifications(person, template_key="contact_alert")[0]
    assert (alert["status"], alert["cancelled_reason"]) == ("cancelled", "incident_resolved")
    await world.advance_to(ist("2026-10-14T23:30"))
    assert world.mail.to(_address(person, "Mom"), "contact_alert") == []
    assert world.incidents(person)[0]["contacts_messaged_at"] is None
    # nobody was told, so there is no all-clear either
    assert world.mail.to(_address(person, "Mom"), "contact_all_clear") == []


async def test_a_user_who_never_returns_escalates_through_every_stage(world: World) -> None:
    """ENG-LC-04."""
    await _start_at(world, "2026-10-13T19:00")
    person = await world.ready(
        contacts=("Mom", "Dad", "Sam"),
        stages=((180, ("Mom",)), (1440, ("Dad",)), (2880, ("Sam",))),
    )
    await world.advance_to(ist("2026-10-20T20:00"))
    incident = world.open_incident(person)
    assert incident is not None
    assert incident["status"] == "escalated"
    for label in ("Mom", "Dad", "Sam"):
        assert len(world.mail.to(_address(person, label), "contact_alert")) == 1
    assert len(world.incidents(person)) == 1  # the schedule is suspended: no second incident
    assert world.config(person)["status"] == "incident_open"
    assert len(world.mail.to(person.email, "checkin_pre_reminder")) == 1  # none during an incident


async def test_account_deletion_voids_the_incident_and_tells_those_already_messaged(
    world: World,
) -> None:
    """ENG-LC-05 (the engine side; the deletion endpoint arrives with the account phase)."""
    await _start_at(world, "2026-10-13T19:00")
    person = await world.ready(contacts=("Mom", "Dad"), stages=((180, ("Mom",)), (1440, ("Dad",))))
    await world.advance_to(ist("2026-10-14T23:10"))  # Mom has been messaged; Dad not yet
    assert len(world.mail.to(_address(person, "Mom"), "contact_alert")) == 1

    async with world.engine.db.sessionmaker() as session, session.begin():
        outcome = await void_open_incident(
            session,
            audit_writer=world.engine.services.audit,
            owner_id=__import__("uuid").UUID(person.user_id),
            closed_by="account_deleted",
            now=world.clock.current,
        )
    assert outcome is not None
    assert [name for _, name in outcome.all_clear_to] == ["Mom"]  # only those already messaged

    incident = world.incidents(person)[0]
    assert (incident["status"], incident["closed_by"]) == ("voided", "account_deleted")
    await world.advance_to(ist("2026-10-15T21:00"))
    assert world.mail.to(_address(person, "Mom"), "contact_all_clear") == []
    [withdrawn] = world.mail.to(_address(person, "Mom"), "contact_alert_withdrawn")
    assert "closed their AfterMe account" in withdrawn.text
    assert world.mail.to(_address(person, "Dad"), "contact_alert") == []
    assert world.mail.to(_address(person, "Dad"), "contact_alert_withdrawn") == []
    assert world.mail.to(_address(person, "Dad"), "contact_all_clear") == []


async def test_multi_day_interval_and_a_late_night_deadline(world: World) -> None:
    """ENG-LC-07."""
    await _start_at(world, "2026-10-13T19:00")
    person = await world.person(premium=True)
    await world.contact(person, "Mom")
    await world.plan(person, [(180, ["Mom"])])
    schedule = await world.call(person, "GET", "/v1/checkin/schedule")
    saved = await world.call(
        person,
        "PUT",
        "/v1/checkin/schedule",
        json={"interval_days": 3, "due_local_time": "00:30", "reminder_lead_minutes": 60},
        headers={"If-Match": schedule.headers["etag"]},
    )
    assert saved.status_code == 200, saved.text
    await world.activate(person)
    # every 3 days by 00:30, from Tue 19:00: the 12-hour rule is not involved, so Fri 00:30
    assert world.config(person)["next_due_at"] == ist("2026-10-16T00:30")
    await world.advance_to(ist("2026-10-16T00:30:15"))
    incident = world.open_incident(person)
    assert incident is not None
    assert incident["missed_due_at"] == ist("2026-10-16T00:30")
    assert incident["grace_ends_at"] == ist("2026-10-16T03:30")
    await world.advance_to(ist("2026-10-16T03:36"))
    assert len(world.mail.to(_address(person, "Mom"), "contact_alert")) == 1


async def test_im_safe_is_idempotent_and_needs_an_open_incident(world: World) -> None:
    await _start_at(world, "2026-10-13T19:00")
    person = await world.ready()
    await world.advance_to(ist("2026-10-14T23:10"))
    incident_id = str(world.open_incident(person)["id"])  # type: ignore[index]

    first = await world.safe(person, incident_id, key="im-safe-idempotency-0001")
    again = await world.h.client.post(
        f"/v1/incidents/{incident_id}/safe",
        headers={**person.headers, "Idempotency-Key": "im-safe-idempotency-0001"},
    )
    assert again.status_code == 200
    assert again.json() == first.json()
    assert again.headers["idempotent-replayed"] == "true"
    # a different key on a closed incident is a conflict
    closed = await world.safe(person, incident_id, expect=409)
    assert problem(closed)["code"] == "invalid_state"
    assert len(world.mail.to(_address(person, "Mom"), "contact_all_clear")) == 0  # not yet sent
    await world.tick()
    assert len(world.mail.to(_address(person, "Mom"), "contact_all_clear")) == 1  # exactly one


async def test_im_safe_needs_a_fresh_password(world: World) -> None:
    await _start_at(world, "2026-10-13T19:00")
    person = await world.ready()
    await world.advance_to(ist("2026-10-14T23:10"))
    incident_id = str(world.open_incident(person)["id"])  # type: ignore[index]
    await world.login(person)
    response = await world.h.client.post(
        f"/v1/incidents/{incident_id}/safe",
        headers={**person.headers, "Idempotency-Key": "no-reauth-idempotency-1"},
    )
    assert response.status_code == 403
    assert problem(response)["code"] == "reauth_required"
    assert world.open_incident(person) is not None


async def test_the_current_incident_endpoint_tells_the_whole_story(world: World) -> None:
    await _start_at(world, "2026-10-13T19:00")
    person = await world.ready(contacts=("Mom", "Dad"), stages=((180, ("Mom",)), (1440, ("Dad",))))
    assert (await world.call(person, "GET", "/v1/incidents/current")).json() == {"incident": None}

    await world.advance_to(ist("2026-10-14T23:10"))
    response = await world.call(person, "GET", "/v1/incidents/current")
    incident = response.json()["incident"]
    assert incident["status"] == "escalating"
    assert incident["requires"] == "safe"  # Mom has been messaged
    assert incident["contacts_messaged"] is True
    kinds = [(t["kind"], t["status"]) for t in incident["timeline"]]
    assert kinds == [
        ("user_reminder", "executed"),
        ("user_reminder", "executed"),
        ("user_reminder", "executed"),
        ("execute_stage", "executed"),
        ("execute_stage", "pending"),
    ]
    first, second = incident["timeline"][3], incident["timeline"][4]
    assert first["stage_position"] == 1
    assert second["stage_position"] == 2
    assert first["contacts"] == [
        {"id": person.contacts["Mom"], "display_name": "Mom", "result": "messaged"}
    ]
    assert second["contacts"] == [
        {"id": person.contacts["Dad"], "display_name": "Dad", "result": None}
    ]
    # Home carries the same object
    home = (await world.call(person, "GET", "/v1/home")).json()
    assert home["incident"]["id"] == incident["id"]
    assert home["checkin"]["status"] == "incident_open"


async def test_history_lists_closed_incidents_newest_first(world: World) -> None:
    await _start_at(world, "2026-10-13T19:00")
    person = await world.ready()
    await world.advance_to(ist("2026-10-14T20:30"))
    world.clock.set(ist("2026-10-14T21:00"))
    await world.checkin(person)
    await world.advance_to(ist("2026-10-15T20:30"))
    page = (await world.call(person, "GET", "/v1/incidents")).json()
    assert [i["status"] for i in page["items"]] == ["grace", "resolved"]
    assert page["next_cursor"] is None
    one = (await world.call(person, "GET", "/v1/incidents?limit=1")).json()
    assert len(one["items"]) == 1
    assert one["next_cursor"]
    rest = (
        await world.call(person, "GET", f"/v1/incidents?limit=1&cursor={one['next_cursor']}")
    ).json()
    assert [i["status"] for i in rest["items"]] == ["resolved"]
    detail = (await world.call(person, "GET", f"/v1/incidents/{one['items'][0]['id']}")).json()
    assert detail["requires"] == "checkin"


async def test_deadline_reached_while_the_checkin_is_in_flight(world: World) -> None:
    """FS-28: either no incident opens, or it opens and the check-in resolves it at once."""
    await _start_at(world, "2026-10-13T19:00")
    person = await world.ready()
    world.clock.set(ist("2026-10-13T19:30"))
    due = world.config(person)["next_due_at"]
    world.clock.set(due + timedelta(seconds=1))  # the deadline has just passed
    await world.tick()  # the worker opens the incident first...
    assert world.open_incident(person) is not None
    response = await world.checkin(person)  # ...and the check-in resolves it, nobody told
    assert response.json()["incident_resolved"] is True
    assert world.notifications(person, audience="contact") == []
