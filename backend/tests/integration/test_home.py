"""``GET /v1/home`` (API_SPEC §5; PERF-04 shape)."""

from __future__ import annotations

import uuid
from datetime import timedelta
from typing import Any

import psycopg

from tests.support import Harness, bearer, make_premium

Db = psycopg.Connection[dict[str, Any]]

OWNER = "owner@example.com"


async def _home(h: Harness, tokens: dict[str, Any]) -> dict[str, Any]:
    response = await h.client.get("/v1/home", headers=bearer(tokens))
    assert response.status_code == 200, response.text
    assert response.headers["cache-control"] == "no-store"
    body: dict[str, Any] = response.json()
    return body


def _codes(home: dict[str, Any]) -> list[str]:
    return [i["code"] for i in home["readiness"]["issues"]]


async def test_a_new_account(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    home = await _home(h, tokens)
    assert home == {
        "server_time": "2026-10-08T09:00:00Z",
        "user": {"display_name": "Test User", "tier": "free", "timezone": "Asia/Kolkata"},
        "checkin": {
            "status": "inactive",
            "next_due_at": None,
            "last_checkin_at": None,
            "schedule": {
                "interval_days": 1,
                "due_local_time": "20:00",
                "reminder_lead_minutes": 60,
            },
        },
        "incident": None,
        "plan_summary": {
            "stages": 0,
            "contacts_total": 0,
            "contacts_verified": 0,
            "instructions_active": 0,
        },
        "readiness": {
            "ready": False,
            "issues": [
                {"code": "schedule_inactive", "contact_id": None},
                {"code": "no_contacts", "contact_id": None},
                {"code": "no_stages", "contact_id": None},
            ],
        },
        "recent_activity": [],
    }


async def test_a_pending_contact_is_a_readiness_issue_with_its_id(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    contact = (await h.add_contact(tokens, "mom@example.com")).json()
    home = await _home(h, tokens)
    assert home["readiness"]["issues"] == [
        {"code": "schedule_inactive", "contact_id": None},
        {"code": "contact_pending", "contact_id": contact["id"]},
        {"code": "no_stages", "contact_id": None},
    ]
    assert home["plan_summary"]["contacts_total"] == 1
    assert home["plan_summary"]["contacts_verified"] == 0
    assert home["readiness"]["ready"] is False


async def test_every_contact_status_maps_to_its_issue(h: Harness, owner_db: Db) -> None:
    tokens = await h.signup(OWNER)
    make_premium(owner_db, OWNER)  # a free account holds one contact
    ids: dict[str, str] = {}
    for n, status in enumerate(["declined", "bounced", "opted_out", "verified"]):
        contact = (
            await h.add_contact(
                tokens,
                f"{status}@example.com",
                name=status.title(),
                priority=n + 1,
            )
        ).json()
        ids[status] = contact["id"]
    for status, contact_id in ids.items():
        owner_db.execute(
            "UPDATE trusted_contacts SET verification_status = %s WHERE id = %s",
            (status, contact_id),
        )
    home = await _home(h, tokens)
    issues = {i["code"]: i["contact_id"] for i in home["readiness"]["issues"]}
    assert issues == {
        "schedule_inactive": None,
        "no_stages": None,
        "contact_declined": ids["declined"],
        "contact_bounced": ids["bounced"],
        "contact_opted_out": ids["opted_out"],
    }
    assert home["plan_summary"] == {
        "stages": 0,
        "contacts_total": 4,
        "contacts_verified": 1,
        "instructions_active": 0,
    }


async def test_an_active_schedule_with_a_verified_contact_is_ready(
    h: Harness, owner_db: Db
) -> None:
    tokens = await h.signup(OWNER)
    contact = (await h.add_contact(tokens, "mom@example.com")).json()
    owner_db.execute(
        "UPDATE trusted_contacts SET verification_status = 'verified', verified_at = now() "
        "WHERE id = %s",
        (contact["id"],),
    )
    await h.plan_for_contacts(tokens)
    assert (await h.client.post("/v1/checkin/activate", headers=bearer(tokens))).status_code == 200
    home = await _home(h, tokens)
    assert home["readiness"] == {"ready": True, "issues": []}
    assert home["checkin"]["status"] == "active"
    assert home["checkin"]["next_due_at"] == "2026-10-09T14:30:00Z"


async def test_a_contact_that_is_switched_off_is_not_judged(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    contact = (await h.add_contact(tokens, "mom@example.com")).json()
    await h.client.patch(
        f"/v1/contacts/{contact['id']}", json={"is_active": False}, headers=bearer(tokens)
    )
    home = await _home(h, tokens)
    assert _codes(home) == ["schedule_inactive", "no_contacts", "no_stages"]
    assert home["plan_summary"]["contacts_total"] == 1


async def test_recent_activity_is_the_newest_five_user_visible_records(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    await h.add_contact(tokens, "mom@example.com")  # contact.created + contact.invitation_sent
    for _ in range(5):
        h.clock.advance(minutes=1)  # five minutes in all: inside the access token's lifetime
        response = await h.client.post(
            "/v1/checkins", headers={**bearer(tokens), "Idempotency-Key": str(uuid.uuid4())}
        )
        assert response.status_code == 200
    home = await _home(h, tokens)
    activity = home["recent_activity"]
    assert len(activity) == 5
    assert {a["action"] for a in activity} == {"checkin.recorded"}
    times = [a["occurred_at"] for a in activity]
    assert times == sorted(times, reverse=True)
    assert set(activity[0]) == {"action", "occurred_at"}


async def test_the_contact_events_appear_when_nothing_newer_exists(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    await h.add_contact(tokens, "mom@example.com")
    home = await _home(h, tokens)
    assert {a["action"] for a in home["recent_activity"]} == {
        "contact.created",
        "contact.invitation_sent",
    }


async def test_home_shows_only_the_callers_data(h: Harness) -> None:
    alice = await h.signup("alice@example.com")
    bob = await h.signup("bob@example.com")
    await h.add_contact(alice, "alices.mom@example.com", name="Alice's Mom")
    await h.plan_for_contacts(alice)
    await h.client.post("/v1/checkin/activate", headers=bearer(alice))
    bobs = await _home(h, bob)
    assert bobs["checkin"]["status"] == "inactive"
    assert bobs["plan_summary"]["contacts_total"] == 0
    assert bobs["recent_activity"] == []
    assert "Alice" not in str(bobs)


async def test_server_time_tracks_the_clock(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    first = await _home(h, tokens)
    h.clock.advance(timedelta(minutes=5))
    tokens = await h.relogin(OWNER)
    second = await _home(h, tokens)
    assert first["server_time"] == "2026-10-08T09:00:00Z"
    assert second["server_time"] == "2026-10-08T09:05:00Z"


async def test_home_requires_a_session(h: Harness) -> None:
    assert (await h.client.get("/v1/home")).status_code == 401


async def test_a_stage_with_nobody_to_notify_is_reported(h: Harness) -> None:
    tokens = await h.signup(OWNER)
    contact = (await h.add_contact(tokens, "mom@example.com")).json()
    await h.plan_for_contacts(tokens)
    deleted = await h.client.delete(f"/v1/contacts/{contact['id']}", headers=bearer(tokens))
    assert deleted.status_code == 204
    home = await _home(h, tokens)
    assert "stage_empty" in _codes(home)
    assert "no_stages" not in _codes(home)
    assert home["plan_summary"]["stages"] == 1


async def test_a_complete_plan_clears_the_plan_issues_and_is_counted(
    h: Harness, owner_db: Db
) -> None:
    tokens = await h.signup(OWNER)
    contact = (await h.add_contact(tokens, "mom@example.com")).json()
    owner_db.execute(
        "UPDATE trusted_contacts SET verification_status = 'verified', verified_at = now() "
        "WHERE id = %s",
        (contact["id"],),
    )
    await h.plan_for_contacts(tokens)
    assert (await h.client.post("/v1/checkin/activate", headers=bearer(tokens))).status_code == 200
    home = await _home(h, tokens)
    assert home["readiness"] == {"ready": True, "issues": []}
    assert home["plan_summary"]["stages"] == 1
