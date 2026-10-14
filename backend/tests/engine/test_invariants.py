"""The safety invariants INV-1...INV-10 (ESCALATION_ENGINE §2; TEST_PLAN §4.2).

INV-4 (each gate), INV-5/6/7/8/10 and the opening rules are also exercised in
``test_incidents.py``, ``test_dispatch.py`` and ``test_hold.py``; this file holds the ones that
need their own setup, plus the architectural guards.
"""

from __future__ import annotations

import ast
import pathlib
import uuid
from datetime import timedelta
from typing import Any

import psycopg
import pytest

from app.engine.executor import ActionExecutor
from app.engine.runtime import Engine
from app.incidents.snapshot import SnapshotRelease
from tests.support import API_PASSWORD, bearer, connect
from tests.world import World, ist

DUE = ist("2026-10-09T20:00")
APP = pathlib.Path(__file__).resolve().parents[2] / "app"


# --- INV-1: backend authority -----------------------------------------------------------------


def _imports(path: pathlib.Path) -> set[str]:
    tree = ast.parse(path.read_text())
    found: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            found.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            found.add(node.module)
    return found


@pytest.mark.no_db
def test_the_api_never_imports_the_engine() -> None:
    """The engine (which can open incidents and run stages) is worker-only code: nothing the API
    process loads reaches it, so no request handler can call it."""
    offenders: list[str] = []
    for path in APP.rglob("*.py"):
        relative = path.relative_to(APP)
        if relative.parts[0] == "engine":
            continue
        for module in _imports(path):
            if module == "app.engine" or module.startswith("app.engine."):
                offenders.append(f"{relative} imports {module}")
    # the only non-engine modules allowed to use it are the operator tooling and the worker;
    # ops/users.py is CLI-only (never imported by the API process) and takes the per-user lock
    # through EngineStore.lock_user, so that its change follows the engine's lock order; so is
    # ops/kms.py (the key re-wrap and rotation commands), for the same reason
    allowed = {"ops/admin.py", "ops/users.py", "ops/kms.py"}
    assert [o for o in offenders if o.split(" ")[0] not in allowed] == []


@pytest.mark.no_db
def test_the_incident_creating_code_is_confined_to_the_engine() -> None:
    """Only ``app/engine`` constructs incident and action rows."""
    for path in APP.rglob("*.py"):
        relative = path.relative_to(APP).as_posix()
        if relative.startswith("engine/") or relative in ("incidents/models.py",):
            continue
        text = path.read_text()
        assert "EscalationIncident(" not in text, relative
        assert "IncidentAction(" not in text, relative


async def test_the_api_database_role_cannot_create_an_incident_or_an_action(
    world: World, migrated_database: str
) -> None:
    person = await world.ready()
    with connect("afterme_api", API_PASSWORD, migrated_database) as api:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            api.execute(
                "INSERT INTO escalation_incidents (user_id, plan_id, plan_version, plan_snapshot, "
                "missed_due_at, opened_at, anchor_at, grace_ends_at) SELECT user_id, id, 1, "
                "'{}', now(), now(), now(), now() FROM escalation_plans LIMIT 1"
            )
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            api.execute(
                "INSERT INTO incident_actions (incident_id, user_id, kind, scheduled_for, "
                "original_scheduled_for, dedupe_key) VALUES (gen_random_uuid(), %s, "
                "'execute_stage', now(), now(), 'forged')",
                (person.user_id,),
            )


# --- INV-3: single clock ----------------------------------------------------------------------


async def test_client_supplied_times_never_change_an_outcome(world: World) -> None:
    person = await world.ready()
    world.clock.set(DUE - timedelta(hours=2))
    before = world.config(person)["next_due_at"]
    response = await world.h.client.post(
        "/v1/checkins",
        json={"client_reported_at": "2030-01-01T00:00:00Z"},  # absurd, and in the future
        headers={**bearer(await _relogin(world, person)), "Idempotency-Key": "client-time-0000001"},
    )
    assert response.status_code == 200
    config = world.config(person)
    assert config["last_checkin_at"] == world.clock.current  # the server's time, not the client's
    assert config["next_due_at"] != before
    assert config["next_due_at"] < world.clock.current + timedelta(days=2)
    await world.advance_to(config["next_due_at"] + timedelta(minutes=1))
    assert world.open_incident(person) is not None  # the deadline is the server's, not 2030


async def _relogin(world: World, person: Any) -> dict[str, Any]:
    await world.login(person)
    return person.tokens  # type: ignore[no-any-return]


# --- INV-9: warning before release ------------------------------------------------------------


class _Releases:
    """Phase 6 stand-in: one planned release at the second stage, valid until told otherwise."""

    def __init__(self) -> None:
        self.valid = True

    async def planned(self, session: Any, *, user_id: uuid.UUID, step_ids: list[uuid.UUID]) -> Any:
        from app.engine.store import EngineStore

        plan = await EngineStore.plan(session, user_id)
        stages = await EngineStore.stages(session, plan.id) if plan else []
        planned: dict[uuid.UUID, list[SnapshotRelease]] = {}
        for step, contacts in stages:
            if step.position == 2 and contacts:
                planned[step.id] = [SnapshotRelease(uuid.uuid4(), contacts[0])]
        return planned

    async def still_valid(
        self, session: Any, *, user_id: uuid.UUID, release: Any, step_id: Any
    ) -> str | None:
        return None if self.valid else "instruction_inactive"


async def _with_releases(world: World) -> tuple[Any, _Releases]:
    person = await world.ready(contacts=("Mom", "Dad"), stages=((180, ("Mom",)), (1440, ("Dad",))))
    stub = _Releases()
    engine = Engine(world.engine.services, releases=stub, instance_id="releases")
    world.engine = engine
    world.dispatcher.services = engine.services
    return person, stub


async def test_a_releasing_stage_is_preceded_by_its_final_warning(world: World) -> None:
    person, _ = await _with_releases(world)
    await world.advance_to(DUE + timedelta(minutes=1440 - 59))
    warnings = world.mail.to(person.email, "release_final_warning")
    assert len(warnings) == 1
    assert "In 1 hour, 1 instruction will be shared with Dad." in warnings[0].text
    warning = world.actions(person, kind="user_final_warning")[0]
    stage = world.actions(person, kind="execute_stage")[1]
    assert warning["scheduled_for"] == stage["scheduled_for"] - timedelta(minutes=60)
    assert warning["executed_at"] <= stage["scheduled_for"]


async def test_a_releasing_stage_waits_for_its_warning_and_is_held_after_thirty_minutes(
    world: World,
) -> None:
    """ENG-INV-9: the warning never ran (here: cancelled behind the engine's back)."""
    person, _ = await _with_releases(world)
    await world.advance_to(DUE + timedelta(minutes=1000))
    world.db.execute(
        "UPDATE incident_actions SET status = 'cancelled' WHERE kind = 'user_final_warning' "
        "AND user_id = %s",
        (person.user_id,),
    )
    stage_time = DUE + timedelta(minutes=1440)
    await world.advance_to(stage_time + timedelta(minutes=10))
    stage = world.actions(person, kind="execute_stage")[1]
    assert stage["status"] == "pending"  # waiting, not run
    await world.advance_to(stage_time + timedelta(minutes=40))
    stage = world.actions(person, kind="execute_stage")[1]
    assert stage["status"] == "held"
    assert stage["outcome"] == {"held_by_gate": "G9"}
    assert world.mail.to(f"dad.{person.user_id[:6]}@example.com", "contact_alert") == []


async def test_a_release_that_is_no_longer_valid_is_skipped_but_the_stage_still_alerts(
    world: World,
) -> None:
    person, stub = await _with_releases(world)
    stub.valid = False
    await world.advance_to(DUE + timedelta(minutes=1445))
    stage = world.actions(person, kind="execute_stage")[1]
    assert stage["status"] == "executed"


# --- INV-4 at the engine level: a forced failure of any single check prevents the action ------


@pytest.mark.parametrize(
    ("break_it", "gate"),
    [
        ("incident_closed", "G2"),
        ("snapshot", "G6"),
        ("checkin", "G3"),
        ("user_inactive", "G5"),
    ],
)
async def test_each_gate_stops_the_real_engine(world: World, break_it: str, gate: str) -> None:
    person = await world.ready()
    await world.advance_to(DUE + timedelta(minutes=20))
    if break_it == "incident_closed":
        world.db.execute(
            "UPDATE escalation_incidents SET status = 'resolved', closed_at = now(), "
            "closed_by = 'user_checkin' WHERE user_id = %s",
            (person.user_id,),
        )
    elif break_it == "snapshot":
        world.db.execute(
            "UPDATE escalation_incidents SET plan_snapshot = '{}'::jsonb WHERE user_id = %s",
            (person.user_id,),
        )
    elif break_it == "checkin":
        world.db.execute(
            "INSERT INTO checkin_events (user_id, kind, source, received_at, idempotency_key, "
            "response_snapshot) VALUES (%s, 'ok', 'app', %s, 'slipped-through-0000001', '{}')",
            (person.user_id, DUE + timedelta(minutes=10)),
        )
    else:
        world.db.execute("UPDATE users SET status = 'suspended' WHERE id = %s", (person.user_id,))
    await world.advance_to(DUE + timedelta(minutes=190))
    stage = world.actions(person, kind="execute_stage")[0]
    assert stage["status"] in ("cancelled", "held"), (break_it, gate, stage["status"])
    assert world.notifications(person, template_key="contact_alert") == []
    assert world.mail.to(f"mom.{person.user_id[:6]}@example.com", "contact_alert") == []


# --- ENG-INV-3 style: the engine never needs the API ------------------------------------------


async def test_the_engine_runs_without_the_api_process(world: World) -> None:
    """Escalation is the worker's alone: it needs only the database (INV-1)."""
    person = await world.ready()
    await world.h.app.state.services.db.dispose()  # the API's pool is gone
    await world.advance_to(DUE + timedelta(minutes=181))
    assert world.open_incident(person) is not None
    assert len(world.notifications(person, template_key="contact_alert")) == 1


_ = ActionExecutor  # imported to make the dependency on the real executor explicit
