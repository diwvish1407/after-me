"""Check-in schedule: ``GET/PUT /v1/checkin/schedule``, activate and deactivate
(API_SPEC §6.1; TEST_PLAN CHK-*)."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

import httpx
import psycopg
import pytest

from tests.support import Harness, bearer, problem, rows

Db = psycopg.Connection[dict[str, Any]]

SCHEDULE = "/v1/checkin/schedule"
OWNER = "owner@example.com"
BODY = {"interval_days": 2, "due_local_time": "21:30", "reminder_lead_minutes": 30}


async def _get(h: Harness, tokens: dict[str, Any]) -> httpx.Response:
    return await h.client.get(SCHEDULE, headers=bearer(tokens))


async def _put(
    h: Harness, tokens: dict[str, Any], body: Any, if_match: str | None
) -> httpx.Response:
    headers = bearer(tokens)
    if if_match is not None:
        headers["If-Match"] = if_match
    return await h.client.put(SCHEDULE, json=body, headers=headers)


async def _post(h: Harness, tokens: dict[str, Any], action: str) -> httpx.Response:
    return await h.client.post(f"/v1/checkin/{action}", headers=bearer(tokens))


async def _active_account(h: Harness, email: str = OWNER) -> dict[str, Any]:
    tokens = await h.signup(email)
    assert (await h.add_contact(tokens, f"mom.{email}")).status_code == 201
    await h.plan_for_contacts(tokens)
    assert (await _post(h, tokens, "activate")).status_code == 200
    return tokens


def _config(owner_db: Db, tokens: dict[str, Any]) -> dict[str, Any]:
    (row,) = rows(
        owner_db,
        "SELECT * FROM checkin_configurations WHERE user_id = %s",
        tokens["user"]["id"],
    )
    return dict(row)


def _audit(owner_db: Db, action: str) -> list[dict[str, Any]]:
    return [dict(r) for r in rows(owner_db, "SELECT * FROM audit_logs WHERE action = %s", action)]


# --- read -------------------------------------------------------------------------------------


async def test_a_new_account_has_the_default_inactive_schedule(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    response = await _get(h, tokens)
    assert response.status_code == 200
    assert response.json() == {
        "interval_days": 1,
        "due_local_time": "20:00",
        "reminder_lead_minutes": 60,
        "timezone": "Asia/Kolkata",
        "status": "inactive",
        "next_due_at": None,
        "last_checkin_at": None,
        "version": 1,
    }
    assert response.headers["etag"] == '"sched-1"'
    assert response.headers["cache-control"] == "no-store"


async def test_the_schedule_belongs_to_the_caller(h: Harness) -> None:
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    assert (await h.add_contact(alice, "alice.mom@example.com")).status_code == 201
    await h.plan_for_contacts(alice)
    assert (await _post(h, alice, "activate")).status_code == 200
    bobs = await _get(h, bob)
    assert bobs.json()["status"] == "inactive"
    assert bobs.json()["version"] == 1


# --- update with If-Match ---------------------------------------------------------------------


async def test_put_without_if_match_is_428(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    response = await _put(h, tokens, BODY, if_match=None)
    assert response.status_code == 428
    assert problem(response)["code"] == "precondition_required"
    assert _config(owner_db, tokens)["interval_days"] == 1


@pytest.mark.parametrize(
    "if_match", ['"sched-9"', '"sched-0"', "sched-1", "*", 'W/"sched-1"', '""']
)
async def test_put_with_a_stale_or_malformed_if_match_is_412(
    h: Harness, owner_db: Db, if_match: str
) -> None:
    tokens = await h.signup(OWNER)
    response = await _put(h, tokens, BODY, if_match=if_match)
    assert response.status_code == 412
    assert problem(response)["code"] == "precondition_failed"
    assert _config(owner_db, tokens)["interval_days"] == 1


async def test_put_saves_the_schedule_of_an_inactive_account(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    response = await _put(h, tokens, BODY, '"sched-1"')
    assert response.status_code == 200
    assert response.json() == {
        "interval_days": 2,
        "due_local_time": "21:30",
        "reminder_lead_minutes": 30,
        "timezone": "Asia/Kolkata",
        "status": "inactive",
        "next_due_at": None,
        "last_checkin_at": None,
        "version": 2,
    }
    assert response.headers["etag"] == '"sched-2"'
    assert (await _get(h, tokens)).json() == response.json()
    (event,) = _audit(owner_db, "schedule.updated")
    assert event["metadata"] == {"fields": "interval.time.reminder", "active": False}
    assert event["user_visible"] is True
    assert event["subject_user_id"] == event["actor_id"]


async def test_an_old_version_cannot_overwrite_a_newer_one(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    assert (await _put(h, tokens, BODY, '"sched-1"')).status_code == 200
    lost = await _put(h, tokens, {**BODY, "interval_days": 7}, '"sched-1"')
    assert lost.status_code == 412
    assert (await _get(h, tokens)).json()["interval_days"] == 2


async def test_an_identical_put_changes_nothing(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    assert (await _put(h, tokens, BODY, '"sched-1"')).status_code == 200
    again = await _put(h, tokens, BODY, '"sched-2"')
    assert again.status_code == 200
    assert again.json()["version"] == 2
    assert again.headers["etag"] == '"sched-2"'
    assert len(_audit(owner_db, "schedule.updated")) == 1


@pytest.mark.parametrize(
    "body",
    [
        {**BODY, "interval_days": 0},
        {**BODY, "interval_days": 31},
        {**BODY, "interval_days": "2"},
        {**BODY, "interval_days": 1.5},
        {**BODY, "interval_days": True},
        {**BODY, "interval_days": None},
        {**BODY, "due_local_time": "24:00"},
        {**BODY, "due_local_time": "8:00"},
        {**BODY, "due_local_time": "20:00:00"},
        {**BODY, "due_local_time": "20:60"},
        {**BODY, "due_local_time": 2000},
        {**BODY, "reminder_lead_minutes": 45},
        {**BODY, "reminder_lead_minutes": "60"},
        {**BODY, "reminder_lead_minutes": -30},
        {**BODY, "timezone": "UTC"},
        {"interval_days": 1, "due_local_time": "20:00"},
        {},
    ],
)
async def test_put_validates_the_body(h: Harness, owner_db: Db, body: dict[str, Any]) -> None:
    tokens = await h.signup(OWNER)
    response = await _put(h, tokens, body, '"sched-1"')
    assert response.status_code == 422
    error = problem(response)
    assert error["code"] == "validation_failed"
    assert error["errors"]
    config = _config(owner_db, tokens)
    assert (config["interval_days"], config["version"]) == (1, 1)


@pytest.mark.parametrize("limit", [1, 30])
async def test_interval_limits_are_inclusive(h: Harness, limit: int) -> None:
    tokens = await h.signup(OWNER)
    response = await _put(h, tokens, {**BODY, "interval_days": limit}, '"sched-1"')
    assert response.status_code == 200
    assert response.json()["interval_days"] == limit


@pytest.mark.parametrize("minutes", [0, 30, 60, 120, 240])
async def test_every_reminder_lead_is_accepted(h: Harness, minutes: int) -> None:
    tokens = await h.signup(OWNER)
    response = await _put(h, tokens, {**BODY, "reminder_lead_minutes": minutes}, '"sched-1"')
    assert response.status_code == 200


# --- activation -------------------------------------------------------------------------------


async def test_activation_needs_a_contact(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    response = await _post(h, tokens, "activate")
    assert response.status_code == 409
    error = problem(response)
    assert error["code"] == "activation_requirements_unmet"
    assert error["requirements"] == ["no_contacts", "no_stages"]
    config = _config(owner_db, tokens)
    assert config["status"] == "inactive"
    assert config["next_due_at"] is None
    assert _audit(owner_db, "schedule.activated") == []


async def test_a_contact_that_is_switched_off_does_not_count(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    contact = (await h.add_contact(tokens, "mom@example.com")).json()
    patched = await h.client.patch(
        f"/v1/contacts/{contact['id']}", json={"is_active": False}, headers=bearer(tokens)
    )
    assert patched.status_code == 200
    await h.plan_for_contacts(tokens)  # the stage has nobody who is switched on
    response = await _post(h, tokens, "activate")
    assert response.status_code == 409
    assert problem(response)["requirements"] == ["no_contacts", "stage_empty"]


async def test_activation_needs_a_stage_that_notifies_someone(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    await h.add_contact(tokens, "mom@example.com")
    no_plan = await _post(h, tokens, "activate")
    assert no_plan.status_code == 409
    assert problem(no_plan)["requirements"] == ["no_stages"]

    plan = await h.plan_for_contacts(tokens)
    assert plan["stages"][0]["notify_contact_ids"]
    ready = await _post(h, tokens, "activate")
    assert ready.status_code == 200
    assert ready.json()["status"] == "active"


async def test_a_stage_that_lost_its_contact_no_longer_counts(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    contact = (await h.add_contact(tokens, "mom@example.com")).json()
    await h.plan_for_contacts(tokens)
    deleted = await h.client.delete(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))
    assert deleted.status_code == 204
    await h.add_contact(tokens, "dad@example.com", name="Dad")
    response = await _post(h, tokens, "activate")
    assert response.status_code == 409
    assert problem(response)["requirements"] == ["stage_empty"]


async def test_a_deleted_contact_does_not_count(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    contact = (await h.add_contact(tokens, "mom@example.com")).json()
    deleted = await h.client.delete(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))
    assert deleted.status_code == 204
    assert (await _post(h, tokens, "activate")).status_code == 409


async def test_activation_starts_the_schedule(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    await h.add_contact(tokens, "mom@example.com")
    await h.plan_for_contacts(tokens)
    response = await _post(h, tokens, "activate")
    assert response.status_code == 200
    body = response.json()
    # 2026-10-08 09:00Z is 14:30 in Kolkata; the next 20:00 there is the following day.
    assert body["status"] == "active"
    assert body["next_due_at"] == "2026-10-09T14:30:00Z"
    assert body["last_checkin_at"] is None
    assert body["version"] == 2
    assert response.headers["etag"] == '"sched-2"'
    config = _config(owner_db, tokens)
    assert config["baseline_at"] == h.clock.current
    assert config["activated_at"] == h.clock.current
    (event,) = _audit(owner_db, "schedule.activated")
    assert event["user_visible"] is True


async def test_activation_uses_the_saved_schedule(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    await h.add_contact(tokens, "mom@example.com")
    assert (await _put(h, tokens, BODY, '"sched-1"')).status_code == 200
    await h.plan_for_contacts(tokens)
    body = (await _post(h, tokens, "activate")).json()
    # Every 2 days by 21:30 IST from Thu 2026-10-08 14:30 IST -> Sat 2026-10-10 21:30 IST.
    assert body["next_due_at"] == "2026-10-10T16:00:00Z"


async def test_activating_twice_does_not_restart_the_clock(h: Harness, owner_db: Db) -> None:
    tokens = await _active_account(h)
    before = _config(owner_db, tokens)
    h.clock.advance(hours=3)
    tokens = await h.relogin(OWNER)
    await h.plan_for_contacts(tokens)
    again = await _post(h, tokens, "activate")
    assert again.status_code == 200
    assert again.json()["version"] == 2
    after = _config(owner_db, tokens)
    assert after["baseline_at"] == before["baseline_at"]
    assert after["next_due_at"] == before["next_due_at"]
    assert len(_audit(owner_db, "schedule.activated")) == 1


async def test_changing_an_active_schedule_restarts_the_clock(h: Harness, owner_db: Db) -> None:
    tokens = await _active_account(h)
    h.clock.advance(hours=1)  # 10:00Z = 15:30 IST on Oct 8
    tokens = await h.relogin(OWNER)
    assert (await h.reauth(tokens)).status_code == 204  # lengthening an active schedule
    response = await _put(h, tokens, BODY, '"sched-2"')
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "active"
    assert body["next_due_at"] == "2026-10-10T16:00:00Z"  # 21:30 IST, two days on
    assert body["version"] == 3
    assert _config(owner_db, tokens)["baseline_at"] == h.clock.current
    event = _audit(owner_db, "schedule.updated")[-1]
    assert event["metadata"]["active"] is True


# --- step-up: lengthening the interval of an active schedule ---------------------------------


async def test_lengthening_an_active_schedule_needs_a_fresh_password(
    h: Harness, owner_db: Db
) -> None:
    tokens = await _active_account(h)
    before = _config(owner_db, tokens)
    response = await _put(h, tokens, {**BODY, "interval_days": 30}, '"sched-2"')
    assert response.status_code == 403
    assert problem(response)["code"] == "reauth_required"
    assert _config(owner_db, tokens) == before
    assert _audit(owner_db, "schedule.updated") == []

    assert (await h.reauth(tokens)).status_code == 204
    ok = await _put(h, tokens, {**BODY, "interval_days": 30}, '"sched-2"')
    assert ok.status_code == 200
    assert ok.json()["interval_days"] == 30
    assert ok.json()["version"] == 3


async def test_the_password_is_only_good_for_five_minutes(h: Harness) -> None:
    tokens = await _active_account(h)
    assert (await h.reauth(tokens)).status_code == 204
    h.clock.advance(minutes=5, seconds=1)
    response = await _put(h, tokens, {**BODY, "interval_days": 7}, '"sched-2"')
    assert response.status_code == 403
    assert problem(response)["code"] == "reauth_required"


@pytest.mark.parametrize(
    "change",
    [
        {"interval_days": 1, "due_local_time": "22:15"},  # same interval, later time
        {"interval_days": 1, "reminder_lead_minutes": 0},  # reminders only
    ],
)
async def test_other_changes_to_an_active_schedule_need_no_password(
    h: Harness, change: dict[str, Any]
) -> None:
    tokens = await _active_account(h)
    body = {"interval_days": 1, "due_local_time": "20:00", "reminder_lead_minutes": 60, **change}
    response = await _put(h, tokens, body, '"sched-2"')
    assert response.status_code == 200, response.text


async def test_shortening_an_active_schedule_needs_no_password(h: Harness) -> None:
    tokens = await _active_account(h)
    assert (await h.reauth(tokens)).status_code == 204
    assert (await _put(h, tokens, {**BODY, "interval_days": 7}, '"sched-2"')).status_code == 200
    h.clock.advance(minutes=6)  # the password is no longer fresh
    shorter = await _put(h, tokens, {**BODY, "interval_days": 2}, '"sched-3"')
    assert shorter.status_code == 200
    assert shorter.json()["interval_days"] == 2


async def test_an_inactive_schedule_can_be_lengthened_freely(h: Harness) -> None:
    """Nothing is protected yet (onboarding): no password is asked for."""
    tokens = await h.signup(OWNER)
    response = await _put(h, tokens, {**BODY, "interval_days": 30}, '"sched-1"')
    assert response.status_code == 200


async def test_a_deactivate_activate_cycle_cannot_smuggle_a_longer_interval(
    h: Harness,
) -> None:
    """Deactivating needs the password already; the interval is then free to change while
    off, and activation uses what was saved. The password gate sits on the way *out*."""
    tokens = await _active_account(h)
    assert (await h.reauth(tokens)).status_code == 204
    assert (await _post(h, tokens, "deactivate")).status_code == 200
    saved = await _put(h, tokens, {**BODY, "interval_days": 14}, '"sched-3"')
    assert saved.status_code == 200
    assert (await _post(h, tokens, "activate")).json()["interval_days"] == 14


# --- deactivation -----------------------------------------------------------------------------


async def test_deactivation_needs_a_fresh_password(h: Harness, owner_db: Db) -> None:
    tokens = await _active_account(h)
    response = await _post(h, tokens, "deactivate")
    assert response.status_code == 403
    assert problem(response)["code"] == "reauth_required"
    assert _config(owner_db, tokens)["status"] == "active"
    assert _audit(owner_db, "schedule.deactivated") == []


async def test_deactivation_turns_the_schedule_off(h: Harness, owner_db: Db) -> None:
    tokens = await _active_account(h)
    assert (await h.reauth(tokens)).status_code == 204
    response = await _post(h, tokens, "deactivate")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "inactive"
    assert body["next_due_at"] is None
    assert body["version"] == 3
    config = _config(owner_db, tokens)
    assert (config["baseline_at"], config["next_due_at"], config["activated_at"]) == (
        None,
        None,
        None,
    )
    (event,) = _audit(owner_db, "schedule.deactivated")
    assert event["user_visible"] is True


async def test_deactivating_an_inactive_schedule_is_a_no_op(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    assert (await h.reauth(tokens)).status_code == 204
    response = await _post(h, tokens, "deactivate")
    assert response.status_code == 200
    assert response.json()["version"] == 1
    assert _audit(owner_db, "schedule.deactivated") == []


async def test_reactivating_computes_a_fresh_deadline(h: Harness) -> None:
    tokens = await _active_account(h)
    assert (await h.reauth(tokens)).status_code == 204
    assert (await _post(h, tokens, "deactivate")).status_code == 200
    h.clock.advance(days=3)
    tokens = await h.relogin(OWNER)
    await h.plan_for_contacts(tokens)
    body = (await _post(h, tokens, "activate")).json()
    assert body["next_due_at"] == "2026-10-12T14:30:00Z"


# --- an open incident blocks every change (§3.4, §10) -----------------------------------------


async def test_nothing_changes_while_an_incident_is_open(h: Harness, owner_db: Db) -> None:
    tokens = await _active_account(h)
    owner_db.execute(
        "UPDATE checkin_configurations SET status = 'incident_open' WHERE user_id = %s",
        (tokens["user"]["id"],),
    )
    before = _config(owner_db, tokens)
    assert (await h.reauth(tokens)).status_code == 204

    for response in (
        await _put(h, tokens, BODY, '"sched-2"'),
        await _post(h, tokens, "activate"),
        await _post(h, tokens, "deactivate"),
    ):
        assert response.status_code == 409
        assert problem(response)["code"] == "incident_open"
    assert _config(owner_db, tokens) == before
    assert (await _get(h, tokens)).json()["status"] == "incident_open"


# --- timezones end to end ---------------------------------------------------------------------


async def test_a_deadline_inside_a_dst_gap_lands_after_the_gap(h: Harness) -> None:
    h.clock.set(datetime(2026, 3, 7, 17, 0, tzinfo=UTC))  # Sat 12:00 in New York (EST)
    tokens = await h.signup(OWNER)
    patched = await h.client.patch(
        "/v1/me/profile", json={"timezone": "America/New_York"}, headers=bearer(tokens)
    )
    assert patched.status_code == 200
    await h.add_contact(tokens, "mom@example.com")
    version = (await _get(h, tokens)).json()["version"]
    put = await _put(
        h,
        tokens,
        {"interval_days": 1, "due_local_time": "02:30", "reminder_lead_minutes": 60},
        f'"sched-{version}"',
    )
    assert put.status_code == 200
    await h.plan_for_contacts(tokens)
    body = (await _post(h, tokens, "activate")).json()
    assert body["next_due_at"] == "2026-03-08T07:30:00Z"  # 03:30 EDT: 02:30 does not exist


async def test_a_deadline_inside_a_dst_overlap_uses_the_second_occurrence(h: Harness) -> None:
    h.clock.set(datetime(2026, 10, 31, 16, 0, tzinfo=UTC))  # Sat 12:00 in New York (EDT)
    tokens = await h.signup(OWNER)
    await h.client.patch(
        "/v1/me/profile", json={"timezone": "America/New_York"}, headers=bearer(tokens)
    )
    await h.add_contact(tokens, "mom@example.com")
    version = (await _get(h, tokens)).json()["version"]
    await _put(
        h,
        tokens,
        {"interval_days": 1, "due_local_time": "01:30", "reminder_lead_minutes": 0},
        f'"sched-{version}"',
    )
    await h.plan_for_contacts(tokens)
    body = (await _post(h, tokens, "activate")).json()
    assert body["next_due_at"] == "2026-11-01T06:30:00Z"  # 01:30 EST, the second 01:30
