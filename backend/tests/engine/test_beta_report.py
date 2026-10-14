"""The closed-beta report (``afterme-admin beta-report``): metrics, every escalated incident,
verdict hints, date filters, a stable JSON schema, and nothing private in either format.

The scenario is driven through the real API, engine and dispatcher on the frozen clock; only
what the engine cannot be made to do here (a provider's delivery webhook, a web check-in) is
seeded as the row it would have written.
"""

from __future__ import annotations

import json
import re
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from typing import Any

import pytest
from psycopg import sql
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from app.models import ALL_TABLES
from app.ops import admin, beta
from cli import admin as cli
from tests.engine.test_release import BODY, TITLE, Portal, address
from tests.support import TEST_DB
from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")  # 14:30Z: the deadline of everyone activated at T0
HOLD_FROM = datetime(2026, 10, 8, 12, 0, tzinfo=UTC)
HOLD_TO = datetime(2026, 10, 8, 13, 0, tzinfo=UTC)
NOW = datetime(2026, 10, 9, 18, 0, tzinfo=UTC)


@dataclass
class Beta:
    quiet: Person  # misses, then I'M OK before anyone is told
    safe: Person  # contacts messaged, then I'M SAFE
    voided: Person  # contacts messaged, then an operator voids it
    late: Person  # opens within 24 h of the Hold's end, contacts messaged, still open
    incident: dict[str, str]  # label -> incident id


def _incident_of(world: World, person: Person) -> str:
    [row] = world.incidents(person)
    return str(row["id"])


async def _set_due_time(world: World, person: Person, due: str) -> None:
    schedule = await world.call(person, "GET", "/v1/checkin/schedule")
    saved = await world.call(
        person,
        "PUT",
        "/v1/checkin/schedule",
        json={"interval_days": 1, "due_local_time": due, "reminder_lead_minutes": 60},
        headers={"If-Match": schedule.headers["etag"]},
    )
    assert saved.status_code == 200, saved.text


def _log_outcome(world: World, person: Person, outcome: str, event_id: str) -> None:
    """What a provider's delivery webhook writes: one more log row for the contact's alert."""
    [alert] = world.notifications(person, template_key="contact_alert")
    world.db.execute(
        "INSERT INTO notification_logs (notification_id, attempted_at, provider, outcome, "
        "provider_event_id) VALUES (%s, %s, 'recording', %s, %s)",
        (alert["id"], world.clock.current, outcome, event_id),
    )


async def scenario(world: World) -> Beta:
    """Four people, one Hold, three escalated incidents, one that never reached a contact."""
    services = world.engine.services
    quiet = await world.ready("quiet.person@example.com")
    safe = await world.ready("safe.person@example.com")
    voided = await world.ready("voided.person@example.com")

    # (d) a Hold, entered and ended by an operator, long before the cohort's deadline
    await world.advance_to(HOLD_FROM)
    await admin.hold_enter(services, operator="alex", reason="provider incident, investigating")
    await world.advance_to(HOLD_TO)
    assert await admin.hold_exit(services, operator="alex") == 1
    await world.tick()

    # someone whose deadline falls 15 hours after the Hold ended (daily, 10:00 IST)
    await world.advance_to(HOLD_TO + timedelta(minutes=30))
    late = await world.ready("late.person@example.com", activate=False)
    await _set_due_time(world, late, "10:00")
    await world.activate(late)
    late_due = world.config(late)["next_due_at"]
    assert late_due == ist("2026-10-09T10:00")
    await world.advance_to(late_due + timedelta(minutes=186))
    still_open = world.open_incident(late)
    assert still_open is not None
    assert still_open["status"] == "escalated"
    assert still_open["contacts_messaged_at"] is not None

    # (a) a missed deadline, resolved by I'M OK before any contact is told
    await world.advance_to(DUE + timedelta(minutes=60))
    quiet_incident = _incident_of(world, quiet)
    await world.checkin(quiet)
    assert world.incidents(quiet)[0]["closed_by"] == "user_checkin"

    # (b) and (c) escalate: stage 1 runs at +180 and the messages go out at +185
    await world.advance_to(DUE + timedelta(minutes=186))
    safe_incident = _incident_of(world, safe)
    voided_incident = _incident_of(world, voided)
    assert world.incidents(safe)[0]["contacts_messaged_at"] == DUE + timedelta(minutes=185)
    await world.safe(safe, safe_incident)
    assert await admin.void_incident(
        services, operator="alex", incident_id=uuid.UUID(voided_incident)
    )
    await world.advance_to(DUE + timedelta(minutes=200))  # the all-clear and the withdrawal go out
    return Beta(
        quiet=quiet,
        safe=safe,
        voided=voided,
        late=late,
        incident={
            "quiet": quiet_incident,
            "safe": safe_incident,
            "voided": voided_incident,
            "late": _incident_of(world, late),
        },
    )


async def seeded_scenario(world: World) -> Beta:
    """The scenario, plus what a provider's webhooks and a browser would have added: one alert
    reported delivered, one reported bounced, and one check-in from the web page."""
    built = await scenario(world)
    _log_outcome(world, built.safe, "delivered", "evt-delivered-1")
    _log_outcome(world, built.voided, "bounced", "evt-bounced-1")
    world.db.execute(
        "INSERT INTO checkin_events (user_id, kind, source, received_at, idempotency_key, "
        "response_snapshot) VALUES (%s, 'ok', 'web', %s, 'seeded-web-checkin-0001', '{}'::jsonb)",
        (built.late.user_id, world.clock.current),
    )
    return built


async def report(world: World, **kwargs: Any) -> dict[str, Any]:
    document = (await beta.beta_report(world.engine.services, **kwargs)).as_dict()
    assert isinstance(document, dict)
    return document


def block(document: Mapping[str, Any], incident_id: str) -> dict[str, Any]:
    [found] = [b for b in document["escalated_incidents"] if b["incident_id"] == incident_id]
    assert isinstance(found, dict)
    return found


def _events(item: Mapping[str, Any]) -> list[tuple[float, str]]:
    return [(e["minutes"], e["event"]) for e in item["timeline"]]


def _digest(world: World) -> dict[str, str]:
    """Row count and a hash of the content of every application table."""
    found: dict[str, str] = {}
    for table in ALL_TABLES:
        row = world.db.execute(
            sql.SQL(
                "SELECT count(*) AS n, "
                "md5(coalesce(string_agg(t::text, ',' ORDER BY t::text), '')) AS d FROM {} t"
            ).format(sql.Identifier(table))
        ).fetchone()
        assert row is not None
        found[table] = f"{row['n']}:{row['d']}"
    return found


# --- the metrics ------------------------------------------------------------------------------


async def test_the_metrics_for_the_period(world: World) -> None:
    await seeded_scenario(world)
    metrics = (await report(world))["metrics"]

    assert metrics["users"] == {"created": 4, "active": 3, "with_active_schedule_now": 4}
    assert metrics["checkins"] == {
        "total": 3,
        "by_source": {"app": 2, "web": 1},
        "by_kind": {"ok": 2, "safe": 1},
    }
    incidents = metrics["incidents"]
    assert incidents["opened"] == 4
    assert incidents["by_closed_by"] == {
        "user_checkin": 1,
        "user_safe": 1,
        "account_deleted": 0,
        "operator_void": 1,
    }
    assert incidents["still_open"] == 1
    assert incidents["contacts_messaged"] == 3  # the quiet one never reached a contact
    assert incidents["stage_executed_nobody_messaged"] == 0
    assert sum(incidents["by_status"].values()) == 4

    messages = metrics["messages"]
    assert messages["by_template"]["contact_alert"] == {
        "queued": 0,
        "sending": 0,
        "sent": 3,
        "failed": 0,
        "cancelled": 0,
    }
    assert messages["by_template"]["contact_all_clear"]["sent"] == 1
    assert messages["by_template"]["contact_alert_withdrawn"]["sent"] == 1
    assert messages["by_category"]["contact_escalation"]["sent"] == 3
    assert messages["cancelled_reasons"] == {}
    assert messages["total"] == sum(
        sum(counts.values()) for counts in messages["by_template"].values()
    )

    email = metrics["delivery"]["email"]
    assert email["outcomes"]["delivered"] == 1
    assert email["outcomes"]["bounced"] == 1
    assert email["outcomes"]["complained"] == 0
    assert email["outcomes"]["accepted"] == messages["total"]  # nothing was refused
    assert email["accepted_by_provider"] == {"recording": messages["total"]}
    assert metrics["delivery"]["push"] == {"sent": 0, "invalid_token": 0, "failed": 0}

    assert metrics["releases"]["created"] == 0
    assert metrics["delays"] == {
        "incident_delayed_notices": 0,
        "incidents_with_a_delayed_notice": 0,
        "stage_deferrals": 0,
    }
    assert metrics["contacts"] == {"bounced_now": 0, "bounced_in_period": 0}
    assert metrics["accounts"] == {
        "pending_deletion_now": 0,
        "deletion_requested": 0,
        "deleted": 0,
    }
    assert metrics["safety"] == {"actions_held": 0, "consistency_violations": 0}


async def test_the_hold_history_has_its_reason_and_duration(world: World) -> None:
    await scenario(world)
    holds = (await report(world))["metrics"]["holds"]
    assert (holds["entered"], holds["exited"], holds["total_minutes"]) == (1, 1, 60.0)
    assert holds["by_reason"] == {"ingestion": 0, "anomaly": 0, "operator": 1}
    [hold] = holds["history"]
    assert hold["reason"] == "operator"
    assert hold["started_at"] == HOLD_FROM.isoformat()
    assert hold["ended_at"] == HOLD_TO.isoformat()
    assert hold["duration_minutes"] == 60.0
    assert hold["ongoing"] is False
    assert hold["exit_processed_at"] is not None
    assert "provider incident" not in json.dumps(holds)  # the operator's note stays in the table


async def test_a_hold_that_is_still_active_is_ongoing_up_to_now(world: World) -> None:
    await world.ready()
    await world.advance_to(HOLD_FROM)
    await admin.hold_enter(world.engine.services, operator="alex", reason="investigating")
    world.clock.set(HOLD_FROM + timedelta(minutes=90))
    [hold] = (await report(world))["metrics"]["holds"]["history"]
    assert hold["ongoing"] is True
    assert hold["ended_at"] is None
    assert hold["duration_minutes"] == 90.0


async def test_a_near_miss_is_counted_separately(world: World) -> None:
    """A stage ran, the settle delay had not passed, and the person checked in: nobody was
    told. Not a wrong message, but the closest thing to one."""
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=181))  # stage 1 ran, nothing sent yet
    assert world.open_incident(person)["contacts_messaged_at"] is None  # type: ignore[index]
    await world.checkin(person, expect=200)
    await world.tick()
    document = await report(world)
    assert document["metrics"]["incidents"]["stage_executed_nobody_messaged"] == 1
    assert document["metrics"]["incidents"]["contacts_messaged"] == 0
    assert document["escalated_incidents"] == []
    assert document["metrics"]["messages"]["cancelled_reasons"]  # the queued alert was cancelled


# --- the escalated incidents ------------------------------------------------------------------


async def test_every_incident_in_which_a_contact_was_messaged_is_listed(world: World) -> None:
    built = await seeded_scenario(world)
    document = await report(world)
    listed = [b["incident_id"] for b in document["escalated_incidents"]]
    assert sorted(listed) == sorted(
        [built.incident["safe"], built.incident["voided"], built.incident["late"]]
    )
    assert built.incident["quiet"] not in listed  # resolved by I'M OK before anyone was told
    assert listed[0] == built.incident["late"]  # oldest first
    review = document["review"]
    assert review["escalated_incidents"] == 3
    assert review["needs_human_review"] == 3
    assert review["incident_ids"] == [b["incident_id"] for b in document["escalated_incidents"]]
    # the one that is still open is counted on its own line, whatever the period
    assert review["still_open_with_contacts_messaged"] == 1
    assert review["still_open_incident_ids"] == [built.incident["late"]]


async def test_the_safe_incident_is_a_false_alarm_candidate(world: World) -> None:
    built = await seeded_scenario(world)
    item = block(await report(world), built.incident["safe"])
    assert item["user_id"] == built.safe.user_id
    assert item["opened_at"] == DUE.isoformat()
    assert (item["status"], item["closed_by"]) == ("cancelled", "user_safe")
    assert _events(item) == [
        (0.0, "missed"),
        (0.0, "user_reminder"),
        (90.0, "user_reminder"),
        (165.0, "user_reminder"),
        (180.0, "stage_executed"),
        (185.0, "contacts_messaged"),
        (186.0, "closed"),
    ]
    assert [e["detail"] for e in item["timeline"] if e["event"] == "user_reminder"] == [
        "missed",
        "midpoint",
        "last_chance",
    ]
    assert item["minutes_from_first_contact_message_to_resolution"] == 1.0
    assert item["contacts_messaged"] == 1
    [contact] = item["contacts"]
    assert contact["label"] == "contact-1"
    assert contact["outcome"] == "delivered"
    assert [(m["template"], m["status"], m["delivery"]) for m in contact["messages"]] == [
        ("contact_alert", "sent", "delivered"),
        ("contact_all_clear", "sent", "accepted"),
    ]
    assert item["releases"] == {"created": 0, "viewed": 0, "revoked": 0, "views": 0}
    assert item["hints"] == ["closed_by_checkin_after_contacts_messaged"]
    assert item["needs_human_review"] is True
    assert item["review_reasons"] == ["closed_by_checkin_after_contacts_messaged"]
    assert item["user_notices"]["all_clear_confirmation"] == {"sent": 1}


async def test_the_voided_incident_and_its_bounce_are_flagged(world: World) -> None:
    built = await seeded_scenario(world)
    item = block(await report(world), built.incident["voided"])
    assert (item["status"], item["closed_by"]) == ("voided", "operator_void")
    assert item["timeline"][-1]["event"] == "closed"
    assert item["timeline"][-1]["detail"] == "operator_void"
    [contact] = item["contacts"]
    assert contact["outcome"] == "bounced"
    assert contact["messages"][0]["delivery"] == "bounced"
    assert [m["template"] for m in contact["messages"]] == [
        "contact_alert",
        "contact_alert_withdrawn",  # not "all clear": nobody said the person is safe
    ]
    # hints come out in the order the rules are listed, not the order they were found
    assert item["hints"] == [
        "voided_by_operator_after_contacts_messaged",
        "delivery_failed_to_a_contact",
    ]
    assert item["needs_human_review"] is True
    assert item["review_reasons"] == ["voided_by_operator_after_contacts_messaged"]


async def test_an_open_incident_after_a_hold_is_flagged_for_the_hold_alone(world: World) -> None:
    built = await seeded_scenario(world)
    item = block(await report(world), built.incident["late"])
    assert item["status"] == "escalated"
    assert item["closed_by"] is None
    assert item["closed_at"] is None
    assert item["minutes_from_first_contact_message_to_resolution"] is None
    assert item["hints"] == ["opened_within_24h_of_hold_exit"]
    assert item["needs_human_review"] is True
    assert [e for e in _events(item) if e[1] == "closed"] == []
    # the Hold is on the timeline too, but only when it overlaps the incident
    assert all(not e["event"].startswith("hold_") for e in item["timeline"])
    assert item["contacts"][0]["outcome"] == "sent"  # accepted by the provider, no report back


async def test_a_hold_that_overlaps_an_incident_is_on_its_timeline(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=100))
    await admin.hold_enter(world.engine.services, operator="alex", reason="investigating")
    await world.advance_to(DUE + timedelta(minutes=130))
    await admin.hold_exit(world.engine.services, operator="alex")
    await world.advance_to(DUE + timedelta(minutes=400))
    assert world.incidents(person)[0]["contacts_messaged_at"] is not None  # shifted, then sent
    [item] = (await report(world))["escalated_incidents"]
    events = {e["event"]: e["minutes"] for e in item["timeline"]}
    assert events["hold_started"] == 100.0
    assert events["hold_ended"] == 130.0
    assert "stage_delayed" in item["hints"]  # the Hold pushed the stage back
    assert events["stage_executed"] > 180.0  # ... and it ran after the original time


# --- the period -------------------------------------------------------------------------------


async def test_the_period_filters_incidents_and_events_by_utc_day(world: World) -> None:
    built = await seeded_scenario(world)

    everything = await report(world, since=date(2026, 10, 8), until=date(2026, 10, 9))
    assert everything["metrics"]["incidents"]["opened"] == 4
    assert len(everything["escalated_incidents"]) == 3
    assert everything["period"] == {
        "since": "2026-10-08",
        "until": "2026-10-09",
        "from": "2026-10-08T00:00:00+00:00",
        "to_exclusive": "2026-10-10T00:00:00+00:00",
        "timezone": "UTC",
    }

    # both ends are inclusive days: 9 October holds all the incidents, and no Hold
    day = await report(world, since=date(2026, 10, 9), until=date(2026, 10, 9))
    assert day["metrics"]["incidents"]["opened"] == 4
    assert day["metrics"]["users"]["created"] == 0  # they signed up on the 8th
    assert day["metrics"]["holds"]["entered"] == 0
    assert day["metrics"]["holds"]["history"] == []
    assert day["metrics"]["checkins"]["total"] == 3

    before = await report(world, until=date(2026, 10, 8))
    assert before["metrics"]["incidents"]["opened"] == 0
    assert before["escalated_incidents"] == []
    assert before["review"]["needs_human_review"] == 0
    assert before["metrics"]["users"]["created"] == 4
    assert before["metrics"]["holds"]["entered"] == 1
    assert before["metrics"]["holds"]["exited"] == 1

    after = await report(world, since=date(2026, 10, 10))
    assert after["metrics"]["incidents"]["opened"] == 0
    # nothing was messaged or closed after the 10th; only the alarm that is still open is
    # listed (an unresolved alert is never left out because of the dates asked for)
    assert [b["incident_id"] for b in after["escalated_incidents"]] == [built.incident["late"]]
    assert after["escalated_incidents"][0]["listed_because"] == ["still_open"]
    assert after["metrics"]["checkins"]["total"] == 0
    assert after["metrics"]["messages"]["total"] == 0
    assert after["metrics"]["holds"]["history"] == []
    # a snapshot of now, not of the period
    assert after["metrics"]["users"]["with_active_schedule_now"] == 4

    # in the list because of the day contacts were first messaged (here, also the day it opened)
    listed = {b["incident_id"]: b["listed_because"] for b in day["escalated_incidents"]}
    assert "contacts_first_messaged_in_period" in listed[built.incident["late"]]
    assert "closed_in_period" in listed[built.incident["safe"]]
    assert listed[built.incident["late"]] == [
        "contacts_first_messaged_in_period",
        "still_open",
    ]


@pytest.mark.no_db
def test_a_hold_is_listed_when_it_overlaps_the_period() -> None:
    now = datetime(2026, 10, 12, tzinfo=UTC)
    across = beta.HoldRow(
        id=uuid.UUID(int=1),
        reason="operator",
        started_at=datetime(2026, 10, 8, 23, tzinfo=UTC),
        detected_at=datetime(2026, 10, 8, 23, tzinfo=UTC),
        ended_at=datetime(2026, 10, 9, 1, tzinfo=UTC),
        exit_processed_at=datetime(2026, 10, 9, 1, tzinfo=UTC),
    )
    ongoing = beta.HoldRow(
        id=uuid.UUID(int=2),
        reason="anomaly",
        started_at=datetime(2026, 10, 11, 23, tzinfo=UTC),
        detected_at=datetime(2026, 10, 11, 23, tzinfo=UTC),
        ended_at=None,
        exit_processed_at=None,
    )
    holds = [across, ongoing]

    def counts(since: date | None, until: date | None) -> tuple[int, int, int]:
        section = beta._holds_section(holds, beta.Period(since, until), now)
        return section["entered"], section["exited"], len(section["history"])

    assert counts(date(2026, 10, 8), date(2026, 10, 8)) == (1, 0, 1)  # still running at midnight
    assert counts(date(2026, 10, 9), date(2026, 10, 9)) == (0, 1, 1)  # began the day before
    assert counts(date(2026, 10, 10), date(2026, 10, 10)) == (0, 0, 0)
    assert counts(date(2026, 10, 11), None) == (1, 0, 1)  # the open one, up to now
    assert counts(None, None) == (2, 1, 2)
    section = beta._holds_section(holds, beta.Period(), now)
    assert [h["duration_minutes"] for h in section["history"]] == [120.0, 60.0]
    assert section["total_minutes"] == 180.0


# --- the JSON document ------------------------------------------------------------------------


def _shape(value: Any, *, free: frozenset[str] = frozenset()) -> Any:
    """The keys of a document: the fixed ones recursively, data-driven maps (named in
    ``free``) as ``"<map>"``, lists by their first element."""
    if isinstance(value, dict):
        return {
            key: "<map>" if key in free else _shape(item, free=free)
            for key, item in sorted(value.items())
        }
    if isinstance(value, list):
        return [_shape(value[0], free=free)] if value else []
    return type(value).__name__


FREE_MAPS = frozenset({"by_template", "by_category", "cancelled_reasons", "accepted_by_provider"})
FREE_MAPS_IN_INCIDENTS = frozenset({"user_notices"})


async def test_the_json_document_has_stable_keys(world: World) -> None:
    await seeded_scenario(world)
    document = await report(world)
    shape = _shape(document, free=FREE_MAPS | FREE_MAPS_IN_INCIDENTS)

    assert sorted(shape) == [
        "coverage",
        "escalated_incidents",
        "generated_at",
        "metrics",
        "period",
        "review",
        "rules",
        "schema_version",
        "source",
    ]
    assert document["schema_version"] == 1
    assert shape["period"] == {
        "from": "NoneType",
        "since": "NoneType",
        "timezone": "str",
        "to_exclusive": "NoneType",
        "until": "NoneType",
    }
    assert shape["review"] == {
        "escalated_incidents": "int",
        "incident_ids": ["str"],
        "listed_by": "str",
        "needs_human_review": "int",
        "still_open_incident_ids": ["str"],
        "still_open_with_contacts_messaged": "int",
    }
    assert shape["source"] == {
        "alembic_revision": "str",
        "database": "str",
        "environment": "str",
        "role": "str",
        "schema_at_head": "bool",
    }
    assert shape["coverage"] == {
        "accounts_purged_in_period": "int",
        "notification_retention_days": "int",
        "oldest_notification_at": "str",
        "period_starts_before_oldest_notification": "bool",
    }
    assert shape["rules"] == [{"meaning": "str", "name": "str", "needs_review": "bool"}]
    assert sorted(shape["metrics"]) == [
        "accounts",
        "checkins",
        "contacts",
        "delays",
        "delivery",
        "holds",
        "incidents",
        "messages",
        "releases",
        "safety",
        "users",
    ]
    metrics = shape["metrics"]
    assert metrics["users"] == {
        "active": "int",
        "created": "int",
        "with_active_schedule_now": "int",
    }
    assert metrics["checkins"] == {
        "by_kind": {"ok": "int", "safe": "int"},
        "by_source": {"app": "int", "web": "int"},
        "total": "int",
    }
    assert metrics["incidents"] == {
        "by_closed_by": {
            "account_deleted": "int",
            "operator_void": "int",
            "user_checkin": "int",
            "user_safe": "int",
        },
        "by_status": {
            "cancelled": "int",
            "escalated": "int",
            "escalating": "int",
            "grace": "int",
            "resolved": "int",
            "voided": "int",
        },
        "contacts_messaged": "int",
        "contacts_messaged_counted_by": "str",
        "counted_by": "str",
        "opened": "int",
        "stage_executed_nobody_messaged": "int",
        "still_open": "int",
    }
    assert metrics["messages"] == {
        "by_category": "<map>",
        "by_template": "<map>",
        "cancelled_reasons": "<map>",
        "total": "int",
    }
    assert metrics["delivery"] == {
        "email": {
            "accepted_by_provider": "<map>",
            "outcomes": {
                "accepted": "int",
                "bounced": "int",
                "complained": "int",
                "delivered": "int",
                "error": "int",
                "rejected": "int",
            },
        },
        "push": {"failed": "int", "invalid_token": "int", "sent": "int"},
    }
    assert metrics["releases"] == {
        "created": "int",
        "revoked": "int",
        "revoked_by_reason": dict.fromkeys(
            (
                "account_deleted",
                "contact_opted_out",
                "contact_removed",
                "hold_rollback",
                "instruction_removed",
                "operator",
                "recipient_removed",
                "user_checkin",
                "user_safe",
            ),
            "int",
        ),
        "viewed": "int",
    }
    assert metrics["holds"] == {
        "by_reason": {"anomaly": "int", "ingestion": "int", "operator": "int"},
        "entered": "int",
        "exited": "int",
        "history": [
            {
                "detected_at": "str",
                "duration_minutes": "float",
                "ended_at": "str",
                "exit_processed_at": "str",
                "hold_id": "str",
                "ongoing": "bool",
                "reason": "str",
                "started_at": "str",
            }
        ],
        "total_minutes": "float",
    }
    assert metrics["delays"] == {
        "incident_delayed_notices": "int",
        "incidents_with_a_delayed_notice": "int",
        "stage_deferrals": "int",
    }
    assert metrics["contacts"] == {"bounced_in_period": "int", "bounced_now": "int"}
    assert metrics["accounts"] == {
        "deleted": "int",
        "deletion_requested": "int",
        "pending_deletion_now": "int",
    }
    assert metrics["safety"] == {"actions_held": "int", "consistency_violations": "int"}

    [item, *_] = shape["escalated_incidents"]
    assert item == {
        "actions": {"cancelled": "int", "executed": "int", "held": "int", "pending": "int"},
        "closed_at": "NoneType",
        "closed_by": "NoneType",
        "contacts": [
            {
                "attempted": "bool",
                "contact_id": "str",
                "label": "str",
                "messages": [
                    {
                        "attempts": "int",
                        "cancelled_reason": "NoneType",
                        "category": "str",
                        "channel": "str",
                        "delivery": "str",
                        "error_code": "NoneType",
                        "provider": "str",
                        "sent_minutes": "float",
                        "status": "str",
                        "template": "str",
                    }
                ],
                "outcome": "str",
            }
        ],
        "contacts_messaged": "int",
        "contacts_messaged_at": "str",
        "hints": ["str"],
        "incident_id": "str",
        "listed_because": ["str"],
        "minutes_from_first_contact_message_to_resolution": "NoneType",
        "missed_due_at": "str",
        "needs_human_review": "bool",
        "opened_at": "str",
        "releases": {"created": "int", "revoked": "int", "views": "int", "viewed": "int"},
        "review_reasons": ["str"],
        "status": "str",
        "timeline": [{"at": "str", "detail": "str", "event": "str", "minutes": "float"}],
        "user_id": "str",
        "user_notices": "<map>",
    }


async def test_the_rule_list_names_every_hint_that_can_fire(world: World) -> None:
    await world.ready()
    names = [r["name"] for r in (await report(world))["rules"]]
    assert names == [rule.name for rule in beta.RULES]
    assert len(set(names)) == len(names)
    review = {r["name"] for r in (await report(world))["rules"] if r["needs_review"]}
    assert review == {
        "closed_by_checkin_after_contacts_messaged",
        "voided_by_operator_after_contacts_messaged",
        "closed_by_account_deletion_after_contacts_messaged",
        "opened_within_24h_of_hold_exit",
        "hold_overlapped_incident",
        "complaint_received",
    }


async def test_an_empty_system_reports_zeros_and_says_so(world: World) -> None:
    document = await report(world)
    assert document["escalated_incidents"] == []
    review = document["review"]
    assert (review["escalated_incidents"], review["needs_human_review"]) == (0, 0)
    assert review["incident_ids"] == []
    assert review["still_open_with_contacts_messaged"] == 0
    assert document["coverage"]["oldest_notification_at"] is None
    text_form = beta.format_text(document)
    assert "none in this period" in text_form
    assert "0 NEED HUMAN REVIEW" in text_form
    assert "STILL OPEN  0 still open with contacts messaged" in text_form
    assert "oldest message still held: none on record" in text_form
    assert "== Rules that fired ==" not in text_form


# --- the text form ----------------------------------------------------------------------------


async def test_the_text_form_shows_the_review_and_the_timeline(world: World) -> None:
    built = await seeded_scenario(world)
    form = beta.format_text(await report(world))
    assert form.startswith("AfterMe closed-beta report\n")
    assert "3 escalated incident(s) listed, 3 NEED HUMAN REVIEW" in form
    assert f"INCIDENT {built.incident['safe']}   *** NEEDS HUMAN REVIEW ***" in form
    assert f"INCIDENT {built.incident['quiet']}" not in form
    assert "contact-1" in form
    assert "185.0  contacts_messaged" in form
    assert "== Rules that fired ==" in form
    assert "closed_by_checkin_after_contacts_messaged [review]" in form
    assert "delivery_failed_to_a_contact [context]" in form


# --- the command line -------------------------------------------------------------------------


@pytest.fixture
def operator_cli(
    world: World, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> Any:
    """``cli.admin.run`` connected to the world's database as the worker role."""
    monkeypatch.setattr(cli, "load_settings", lambda: world.h.settings)
    monkeypatch.setattr(cli, "configure_logging", lambda _settings: None)
    monkeypatch.setattr(cli, "build_worker_services", lambda _settings: world.engine.services)

    async def run(*argv: str) -> tuple[int, str]:
        capsys.readouterr()
        code = await cli.run(list(argv))
        return code, capsys.readouterr().out

    return run


async def test_the_command_prints_text_by_default_and_json_on_request(
    world: World, operator_cli: Any
) -> None:
    built = await seeded_scenario(world)

    code, out = await operator_cli("beta-report")
    assert code == 0
    assert out.startswith("AfterMe closed-beta report\n")
    assert built.incident["safe"] in out

    code, out = await operator_cli("beta-report", "--json")
    assert code == 0
    document = json.loads(out)
    assert document["schema_version"] == 1
    assert document["review"]["needs_human_review"] == 3

    code, out = await operator_cli(
        "beta-report", "--since", "2026-10-10", "--until", "2026-10-31", "--json"
    )
    assert code == 0
    assert [b["listed_because"] for b in json.loads(out)["escalated_incidents"]] == [
        ["still_open"]  # the alarm that has not been resolved is always on the page
    ]
    assert json.loads(out)["period"]["since"] == "2026-10-10"


@pytest.mark.parametrize(
    "argv",
    [
        ["beta-report", "--since", "2026-10-10", "--until", "2026-10-09"],
        ["beta-report", "--since", "20261009"],
        ["beta-report", "--until", "2026-13-01"],
        ["beta-report", "--since", "yesterday"],
    ],
)
async def test_a_bad_period_is_refused_before_anything_is_read(
    argv: list[str], operator_cli: Any
) -> None:
    with pytest.raises(SystemExit) as stopped:
        await operator_cli(*argv)
    assert stopped.value.code == 2


# --- privacy ----------------------------------------------------------------------------------

NAME = "Quentin Aldersgate"
HOLD_NOTE = "operator-note-needle-4471"
CONTACT_PHONE = "+14155550123"
OWN_PHONE = "+919812345678"


async def _private_world(world: World) -> tuple[Person, list[str]]:
    """A person with a name, a phone, two contacts with names, addresses and phones, an
    instruction with a title and a body released to the second one, a Hold with a note, and an
    incident that ran to the release being read and then I'M SAFE. Returns what must never be
    printed."""
    person = await world.person("quentin.aldersgate@example.com", premium=True)
    world.db.execute(
        "UPDATE user_profiles SET display_name = %s, phone_e164 = %s WHERE user_id = %s",
        (NAME, OWN_PHONE, person.user_id),
    )
    await world.contact(person, "Hortensia", phone_e164=CONTACT_PHONE)
    await world.contact(person, "Barnaby")
    await world.plan(person, [(180, ["Hortensia"]), (1440, ["Barnaby"])])
    await world.login(person)
    assert (await world.h.reauth(person.tokens)).status_code == 204
    plan = await world.h.client.get("/v1/plan", headers=person.headers)
    made = await world.h.client.post(
        "/v1/instructions",
        json={
            "category": "home",
            "title": TITLE,
            "body": BODY,
            "recipients": [
                {
                    "contact_id": person.contacts["Barnaby"],
                    "release_stage_id": plan.json()["stages"][1]["id"],
                }
            ],
        },
        headers=person.headers,
    )
    assert made.status_code == 201, made.text
    await world.activate(person)

    await admin.hold_enter(world.engine.services, operator="alex", reason=HOLD_NOTE)
    await admin.hold_exit(world.engine.services, operator="alex")
    await world.tick()

    await world.advance_to(DUE + timedelta(minutes=1440 + 6))
    assert len(world.mail.to(address(person, "Barnaby"), "contact_alert_with_release")) == 1
    portal = Portal(world)
    shown = await portal.reach_content(person, "Barnaby")
    assert TITLE in shown.text  # the contact really did read it
    incident_id = str(world.open_incident(person)["id"])  # type: ignore[index]
    await world.safe(person, incident_id)
    await world.tick()

    tokens = sorted(set(re.findall(r"#((?:rt|ci|oo)_[A-Za-z0-9_.-]+)", _all_mail(world))))
    assert any(t.startswith("rt_") for t in tokens)  # the release link
    forbidden = [
        person.email,
        "quentin",
        "aldersgate",
        OWN_PHONE,
        "hortensia",
        "barnaby",
        address(person, "Hortensia"),
        address(person, "Barnaby"),
        CONTACT_PHONE,
        TITLE,
        BODY,
        "mrs. sharma",
        "spare key",
        HOLD_NOTE,
        "alex",  # the operator's name is not part of a report
        *tokens,
    ]
    return person, forbidden


def _all_mail(world: World) -> str:
    return "\n".join(m.text for m in world.mail.messages)


def _assert_private(output: str, forbidden: list[str]) -> None:
    lowered = output.lower()
    for needle in forbidden:
        assert needle.lower() not in lowered, f"{needle!r} leaked into the report"
    assert "@" not in output, "an email address"
    assert not re.search(r"\b(?:rt|ci|oo|wt|pr)_[A-Za-z0-9_-]{8,}", output), "a token"
    assert not re.search(r"\+\d{7,}", output), "a phone number"


async def test_neither_format_contains_a_name_an_address_a_token_or_instruction_text(
    world: World, operator_cli: Any
) -> None:
    person, forbidden = await _private_world(world)
    assert len(forbidden) > 15  # the list really holds what was seeded
    document = await report(world)
    [item] = document["escalated_incidents"]
    # the report is not empty: it is about this very incident, and says what it needs to
    assert item["user_id"] == person.user_id
    assert item["releases"]["created"] == 1
    assert item["releases"]["viewed"] == 1
    assert item["releases"]["revoked"] == 1  # I'M SAFE took it back
    assert "released_and_viewed" in item["hints"]
    assert "closed_by_checkin_after_contacts_messaged" in item["hints"]
    assert [c["label"] for c in item["contacts"]] == ["contact-1", "contact-2"]
    releases = document["metrics"]["releases"]
    assert (releases["created"], releases["viewed"], releases["revoked"]) == (1, 1, 1)
    assert releases["revoked_by_reason"]["user_safe"] == 1

    _assert_private(beta.format_text(document), forbidden)
    _assert_private(json.dumps(document, indent=2), forbidden)

    # ... and through the command, in both formats
    code, text_out = await operator_cli("beta-report")
    assert code == 0
    _assert_private(text_out, forbidden)
    code, json_out = await operator_cli("beta-report", "--json")
    assert code == 0
    _assert_private(json_out, forbidden)
    assert "contact-2" in text_out


@pytest.mark.no_db
def test_unexpected_text_in_a_code_column_is_not_passed_on() -> None:
    assert beta._label("incident_resolved") == "incident_resolved"
    assert beta._label("push_token_invalid") == "push_token_invalid"
    for odd in ("someone@example.com", "Jane Doe", "", "x" * 65, "a;drop table"):
        assert beta._label(odd) == "other"
    assert beta._label(None) == "other"


# --- read-only --------------------------------------------------------------------------------


async def test_the_command_changes_no_application_row(world: World, operator_cli: Any) -> None:
    await seeded_scenario(world)
    before = _digest(world)
    assert before["audit_logs"].split(":")[0] != "0"  # the digest sees real rows

    for argv in (
        ("beta-report",),
        ("beta-report", "--json"),
        ("beta-report", "--since", "2026-10-09", "--until", "2026-10-09"),
    ):
        code, out = await operator_cli(*argv)
        assert code == 0
        assert out

    assert _digest(world) == before  # not even an audit row: a read is not an event


async def test_the_report_runs_in_a_transaction_the_database_will_not_let_write(
    world: World,
) -> None:
    async with beta.read_only_session(world.engine.services) as session:
        assert (await session.execute(text("SHOW transaction_read_only"))).scalar_one() == "on"
        level = (await session.execute(text("SHOW transaction_isolation"))).scalar_one()
        assert level == "repeatable read"
        with pytest.raises(DBAPIError, match="read-only transaction"):
            await session.execute(
                text(
                    "INSERT INTO service_heartbeats (service, instance_id, last_beat_at, "
                    "started_at, version) VALUES ('x', 'y', now(), now(), '0')"
                )
            )


# --- the rules, one at a time -----------------------------------------------------------------

ORIGIN = datetime(2026, 10, 9, 14, 30, tzinfo=UTC)
MESSAGED = ORIGIN + timedelta(minutes=185)
INCIDENT = uuid.UUID(int=1)
OWNER = uuid.UUID(int=2)
STAGE = uuid.UUID(int=3)


def _incident(**changes: Any) -> beta.IncidentRow:
    values: dict[str, Any] = {
        "id": INCIDENT,
        "user_id": OWNER,
        "status": "escalated",
        "closed_by": None,
        "missed_due_at": ORIGIN,
        "opened_at": ORIGIN,
        "contacts_messaged_at": MESSAGED,
        "closed_at": None,
        "positions": {STAGE: 1},
    }
    values.update(changes)
    return beta.IncidentRow(**values)


def _message(n: int = 1, **changes: Any) -> beta.MessageRow:
    values: dict[str, Any] = {
        "id": uuid.UUID(int=100 + n),
        "audience": "contact",
        "category": "contact_escalation",
        "contact_id": uuid.UUID(int=200 + n),
        "template_key": "contact_alert",
        "channel": "email",
        "status": "sent",
        "cancelled_reason": None,
        "attempts": 1,
        "provider": "resend",
        "created_at": ORIGIN + timedelta(minutes=180, seconds=n),
        "sent_at": MESSAGED,
    }
    values.update(changes)
    return beta.MessageRow(**values)


def _log(message: beta.MessageRow, outcome: str, **changes: Any) -> beta.LogRow:
    values: dict[str, Any] = {
        "notification_id": message.id,
        "outcome": outcome,
        "provider": "resend",
        "error_code": None,
        "via_webhook": False,
        "attempted_at": MESSAGED,
    }
    values.update(changes)
    return beta.LogRow(**values)


def _action(**changes: Any) -> beta.ActionRow:
    values: dict[str, Any] = {
        "kind": "execute_stage",
        "variant": None,
        "step_id": STAGE,
        "scheduled_for": ORIGIN + timedelta(minutes=180),
        "original_scheduled_for": ORIGIN + timedelta(minutes=180),
        "status": "executed",
        "executed_at": ORIGIN + timedelta(minutes=180),
        "outcome": {"targets": [{"contact_id": str(uuid.UUID(int=201)), "result": "messaged"}]},
    }
    values.update(changes)
    return beta.ActionRow(**values)


def _hold(ended: datetime | None, *, started: datetime | None = None) -> beta.HoldRow:
    began = started or (ended - timedelta(hours=1) if ended else ORIGIN)
    return beta.HoldRow(
        id=uuid.UUID(int=300),
        reason="operator",
        started_at=began,
        detected_at=began,
        ended_at=ended,
        exit_processed_at=ended,
    )


def _block(
    incident: beta.IncidentRow | None = None,
    *,
    actions: list[beta.ActionRow] | None = None,
    messages: list[beta.MessageRow] | None = None,
    logs: dict[uuid.UUID, list[beta.LogRow]] | None = None,
    releases: list[beta.ReleaseRow] | None = None,
    holds: list[beta.HoldRow] | None = None,
    now: datetime = NOW,
    fallback: str | None = None,
) -> dict[str, Any]:
    return beta.incident_block(
        incident or _incident(),
        [_action()] if actions is None else actions,
        [_message()] if messages is None else messages,
        logs or {},
        releases or [],
        holds or [],
        now=now,
        fallback_provider=fallback,
    )


pure = pytest.mark.no_db


@pure
def test_a_plain_open_escalation_raises_no_hint() -> None:
    item = _block()
    assert item["hints"] == []
    assert item["needs_human_review"] is False
    assert item["review_reasons"] == []


@pure
@pytest.mark.parametrize(
    ("closed_by", "hint"),
    [
        ("user_checkin", "closed_by_checkin_after_contacts_messaged"),
        ("user_safe", "closed_by_checkin_after_contacts_messaged"),
        ("operator_void", "voided_by_operator_after_contacts_messaged"),
        ("account_deleted", "closed_by_account_deletion_after_contacts_messaged"),
    ],
)
def test_every_way_an_escalated_incident_can_end_is_a_review_candidate(
    closed_by: str, hint: str
) -> None:
    item = _block(
        _incident(status="resolved", closed_by=closed_by, closed_at=MESSAGED + timedelta(hours=1))
    )
    assert item["hints"] == [hint]
    assert item["needs_human_review"] is True
    assert item["review_reasons"] == [hint]


@pure
def test_the_hold_exit_window_is_24_hours_after_the_end_and_not_before_it() -> None:
    ended = ORIGIN - timedelta(hours=24)  # exactly a day before the incident opened
    assert "opened_within_24h_of_hold_exit" not in _block(holds=[_hold(ended)])["hints"]
    ended = ORIGIN - timedelta(hours=23, minutes=59)
    item = _block(holds=[_hold(ended)])
    assert item["hints"] == ["opened_within_24h_of_hold_exit"]
    assert item["needs_human_review"] is True
    # opened while the Hold was active (its window is backdated to the last good probe)
    ended = ORIGIN + timedelta(minutes=1)
    assert _block(holds=[_hold(ended)])["hints"] == ["opened_within_24h_of_hold_exit"]
    ongoing = _hold(None, started=ORIGIN - timedelta(hours=2))
    assert _block(holds=[ongoing])["hints"] == ["opened_within_24h_of_hold_exit"]
    # a Hold that started after the incident opened is the other rule, below


@pure
def test_a_hold_between_the_missed_deadline_and_the_first_message_is_a_review_candidate() -> None:
    during = _hold(MESSAGED - timedelta(minutes=30))  # opened before it, shifted by it
    item = _block(holds=[during])
    assert item["hints"] == ["hold_overlapped_incident"]
    assert item["needs_human_review"] is True
    # not one that ended before the deadline (and more than 24 h before it opened) ...
    before = _hold(ORIGIN - timedelta(hours=30))
    assert _block(holds=[before])["hints"] == []
    # ... nor one that started only after contacts were told
    after = _hold(MESSAGED + timedelta(hours=3))
    assert _block(holds=[after])["hints"] == []
    # an open incident: the Hold counts up to now
    running = _hold(None, started=ORIGIN + timedelta(minutes=60))
    assert _block(holds=[running])["hints"] == ["hold_overlapped_incident"]


@pure
def test_a_resolution_after_more_than_24_hours_is_late_but_not_a_review_candidate() -> None:
    closed = MESSAGED + timedelta(hours=24)
    on_time = _block(_incident(status="resolved", closed_by="user_safe", closed_at=closed))
    assert "late_resolution_over_24h" not in on_time["hints"]
    late = _block(
        _incident(status="resolved", closed_by="user_safe", closed_at=closed + timedelta(minutes=1))
    )
    assert "late_resolution_over_24h" in late["hints"]
    assert late["minutes_from_first_contact_message_to_resolution"] == 1441.0


@pure
def test_an_incident_still_open_after_a_day_says_so() -> None:
    assert "still_open_over_24h" not in _block(now=MESSAGED + timedelta(hours=24))["hints"]
    item = _block(now=MESSAGED + timedelta(hours=24, minutes=1))
    assert item["hints"] == ["still_open_over_24h"]
    assert item["needs_human_review"] is False  # context: open is not wrongful


@pure
def test_a_complaint_is_a_review_candidate() -> None:
    message = _message()
    item = _block(
        messages=[message],
        logs={
            message.id: [_log(message, "accepted"), _log(message, "complained", via_webhook=True)]
        },
    )
    assert item["hints"] == ["complaint_received"]
    assert item["needs_human_review"] is True
    assert item["contacts"][0]["outcome"] == "complained"


@pure
def test_a_release_that_was_viewed_is_context_for_the_reviewer() -> None:
    created = [beta.ReleaseRow(None, 0, None), beta.ReleaseRow(MESSAGED, 2, None)]
    item = _block(releases=created)
    assert item["hints"] == ["released_and_viewed"]
    assert item["releases"] == {"created": 2, "viewed": 1, "revoked": 0, "views": 2}
    assert item["needs_human_review"] is False
    assert "released_and_viewed" not in _block(releases=[beta.ReleaseRow(None, 0, None)])["hints"]


@pure
def test_a_shifted_stage_or_a_delay_notice_is_stage_delayed() -> None:
    shifted = _action(scheduled_for=ORIGIN + timedelta(minutes=240))
    assert "stage_delayed" in _block(actions=[shifted])["hints"]
    notice = _message(2, audience="user", category="user", template_key="incident_delayed")
    notice = beta.MessageRow(**{**notice.__dict__, "contact_id": None})
    item = _block(messages=[_message(), notice])
    assert "stage_delayed" in item["hints"]
    assert item["user_notices"] == {"incident_delayed": {"sent": 1}}


@pure
@pytest.mark.parametrize(
    ("status", "outcome"),
    [("failed", None), ("sent", "bounced"), ("sent", "rejected"), ("sent", "error")],
)
def test_a_message_that_did_not_reach_a_contact_is_a_delivery_failure(
    status: str, outcome: str | None
) -> None:
    message = _message(status=status)
    logs = {message.id: [_log(message, outcome, via_webhook=outcome == "error")]} if outcome else {}
    item = _block(messages=[message], logs=logs)
    assert item["hints"] == ["delivery_failed_to_a_contact"]
    assert item["contacts"][0]["outcome"] == ("failed" if outcome != "bounced" else "bounced")


@pure
def test_an_earlier_failed_attempt_that_was_then_accepted_is_not_a_failure() -> None:
    message = _message(attempts=2)
    logs = {message.id: [_log(message, "error"), _log(message, "accepted")]}
    item = _block(messages=[message], logs=logs)
    assert item["hints"] == []
    assert item["contacts"][0]["outcome"] == "sent"


@pure
def test_the_fallback_provider_is_noticed_by_name_and_by_a_message_that_changed_provider() -> None:
    by_name = _message(provider="postmark")
    assert _block(messages=[by_name], fallback="postmark")["hints"] == ["provider_fallback_used"]
    assert _block(messages=[by_name], fallback="smtp")["hints"] == []
    assert _block(messages=[by_name], fallback=None)["hints"] == []

    message = _message()
    switched = {
        message.id: [
            _log(message, "error", provider="resend"),
            _log(message, "accepted", provider="postmark"),
        ]
    }
    assert _block(messages=[message], logs=switched)["hints"] == ["provider_fallback_used"]
    # a webhook names the provider that sent the message: it is not a second provider
    reported = {
        message.id: [_log(message, "accepted"), _log(message, "delivered", via_webhook=True)]
    }
    assert _block(messages=[message], logs=reported)["hints"] == []


@pure
def test_a_skipped_contact_and_a_held_action_are_noticed() -> None:
    skipped = _action(
        outcome={
            "targets": [
                {"contact_id": str(uuid.UUID(int=201)), "result": "messaged"},
                {"contact_id": str(uuid.UUID(int=202)), "result": "skipped", "reason": "opted_out"},
            ]
        }
    )
    assert _block(actions=[skipped])["hints"] == ["contact_skipped"]
    held = _action(status="held", executed_at=None, outcome={"held_by_gate": "G7"})
    item = _block(actions=[held])
    assert item["hints"] == ["action_held"]
    assert item["actions"] == {"executed": 0, "pending": 0, "cancelled": 0, "held": 1}


@pure
def test_contacts_are_numbered_in_the_order_they_were_first_messaged() -> None:
    second = _message(1, created_at=ORIGIN + timedelta(minutes=181))
    first = _message(2, created_at=ORIGIN + timedelta(minutes=180))
    never_sent = _message(
        3,
        status="cancelled",
        attempts=0,
        sent_at=None,
        cancelled_reason="incident_resolved",
        created_at=ORIGIN + timedelta(minutes=182),
    )
    item = _block(messages=[second, first, never_sent])
    assert [(c["label"], c["contact_id"]) for c in item["contacts"]] == [
        ("contact-1", str(first.contact_id)),
        ("contact-2", str(second.contact_id)),
        ("contact-3", str(never_sent.contact_id)),
    ]
    assert [c["outcome"] for c in item["contacts"]] == ["sent", "sent", "cancelled"]
    assert item["contacts_messaged"] == 2  # the third was never handed to a provider
    assert item["contacts"][2]["messages"][0]["cancelled_reason"] == "incident_resolved"


@pure
def test_a_contacts_outcome_is_the_most_notable_of_their_messages() -> None:
    delivered = _message(1, contact_id=uuid.UUID(int=201))
    failed = _message(2, contact_id=uuid.UUID(int=201), status="failed")
    item = _block(messages=[delivered, failed], logs={delivered.id: [_log(delivered, "delivered")]})
    [contact] = item["contacts"]
    assert contact["outcome"] == "failed"
    assert [m["delivery"] for m in contact["messages"]] == ["delivered", None]


@pure
def test_a_period_is_whole_utc_days() -> None:
    period = beta.Period(date(2026, 10, 1), date(2026, 10, 31))
    assert period.start == datetime(2026, 10, 1, tzinfo=UTC)
    assert period.end == datetime(2026, 11, 1, tzinfo=UTC)
    open_ended = beta.Period()
    assert (open_ended.start, open_ended.end) == (None, None)
    assert beta.Period(until=date.max).end is None  # no day after the last one


# --- Phase 10 review: BETA-1 ... BETA-5 ---------------------------------------------------------


async def _long_grace(world: World) -> tuple[Person, str]:
    """A 48 hour grace: the incident opens on the 9th and reaches a contact on the 11th."""
    person = await world.ready("slow.person@example.com", stages=((2880, ("Mom",)),))
    await world.advance_to(DUE + timedelta(minutes=2880 + 10))  # 11 Oct, 14:40Z
    incident = world.open_incident(person)
    assert incident is not None
    assert incident["opened_at"] == DUE
    assert incident["contacts_messaged_at"] == DUE + timedelta(minutes=2880 + 5)
    return person, str(incident["id"])


async def test_an_incident_is_listed_for_the_day_its_contacts_were_first_messaged(
    world: World,
) -> None:
    """BETA-1. Opened on the 9th, messaged on the 11th: ``--since`` the 10th or 11th must find
    it, though it did not open in that period; and a period that ends before the message does
    not list it, though the incident opened inside it."""
    _, incident_id = await _long_grace(world)

    found = await report(world, since=date(2026, 10, 11))
    [item] = found["escalated_incidents"]
    assert item["incident_id"] == incident_id
    assert item["listed_because"] == ["contacts_first_messaged_in_period", "still_open"]
    assert found["metrics"]["incidents"]["opened"] == 0  # opened counts are by the day it opened
    assert found["metrics"]["incidents"]["contacts_messaged"] == 1  # this one by the message
    assert found["review"]["escalated_incidents"] == 1

    mid = await report(world, since=date(2026, 10, 10), until=date(2026, 10, 10))
    assert mid["escalated_incidents"] == []  # nobody was told on the 10th
    assert mid["metrics"]["incidents"]["opened"] == 0

    # the reverse: opened inside the period, contacts reached after its end
    early = await report(world, since=date(2026, 10, 9), until=date(2026, 10, 10))
    assert early["metrics"]["incidents"]["opened"] == 1
    assert early["metrics"]["incidents"]["contacts_messaged"] == 0
    assert early["escalated_incidents"] == []
    # ... but the alarm is active now, and the header says so
    assert early["review"]["still_open_with_contacts_messaged"] == 1
    assert early["review"]["still_open_incident_ids"] == [incident_id]
    assert "STILL OPEN  1 still open with contacts messaged" in beta.format_text(early)


async def test_an_incident_closed_in_the_period_is_listed_though_it_was_messaged_before(
    world: World,
) -> None:
    person, incident_id = await _long_grace(world)
    await world.advance_to(datetime(2026, 10, 12, 9, 0, tzinfo=UTC))
    await world.safe(person, incident_id)
    await world.tick()

    closed_day = await report(world, since=date(2026, 10, 12), until=date(2026, 10, 12))
    [item] = closed_day["escalated_incidents"]
    assert item["incident_id"] == incident_id
    assert item["listed_because"] == ["closed_in_period"]
    assert "closed_by_checkin_after_contacts_messaged" in item["hints"]
    assert closed_day["review"]["needs_human_review"] == 1
    assert closed_day["review"]["still_open_with_contacts_messaged"] == 0

    between = await report(world, since=date(2026, 10, 9), until=date(2026, 10, 10))
    assert between["escalated_incidents"] == []


async def test_the_header_cannot_read_zero_while_an_alarm_is_active(world: World) -> None:
    """BETA-5."""
    _, incident_id = await _long_grace(world)
    far_future = await report(world, since=date(2026, 12, 1))
    assert far_future["review"]["needs_human_review"] == 0  # nothing flagged by a rule ...
    assert far_future["review"]["still_open_with_contacts_messaged"] == 1  # ... but not quiet
    form = beta.format_text(far_future)
    assert "STILL OPEN  1 still open with contacts messaged: review when they close" in form
    assert incident_id in form.split("== Metrics")[0]  # in the header, not only in a block


async def test_the_report_says_which_database_it_read(world: World) -> None:
    """BETA-4."""
    await world.ready()
    document = await report(world)
    source = document["source"]
    assert source["database"] == TEST_DB
    assert source["role"] == "afterme_worker"
    assert source["environment"] == "test"
    assert source["schema_at_head"] is True
    assert source["alembic_revision"] == ", ".join(sorted(beta.code_heads()))
    form = beta.format_text(document)
    assert f"database {TEST_DB} as role afterme_worker" in form
    assert f"revision {source['alembic_revision']}" in form


async def test_a_database_that_is_behind_or_incomplete_is_refused_not_reported(
    world: World, monkeypatch: pytest.MonkeyPatch
) -> None:
    services = world.engine.services
    with pytest.raises(beta.SchemaMismatch) as behind:
        await beta.beta_report(services, heads=frozenset({"0001"}))
    assert TEST_DB in str(behind.value)
    assert "revision" in str(behind.value)
    assert "alembic upgrade head" in str(behind.value)

    monkeypatch.setattr(beta, "ALL_TABLES", (*beta.ALL_TABLES, "no_such_table"))
    with pytest.raises(beta.SchemaMismatch) as missing:
        await beta.beta_report(services)
    assert "no_such_table" in str(missing.value)
    assert "missing 1 table" in str(missing.value)


async def test_the_command_refuses_with_exit_2_and_prints_no_report(
    world: World,
    operator_cli: Any,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(beta, "code_heads", lambda: frozenset({"0001"}))
    code = await cli.run(["beta-report", "--json"])
    captured = capsys.readouterr()
    assert code == 2
    assert captured.out == ""
    assert captured.err.startswith("refused: database ")
    assert "alembic upgrade head" in captured.err


async def test_the_report_says_how_much_evidence_is_left(world: World) -> None:
    """BETA-3: a quiet report must not be mistaken for a complete one."""
    built = await seeded_scenario(world)
    first = world.db.execute("SELECT min(created_at) AS t FROM notifications").fetchone()
    assert first is not None
    for _ in range(2):  # two accounts were purged since: their incidents went with them
        world.db.execute(
            "INSERT INTO audit_logs (occurred_at, actor_type, subject_user_id, action, "
            "resource_type) VALUES (%s, 'system', gen_random_uuid(), 'account.purged', 'account')",
            (world.clock.current,),
        )
    document = await report(world, since=date(2026, 1, 1))
    coverage = document["coverage"]
    oldest = first["t"].astimezone(UTC).isoformat()
    assert coverage["oldest_notification_at"] == oldest
    assert coverage["notification_retention_days"] == 90
    assert coverage["accounts_purged_in_period"] == 2
    assert coverage["period_starts_before_oldest_notification"] is True
    form = beta.format_text(document)
    assert f"oldest message still held: {oldest}" in form
    assert "accounts purged in the period: 2" in form
    assert "the period starts before the oldest message held" in form

    recent = await report(world, since=date(2026, 10, 10))
    assert recent["coverage"]["period_starts_before_oldest_notification"] is False
    assert recent["coverage"]["accounts_purged_in_period"] == 0  # they went on the 9th
    assert built.incident["quiet"] not in [b["incident_id"] for b in recent["escalated_incidents"]]
