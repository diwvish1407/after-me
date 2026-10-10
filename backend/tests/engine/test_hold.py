"""System Hold, the circuit breaker (ESCALATION_ENGINE §7; TEST_PLAN ENG-INV-10, ENG-FS-09/10/13).

Probe monitoring is enabled by configuring a probe token; each test moves the frozen clock and
inserts probe rows the way the external monitor's requests would.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta
from typing import Any

import pytest

from app.ops import admin
from tests.support import bearer
from tests.world import Person, World, ist

TOKEN = "p" * 48
DUE = ist("2026-10-09T20:00")
STAGE_1 = DUE + timedelta(minutes=180)
MONITORED = pytest.mark.settings(probe_token=TOKEN)


def probe(world: World, at: datetime) -> None:
    world.db.execute(
        "INSERT INTO ingestion_probes (received_at, source) VALUES (%s, 'monitor')", (at,)
    )


def probes(world: World, start: datetime, end: datetime, every: timedelta) -> None:
    at = start
    while at <= end:
        probe(world, at)
        at += every


def holds(world: World) -> list[dict[str, Any]]:
    return [
        dict(r)
        for r in world.db.execute("SELECT * FROM system_holds ORDER BY started_at").fetchall()
    ]


def alert_address(person: Person) -> str:
    return f"mom.{person.user_id[:6]}@example.com"


async def _ready(world: World) -> Person:
    """A monitored system whose probes have been healthy for a while."""
    person = await world.ready()
    probes(world, world.clock.current, STAGE_1 + timedelta(minutes=5), timedelta(minutes=1))
    return person


# --- the probe endpoint -----------------------------------------------------------------------


@MONITORED
async def test_the_probe_records_a_row_and_needs_the_secret(world: World) -> None:
    client = world.h.client
    assert (await client.post("/internal/probe")).status_code == 401
    wrong = await client.post("/internal/probe", headers={"X-Probe-Token": "q" * 48})
    assert wrong.status_code == 401
    ok = await client.post(
        "/internal/probe", headers={"X-Probe-Token": TOKEN, "X-Probe-Source": "uptime-robot"}
    )
    assert ok.status_code == 204
    row = world.db.execute("SELECT * FROM ingestion_probes").fetchall()
    assert [r["source"] for r in row] == ["uptime-robot"]
    assert row[0]["received_at"] == world.clock.current


async def test_the_probe_does_not_exist_without_a_configured_token(world: World) -> None:
    response = await world.h.client.post("/internal/probe", headers={"X-Probe-Token": TOKEN})
    assert response.status_code == 404
    assert world.db.execute("SELECT count(*) AS n FROM ingestion_probes").fetchone()["n"] == 0


@MONITORED
async def test_the_probe_is_rate_limited(world: World) -> None:
    client = world.h.client
    codes = [
        (await client.post("/internal/probe", headers={"X-Probe-Token": TOKEN})).status_code
        for _ in range(11)
    ]
    assert codes[:10] == [204] * 10
    assert codes[10] == 429


# --- starting a Hold --------------------------------------------------------------------------


@MONITORED
async def test_stale_probes_start_a_hold_backdated_to_the_last_good_probe(world: World) -> None:
    person = await world.ready()
    last_good = world.clock.current
    probe(world, last_good)
    world.clock.set(last_good + timedelta(minutes=2))
    report = await world.tick()
    assert report.hold.entered == []  # still within INGESTION_STALE (3 minutes)
    assert holds(world) == []

    world.clock.set(last_good + timedelta(minutes=4))
    report = await world.tick()
    assert report.hold.entered == ["ingestion"]
    (hold,) = holds(world)
    assert hold["reason"] == "ingestion"
    assert hold["started_at"] == last_good  # backdated
    assert hold["detected_at"] == last_good + timedelta(minutes=4)
    assert hold["ended_at"] is None
    audit = world.db.execute(
        "SELECT * FROM audit_logs WHERE action = 'system.hold_entered'"
    ).fetchall()
    assert len(audit) == 1
    assert audit[0]["subject_user_id"] is None
    assert person.user_id not in str(audit)


@MONITORED
async def test_no_incident_opens_and_no_stage_runs_during_hold(world: World) -> None:
    """INV-10."""
    person = await world.ready()
    probes(world, world.clock.current, DUE - timedelta(minutes=10), timedelta(minutes=1))
    await world.advance_to(DUE + timedelta(minutes=30))  # probes stopped 40 minutes ago
    assert holds(world)
    assert holds(world)[0]["ended_at"] is None
    assert world.incidents(person) == []
    assert world.config(person)["status"] == "active"


# --- ending a Hold: rollback and shift --------------------------------------------------------


@MONITORED
async def test_a_stage_that_ran_in_an_undetected_outage_is_rolled_back_and_shifted(
    world: World,
) -> None:
    """ENG-FS-09: the incident was already open; probes stop just before stage 1; the worker
    does not notice for three minutes, so the stage runs, but its message is still inside the
    settle delay when the Hold is detected (backdated) and nothing leaves the system."""
    person = await world.ready()
    probes(world, world.clock.current, STAGE_1 - timedelta(minutes=1), timedelta(minutes=1))
    await world.advance_to(STAGE_1 + timedelta(seconds=30))  # the stage runs unnoticed
    stage = world.actions(person, kind="execute_stage")[0]
    assert stage["status"] == "executed"
    assert world.open_incident(person)["status"] == "escalated"  # type: ignore[index]

    await world.advance_to(STAGE_1 + timedelta(minutes=4))  # detected, backdated
    (hold,) = holds(world)
    assert hold["started_at"] == STAGE_1 - timedelta(minutes=1)
    # the contact message is queued but may not leave while the Hold is on
    await world.advance_to(STAGE_1 + timedelta(minutes=20))
    assert world.mail.to(alert_address(person), "contact_alert") == []

    # probes come back and stay fresh for 10 minutes: the Hold ends and is processed
    probes(
        world,
        STAGE_1 + timedelta(minutes=21),
        STAGE_1 + timedelta(minutes=33),
        timedelta(minutes=1),
    )
    await world.advance_to(STAGE_1 + timedelta(minutes=33))
    (hold,) = holds(world)
    assert hold["ended_at"] is not None
    assert hold["exit_processed_at"] is not None

    stage = world.actions(person, kind="execute_stage")[0]
    window = hold["ended_at"] - hold["started_at"]
    assert stage["status"] == "pending"  # rolled back: nobody saw it
    assert stage["scheduled_for"] == stage["original_scheduled_for"] + window + timedelta(
        minutes=30
    )
    assert world.open_incident(person)["status"] == "grace"  # type: ignore[index]
    alert = world.notifications(person, template_key="contact_alert")[0]
    assert (alert["status"], alert["cancelled_reason"]) == ("cancelled", "hold_rollback")
    assert world.mail.to(alert_address(person), "contact_alert") == []
    assert len(world.mail.to(person.email, "service_interruption")) == 1  # the user is told

    # later the stage runs once more, normally, and then Mom is emailed
    probes(
        world,
        STAGE_1 + timedelta(minutes=34),
        stage["scheduled_for"] + timedelta(minutes=10),
        timedelta(minutes=1),
    )
    await world.advance_to(stage["scheduled_for"] + timedelta(minutes=6))
    assert len(world.mail.to(alert_address(person), "contact_alert")) == 1


@MONITORED
async def test_a_message_already_handed_to_a_provider_is_not_rolled_back(world: World) -> None:
    person = await world.ready()
    probes(world, world.clock.current, STAGE_1 + timedelta(minutes=6), timedelta(minutes=1))
    await world.advance_to(STAGE_1 + timedelta(minutes=6))  # stage ran and Mom was emailed
    assert len(world.mail.to(alert_address(person), "contact_alert")) == 1
    # a Hold whose window (wrongly, late) covers the stage: delivered effects stay
    world.db.execute(
        "INSERT INTO system_holds (reason, started_at, detected_at, ended_at, created_by) "
        "VALUES ('operator', %s, %s, %s, 'test')",
        (
            STAGE_1 - timedelta(minutes=1),
            STAGE_1 + timedelta(minutes=7),
            STAGE_1 + timedelta(minutes=8),
        ),
    )
    probes(
        world, STAGE_1 + timedelta(minutes=7), STAGE_1 + timedelta(minutes=20), timedelta(minutes=1)
    )
    await world.advance_to(STAGE_1 + timedelta(minutes=10))
    assert world.actions(person, kind="execute_stage")[0]["status"] == "executed"
    assert len(world.mail.to(alert_address(person), "contact_alert")) == 1  # no second message
    assert holds(world)[0]["exit_processed_at"] is not None


@MONITORED
async def test_the_shift_preserves_the_spacing_of_later_stages(world: World) -> None:
    person = await world.ready(
        contacts=("Mom", "Dad"), stages=((180, ("Mom",)), (1440, ("Dad",)), (2880, ("Mom",)))
    )
    probes(world, world.clock.current, DUE + timedelta(minutes=60), timedelta(minutes=1))
    await world.advance_to(DUE + timedelta(minutes=60))
    before = {a["step_id"]: a["scheduled_for"] for a in world.actions(person, kind="execute_stage")}
    world.db.execute(
        "INSERT INTO system_holds (reason, started_at, detected_at, ended_at, created_by) "
        "VALUES ('operator', %s, %s, %s, 'test')",
        (DUE + timedelta(minutes=10), DUE + timedelta(minutes=11), DUE + timedelta(minutes=70)),
    )
    probes(world, DUE + timedelta(minutes=61), DUE + timedelta(minutes=75), timedelta(minutes=1))
    await world.advance_to(DUE + timedelta(minutes=75))
    shift = timedelta(minutes=60) + timedelta(minutes=30)
    after = {a["step_id"]: a["scheduled_for"] for a in world.actions(person, kind="execute_stage")}
    assert {k: after[k] - before[k] for k in before} == dict.fromkeys(before, shift)


@MONITORED
async def test_exit_processing_never_shifts_twice(world: World) -> None:
    person = await world.ready()
    probes(world, world.clock.current, DUE + timedelta(minutes=30), timedelta(minutes=1))
    await world.advance_to(DUE + timedelta(minutes=30))
    world.db.execute(
        "INSERT INTO system_holds (reason, started_at, detected_at, ended_at, created_by) "
        "VALUES ('operator', %s, %s, %s, 'test')",
        (DUE + timedelta(minutes=10), DUE + timedelta(minutes=11), DUE + timedelta(minutes=40)),
    )
    probes(world, DUE + timedelta(minutes=31), DUE + timedelta(minutes=60), timedelta(minutes=1))
    await world.advance_to(DUE + timedelta(minutes=45))
    once = world.actions(person, kind="execute_stage")[0]["scheduled_for"]
    # a crash left the Hold marked unprocessed: processing again must be a no-op for this user
    world.db.execute("UPDATE system_holds SET exit_processed_at = NULL")
    await world.advance_to(DUE + timedelta(minutes=50))
    assert world.actions(person, kind="execute_stage")[0]["scheduled_for"] == once
    assert holds(world)[0]["exit_processed_at"] is not None
    assert len(world.mail.to(person.email, "service_interruption")) == 1


@MONITORED
async def test_all_clears_still_go_out_during_hold(world: World) -> None:
    """INV-10: all-clears and OTPs reduce harm, so Hold does not stop them."""
    person = await world.ready()
    probes(world, world.clock.current, STAGE_1 + timedelta(minutes=6), timedelta(minutes=1))
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    incident_id = str(world.open_incident(person)["id"])  # type: ignore[index]
    world.db.execute(
        "INSERT INTO system_holds (reason, started_at, detected_at, created_by) "
        "VALUES ('operator', now(), now(), 'test')"
    )
    await world.safe(person, incident_id)
    await world.tick()
    assert len(world.mail.to(alert_address(person), "contact_all_clear")) == 1


# --- history found after the fact -------------------------------------------------------------


@MONITORED
async def test_a_gap_in_the_probe_history_is_recorded_when_the_worker_was_down(
    world: World,
) -> None:
    """ENG-FS-10: the worker (and the database) were down; the probes show the outage."""
    person = await world.ready()
    start = world.clock.current
    probes(world, start, start + timedelta(minutes=10), timedelta(minutes=1))
    probes(
        world, start + timedelta(minutes=40), start + timedelta(minutes=55), timedelta(minutes=1)
    )
    world.clock.set(start + timedelta(minutes=56))
    report = await world.tick()
    assert report.hold.windows_recorded == 1
    (window,) = holds(world)
    assert window["started_at"] == start + timedelta(minutes=10)
    assert window["ended_at"] == start + timedelta(minutes=40)
    assert window["exit_processed_at"] is not None
    # scanning again finds nothing new
    await world.tick()
    assert len(holds(world)) == 1
    assert person.user_id  # the window exists independently of any user


# --- anomaly and operator ---------------------------------------------------------------------


@pytest.mark.settings(anomaly_floor_per_hour=3, probe_token=TOKEN)
async def test_a_burst_of_incidents_starts_an_anomaly_hold_that_only_a_person_can_end(
    world: World,
) -> None:
    """ENG-FS-13: a bad release stops check-ins and everyone misses the deadline at once."""
    people = [await world.ready(f"user{i}@example.com") for i in range(5)]
    probes(world, world.clock.current, DUE + timedelta(hours=6), timedelta(minutes=1))
    await world.advance_to(DUE + timedelta(seconds=5))
    report = await world.tick()  # evaluates the count of incidents opened in the last hour
    assert "anomaly" in report.hold.entered or any(h["reason"] == "anomaly" for h in holds(world))
    anomaly = next(h for h in holds(world) if h["reason"] == "anomaly")
    assert anomaly["ended_at"] is None

    await world.advance_to(DUE + timedelta(hours=4))  # healthy probes do not end an anomaly Hold
    assert next(h for h in holds(world) if h["reason"] == "anomaly")["ended_at"] is None
    for person in people:
        assert world.mail.to(alert_address(person), "contact_alert") == []

    ended = await admin.hold_exit(world.engine.services, operator="alex")
    assert ended == 1
    await world.tick()
    done = next(h for h in holds(world) if h["reason"] == "anomaly")
    assert done["ended_at"] is not None
    assert done["exit_processed_at"] is not None
    audit = world.db.execute(
        "SELECT * FROM audit_logs WHERE action = 'operator.hold_exit'"
    ).fetchall()
    assert audit[0]["actor_type"] == "operator"
    assert audit[0]["metadata"]["operator"] == "alex"


async def test_an_operator_can_hold_and_release_the_system(world: World) -> None:
    person = await world.ready()
    hold_id = await admin.hold_enter(
        world.engine.services, operator="alex", reason="provider incident, investigating"
    )
    assert isinstance(hold_id, uuid.UUID)
    await world.advance_to(DUE + timedelta(minutes=30))
    assert world.incidents(person) == []
    status = await admin.engine_status(world.engine.services)
    assert status.hold_active is True
    assert status.hold_reasons == ["operator"]
    assert "hold active" in status.pages

    assert await admin.hold_exit(world.engine.services, operator="alex") == 1
    await world.tick()
    incident = world.open_incident(person)
    assert incident is not None
    assert incident["opened_at"] >= DUE + timedelta(minutes=30)  # a full grace from now
    status = await admin.engine_status(world.engine.services)
    assert status.hold_active is False
    assert "hold active" not in status.pages


async def test_an_operator_can_void_an_incident_after_a_confirmed_fault(world: World) -> None:
    person = await world.ready()
    await world.advance_to(STAGE_1 + timedelta(minutes=6))
    incident_id = world.open_incident(person)["id"]  # type: ignore[index]
    assert len(world.mail.to(alert_address(person), "contact_alert")) == 1
    assert await admin.void_incident(
        world.engine.services, operator="alex", incident_id=incident_id
    )
    await world.tick()
    row = world.incidents(person)[0]
    assert (row["status"], row["closed_by"]) == ("voided", "operator_void")
    assert len(world.mail.to(alert_address(person), "contact_all_clear")) == 1
    assert (
        await admin.void_incident(world.engine.services, operator="alex", incident_id=incident_id)
        is False
    )  # already closed


async def test_status_reports_what_would_page(world: World) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(seconds=5))
    healthy = await admin.engine_status(world.engine.services)
    assert healthy.pages == []
    assert healthy.incidents_open == 1
    assert healthy.worker_heartbeat_age_seconds is not None
    # a held action pages
    world.db.execute(
        "UPDATE incident_actions SET status = 'held' WHERE kind = 'execute_stage' AND user_id = %s",
        (person.user_id,),
    )
    assert "held actions" in (await admin.engine_status(world.engine.services)).pages
    # a worker that has not ticked for a while pages
    world.clock.set(world.clock.current + timedelta(minutes=5))
    assert (
        "worker heartbeat older than 2 minutes"
        in (await admin.engine_status(world.engine.services)).pages
    )


_ = bearer  # imported for symmetry with the other engine tests
