"""A timezone change restarts an active check-in schedule in the new zone and is refused while
an incident is open (ESCALATION_ENGINE §3.4; API_SPEC §3; TEST_PLAN PROF-*)."""

from __future__ import annotations

from typing import Any

import psycopg

from tests.support import Harness, bearer, problem, rows

Db = psycopg.Connection[dict[str, Any]]


async def _patch(h: Harness, tokens: dict[str, Any], body: dict[str, Any]) -> Any:
    return await h.client.patch("/v1/me/profile", json=body, headers=bearer(tokens))


async def _schedule(h: Harness, tokens: dict[str, Any]) -> dict[str, Any]:
    response = await h.client.get("/v1/checkin/schedule", headers=bearer(tokens))
    body: dict[str, Any] = response.json()
    return body


async def _activate(h: Harness, tokens: dict[str, Any]) -> None:
    await h.add_contact(tokens, "mom@example.com")
    await h.plan_for_contacts(tokens)
    assert (await h.client.post("/v1/checkin/activate", headers=bearer(tokens))).status_code == 200


async def test_an_active_schedule_is_recomputed_in_the_new_zone(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("tz@example.com")
    await _activate(h, tokens)
    before = await _schedule(h, tokens)
    assert before["next_due_at"] == "2026-10-09T14:30:00Z"  # 20:00 IST

    response = await _patch(h, tokens, {"timezone": "America/New_York"})
    assert response.status_code == 200

    after = await _schedule(h, tokens)
    # Now 05:00 EDT on Oct 8: the next 20:00 there is Oct 9 20:00 EDT = Oct 10 00:00Z.
    assert after["next_due_at"] == "2026-10-10T00:00:00Z"
    assert after["timezone"] == "America/New_York"
    assert after["version"] == before["version"] + 1
    (event,) = rows(owner_db, "SELECT * FROM audit_logs WHERE action = 'schedule.updated'")
    assert event["metadata"] == {"fields": "timezone", "active": True}
    assert rows(owner_db, "SELECT 1 FROM audit_logs WHERE action = 'profile.timezone_changed'")


async def test_an_inactive_schedule_only_changes_its_version(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("tz-inactive@example.com")
    before = await _schedule(h, tokens)
    assert (await _patch(h, tokens, {"timezone": "Europe/London"})).status_code == 200
    after = await _schedule(h, tokens)
    assert after["status"] == "inactive"
    assert after["next_due_at"] is None
    assert after["timezone"] == "Europe/London"
    assert after["version"] == before["version"] + 1
    assert rows(owner_db, "SELECT 1 FROM audit_logs WHERE action = 'schedule.updated'") == []


async def test_an_unchanged_timezone_leaves_the_schedule_alone(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("tz-same@example.com")
    await _activate(h, tokens)
    before = await _schedule(h, tokens)
    assert (await _patch(h, tokens, {"timezone": "Asia/Kolkata"})).status_code == 200
    assert await _schedule(h, tokens) == before


async def test_other_profile_changes_do_not_touch_the_schedule(h: Harness) -> None:
    tokens = await h.signup("tz-other@example.com")
    await _activate(h, tokens)
    before = await _schedule(h, tokens)
    assert (await _patch(h, tokens, {"display_name": "New Name"})).status_code == 200
    assert await _schedule(h, tokens) == before


async def test_the_change_is_refused_while_an_incident_is_open(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup("tz-incident@example.com")
    await _activate(h, tokens)
    owner_db.execute(
        "UPDATE checkin_configurations SET status = 'incident_open' WHERE user_id = %s",
        (tokens["user"]["id"],),
    )
    before = await _schedule(h, tokens)

    response = await _patch(h, tokens, {"timezone": "America/New_York", "display_name": "Other"})
    assert response.status_code == 409
    assert problem(response)["code"] == "incident_open"

    me = (await h.client.get("/v1/me", headers=bearer(tokens))).json()
    assert me["profile"]["timezone"] == "Asia/Kolkata"
    assert me["profile"]["display_name"] == "Test User"  # nothing in the request was applied
    assert await _schedule(h, tokens) == before
    assert (
        rows(owner_db, "SELECT 1 FROM audit_logs WHERE action = 'profile.timezone_changed'") == []
    )
