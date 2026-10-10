"""The owner's decisions on the review's open findings (ESCALATION_ENGINE §13.2):

* F-03: a contact-facing stage found late is put back, and the person is warned again;
* F-12: a fresh password is needed to weaken a safety net that is on;
* F-05a: the anomaly threshold follows the number of people and the hour of the day.
"""

from __future__ import annotations

from datetime import timedelta
from typing import Any

import pytest

from app.engine.hold import HoldMonitor
from app.ops import admin
from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")
STAGE_1 = DUE + timedelta(minutes=180)
STAGE_2 = DUE + timedelta(minutes=1440)
TWO_STAGES = {"contacts": ("Mom", "Dad"), "stages": ((180, ("Mom",)), (1440, ("Dad",)))}


def address(person: Person, label: str) -> str:
    return f"{label.lower()}.{person.user_id[:6]}@example.com"


def audit_count(world: World, action: str) -> int:
    row = world.db.execute("SELECT count(*) AS n FROM audit_logs WHERE action = %s", (action,))
    found = row.fetchone()
    assert found is not None
    return int(found["n"])


# --- F-03: a stage found late is put back --------------------------------------------------


async def test_f03_a_stage_found_late_is_put_back_and_the_person_is_warned_again(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))  # incident open, in grace
    # The worker is down; when it is back the stage is an hour overdue.
    world.clock.set(STAGE_1 + timedelta(hours=1))
    report = await world.tick()
    assert report.deferred == 1

    stage = world.actions(person, kind="execute_stage")[0]
    assert stage["status"] == "pending"
    assert stage["scheduled_for"] == world.clock.current + timedelta(minutes=30)
    assert world.notifications(person, template_key="contact_alert") == []
    delayed = world.mail.to(person.email, "incident_delayed")
    assert len(delayed) == 1
    assert "Mom will be notified at" in delayed[0].text
    assert audit_count(world, "escalation.stage_deferred") == 1

    # It then runs on time, once, and the alert leaves after the settle delay as usual.
    await world.advance_to(stage["scheduled_for"] + timedelta(minutes=6))
    assert world.actions(person, kind="execute_stage")[0]["status"] == "executed"
    assert len(world.mail.to(address(person, "Mom"), "contact_alert")) == 1


async def test_f03_a_stage_that_is_only_a_little_late_runs_as_usual(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))
    world.clock.set(STAGE_1 + timedelta(minutes=3))  # inside the 5-minute tolerance
    report = await world.tick()
    assert report.deferred == 0
    assert world.actions(person, kind="execute_stage")[0]["status"] == "executed"
    assert world.mail.to(person.email, "incident_delayed") == []


async def test_f03_every_later_stage_moves_by_the_same_amount(world: World) -> None:
    person = await world.ready(**TWO_STAGES)  # type: ignore[arg-type]
    await world.advance_to(DUE + timedelta(minutes=10))
    before = [a["scheduled_for"] for a in world.actions(person, kind="execute_stage")]
    world.clock.set(STAGE_1 + timedelta(hours=2))
    await world.tick()
    after = [a["scheduled_for"] for a in world.actions(person, kind="execute_stage")]
    assert after[0] == world.clock.current + timedelta(minutes=30)
    assert after[1] - after[0] == before[1] - before[0]  # the spacing is kept
    assert all(a > b for a, b in zip(after, before, strict=True))  # only ever later


async def test_f03_a_late_second_stage_warns_about_its_own_contacts(world: World) -> None:
    person = await world.ready(**TWO_STAGES)  # type: ignore[arg-type]
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    assert len(world.mail.to(address(person, "Mom"), "contact_alert")) == 1
    world.clock.set(STAGE_2 + timedelta(hours=2))  # the worker was down across stage 2
    await world.tick()
    stage_2 = world.actions(person, kind="execute_stage")[1]
    assert stage_2["status"] == "pending"
    assert stage_2["scheduled_for"] == world.clock.current + timedelta(minutes=30)
    delayed = world.mail.to(person.email, "incident_delayed")
    assert len(delayed) == 1
    assert "Dad will be notified at" in delayed[0].text
    assert world.mail.to(address(person, "Dad"), "contact_alert") == []


async def test_f03_a_check_in_after_the_deferral_still_settles_it(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))
    world.clock.set(STAGE_1 + timedelta(hours=1))
    await world.tick()
    await world.checkin(person)
    await world.advance_to(world.clock.current + timedelta(hours=2))
    assert world.incidents(person)[0]["status"] == "resolved"
    assert world.mail.to(address(person, "Mom"), "contact_alert") == []


async def test_f03_nothing_is_deferred_during_a_hold_which_shifts_on_its_own(
    world: World,
) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=10))
    await admin.hold_enter(world.engine.services, operator="alex", reason="investigating")
    original = world.actions(person, kind="execute_stage")[0]["scheduled_for"]
    world.clock.set(STAGE_1 + timedelta(hours=1))
    report = await world.tick()
    assert report.deferred == 0
    assert world.actions(person, kind="execute_stage")[0]["scheduled_for"] == original
    assert world.mail.to(person.email, "incident_delayed") == []


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


async def test_f03_a_releasing_stage_keeps_a_full_warning_lead_after_an_outage(
    world: World,
) -> None:
    """INV-9: after an outage the final warning is due at once; the stage must still be a full
    lead (60 minutes) after it, not in the same tick."""
    person = await world.ready(
        contacts=("Mom", "Dad", "Sam"), stages=((180, ("Mom",)), (1440, ("Dad",)))
    )
    await _instruct(world, person)  # a real instruction: the real G8 and the real release
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    world.clock.set(STAGE_2 + timedelta(minutes=45))  # the worker was down across the warning
    await world.tick()
    warning = world.actions(person, kind="user_final_warning")[0]
    stage = world.actions(person, kind="execute_stage")[1]
    assert warning["status"] == "executed"  # it warns now
    assert stage["status"] == "pending"
    assert stage["scheduled_for"] >= world.clock.current + timedelta(minutes=60)
    assert len(world.mail.to(person.email, "release_final_warning")) == 1


# --- F-12: a fresh password to weaken a safety net that is on -------------------------------


async def _put_plan(
    world: World, person: Person, *, grace: int, offset: int, reauth: bool = False
) -> Any:
    await world.login(person)
    if reauth:
        assert (await world.h.reauth(person.tokens)).status_code == 204
    current = await world.h.client.get("/v1/plan", headers=person.headers)
    stage = current.json()["stages"][0]
    body = {
        "grace_minutes": grace,
        "stages": [
            {
                "id": stage["id"],
                "offset_minutes": offset,
                "notify_contact_ids": [person.contacts["Mom"]],
            }
        ],
    }
    return await world.h.client.put(
        "/v1/plan", json=body, headers={**person.headers, "If-Match": current.headers["etag"]}
    )


async def test_f12_changing_the_plan_of_an_active_schedule_needs_the_password(
    world: World,
) -> None:
    person = await world.ready()
    refused = await _put_plan(world, person, grace=240, offset=240)
    assert refused.status_code == 403
    assert refused.json()["code"] == "reauth_required"
    assert world.config(person)["status"] == "active"
    again = await _put_plan(world, person, grace=240, offset=240, reauth=True)
    assert again.status_code == 200, again.text
    assert again.json()["grace_minutes"] == 240


async def test_f12_a_plan_that_does_not_change_needs_nothing(world: World) -> None:
    person = await world.ready()
    same = await _put_plan(world, person, grace=180, offset=180)
    assert same.status_code == 200


async def test_f12_nothing_is_asked_while_the_schedule_is_off(world: World) -> None:
    person = await world.ready(activate=False)  # onboarding
    changed = await _put_plan(world, person, grace=240, offset=240)
    assert changed.status_code == 200, changed.text


async def test_f12_removing_a_contact_who_would_be_told_needs_the_password(
    world: World,
) -> None:
    person = await world.ready(contacts=("Mom", "Dad"), stages=((180, ("Mom",)),))
    mom, dad = person.contacts["Mom"], person.contacts["Dad"]
    # Dad is in no stage: removing him cannot make anyone miss an alert.
    free = await world.call(person, "DELETE", f"/v1/contacts/{dad}")
    assert free.status_code == 204
    # Mom is: a stolen token alone must not be able to remove her.
    refused = await world.call(person, "DELETE", f"/v1/contacts/{mom}")
    assert refused.status_code == 403
    assert refused.json()["code"] == "reauth_required"
    assert (await world.h.reauth(person.tokens)).status_code == 204
    done = await world.h.client.delete(f"/v1/contacts/{mom}", headers=person.headers)
    assert done.status_code == 204


async def test_f12_deactivating_or_re_addressing_a_contact_who_would_be_told_needs_it(
    world: World,
) -> None:
    person = await world.ready()
    mom = person.contacts["Mom"]
    for body in ({"is_active": False}, {"email": "someone.else@example.com"}):
        refused = await world.call(person, "PATCH", f"/v1/contacts/{mom}", json=body)
        assert refused.status_code == 403, body
        assert refused.json()["code"] == "reauth_required"
    # Other edits, and any edit of someone no stage lists, are not step-up material.
    renamed = await world.call(person, "PATCH", f"/v1/contacts/{mom}", json={"display_name": "Ma"})
    assert renamed.status_code == 200
    assert world.db.execute(
        "SELECT is_active FROM trusted_contacts WHERE id = %s", (mom,)
    ).fetchone() == {"is_active": True}

    assert (await world.h.reauth(person.tokens)).status_code == 204
    done = await world.h.client.patch(
        f"/v1/contacts/{mom}", json={"is_active": False}, headers=person.headers
    )
    assert done.status_code == 200


async def test_f12_validation_is_answered_before_the_password(world: World) -> None:
    person = await world.ready()
    own = await world.call(
        person, "PATCH", f"/v1/contacts/{person.contacts['Mom']}", json={"email": person.email}
    )
    assert own.status_code == 422  # your own address: said first, no password needed to hear it


# --- F-05a: the anomaly threshold follows people and the hour -------------------------------


@pytest.mark.parametrize(
    ("active", "history", "baseline", "expected"),
    [
        (1_000, False, 0, 500),  # no history: half of everyone
        (1_000, False, 9_999, 500),  # ... and the baseline is not trusted without history
        (1_000, True, 30, 120),  # four times what this hour usually has
        (1_000, True, 5, 100),  # ... but never below a tenth of everyone
        (1_000, True, 400, 900),  # ... and above nine tenths is abnormal whatever the baseline
        (10, True, 0, 25),  # a small base: the absolute floor
        (10, False, 0, 25),
    ],
)
async def test_f05_the_threshold_follows_people_and_the_hour(
    world: World,
    monkeypatch: pytest.MonkeyPatch,
    active: int,
    history: bool,
    baseline: int,
    expected: int,
) -> None:
    async def users(session: Any) -> int:
        return active

    async def has_history(session: Any, now: Any) -> bool:
        return history

    async def same_hour(session: Any, now: Any) -> int:
        return baseline

    monkeypatch.setattr(HoldMonitor, "_active_users", staticmethod(users))
    monkeypatch.setattr(HoldMonitor, "_has_history", staticmethod(has_history))
    monkeypatch.setattr(HoldMonitor, "_same_hour_baseline", staticmethod(same_hour))
    async with world.engine.services.db.sessionmaker() as session:
        threshold = await world.engine.hold._anomaly_threshold(session, world.clock.current)
    assert threshold == expected


@pytest.mark.no_rate_limit
@pytest.mark.settings(anomaly_floor_per_hour=3)
async def test_f05_without_history_half_of_everyone_in_an_hour_is_the_threshold(
    world: World,
) -> None:
    """40 active people, 15 of whom miss the deadline in the same hour: a due time that many
    share, not an anomaly. 25 of them is."""
    people = [await world.ready(f"learn{i:02d}@example.com") for i in range(40)]
    for person in people[:25]:  # these check in before the deadline
        world.clock.set(DUE - timedelta(minutes=30))
        await world.checkin(person)
    await world.advance_to(DUE + timedelta(minutes=5))
    await world.tick()
    holds = world.db.execute("SELECT * FROM system_holds WHERE reason = 'anomaly'").fetchall()
    assert holds == []  # 15 of 40 is below half


@pytest.mark.no_rate_limit
@pytest.mark.settings(anomaly_floor_per_hour=3)
async def test_f05_more_than_half_of_everyone_in_an_hour_is_an_anomaly(world: World) -> None:
    people = [await world.ready(f"surge{i:02d}@example.com") for i in range(40)]
    for person in people[:10]:  # 30 of 40 miss it
        world.clock.set(DUE - timedelta(minutes=30))
        await world.checkin(person)
    await world.advance_to(DUE + timedelta(minutes=5))
    await world.tick()
    holds = world.db.execute("SELECT * FROM system_holds WHERE reason = 'anomaly'").fetchall()
    assert len(holds) == 1


async def test_f05_the_same_hour_of_earlier_days_is_the_baseline(world: World) -> None:
    people = [await world.ready(f"base{i}@example.com") for i in range(3)]
    await world.advance_to(DUE + timedelta(minutes=5))  # three incidents open at DUE
    assert all(world.open_incident(p) is not None for p in people)
    async with world.engine.services.db.sessionmaker() as session:
        one_day_on = DUE + timedelta(days=1, minutes=30)
        assert await HoldMonitor._same_hour_baseline(session, one_day_on) == 3
        assert await HoldMonitor._same_hour_baseline(session, DUE + timedelta(minutes=30)) == 0
        assert await HoldMonitor._has_history(session, DUE + timedelta(days=1)) is False
        assert await HoldMonitor._has_history(session, DUE + timedelta(days=8)) is True
