"""The hot paths stay indexed (TEST_PLAN §9; backend/tests/perf/PLANS.md).

A small seed (2,000 people with the shape of ``scripts/perf.py``'s 100,000) and the real
application code: a check-in and its replay, Home in three states, the activity feed, an engine
tick that opens an incident, the dispatcher, the Hold monitor, the retention purges and the
operator commands run while a :class:`Recorder` keeps every distinct SQL statement with its
parameters. Each is then explained with ``enable_seqscan = off``: a Seq Scan that is still in
the plan has no index it could have used. A change that drops an index, or writes a query the
indexes cannot serve, fails here instead of in production at 100,000 users.

The round-trip budgets pin what ``GET /v1/home`` and ``POST /v1/checkins`` cost in statements.
"""

from __future__ import annotations

from dataclasses import replace
from datetime import UTC, timedelta
from typing import Any

import psycopg
import pytest
from perf_support import seed
from perf_support.engine_phases import queue_messages
from perf_support.plans import Recorder, explain
from pydantic import SecretStr

from app.api.container import build_services
from app.core.clock import FrozenClock
from app.engine.hold import HoldMonitor
from app.maintenance import retention
from app.ops import admin, beta
from tests.support import OWNER_PASSWORD, OWNER_URL, TEST_DB, conninfo
from tests.world import World

pytestmark = pytest.mark.perf

USERS = 2_000
# Tables a statement may scan whole, because they hold a handful of rows by design.
SMALL = frozenset(
    {
        "instruction_categories",
        "system_flags",
        "system_holds",
        "service_heartbeats",
        "alembic_version",
    }
)
# Scans that are accepted, each with the reason (path prefix, table). An entry nothing needs any
# more fails the test: the list must shrink, never rot.
KNOWN: dict[tuple[str, str], str] = {
    ("operator:", "*"): "on-demand operator reports and status: read a period or the whole table",
    ("engine tick", "checkin_configurations"): (
        "Hold's count of active people, only when a burst exceeds the floor (15 ms at 100,000)"
    ),
    ("retention", "sessions"): "least(revoked, expiries) is an expression; bounded by people",
    ("retention", "auth_tokens"): "least(used, expires) is an expression; bounded by people",
    ("retention", "contact_verifications"): "expired invitations: a handful of rows",
    ("retention", "portal_otp_challenges"): "expired codes: a handful of rows",
    ("retention", "portal_sessions"): "expired portal sessions: a handful of rows",
    ("retention", "portal_tokens"): "expired portal links: a handful of rows",
}

# The plan of these statements must use these indexes: "an index is used" is not enough (an
# index on another column can serve a scan that still reads every due action of every person).
# (path prefix, text the statement contains, index the plan must contain)
EXPECT: tuple[tuple[str, str, str], ...] = (
    ("GET /v1/home", "escalation_steps.user_id =", "ix_escalation_steps_user"),
    (
        "engine tick",
        "incident_actions.user_id = %(user_id_1)s::UUID AND incident_actions.status",
        "ix_incident_actions_user_pending",
    ),
    ("Hold: anomaly thresholds", "LEFT JOIN escalation_incidents i", "ix_incidents_opened"),
    (
        "engine tick",
        "status = %(status_1)s::VARCHAR AND notifications.updated_at <",
        "ix_notifications_sending",
    ),
    (
        "retention",
        "FROM notifications WHERE notifications.created_at <",
        "ix_notifications_finished",
    ),
    (
        "retention",
        "FROM checkin_events WHERE checkin_events.received_at <",
        "ix_checkin_events_received_at",
    ),
    ("retention", "FROM audit_logs WHERE audit_logs.occurred_at <", "ix_audit_occurred"),
)
# Parents that retention (or the account purge) deletes one row at a time, and the children that
# reference them with ON DELETE SET NULL / CASCADE: PostgreSQL finds the child rows with the
# child's own index, and scans the whole child table when there is none.
FK_PARENTS = ("sessions", "devices", "refresh_tokens", "incident_actions")
FK_NO_INDEX: dict[tuple[str, str], str] = {
    ("release_events", "action_id"): "released instructions: a few rows per incident",
}

# Statements per request (the API's own connection + the bookkeeping connection used by the
# rate limiter and the last-used touch). Changing these on purpose means changing the numbers.
HOME_BUDGET = 16
CHECKIN_BUDGET = 22
CHECKIN_REPLAY_BUDGET = 8


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


async def _drive(world: World, layout: seed.Layout, rec: Recorder, owner: Any) -> dict[str, int]:
    """Run the paths; returns the statements each request issued."""
    h = world.h
    services = h.app.state.services
    rec.attach(services.db.engine, "api")
    rec.attach(services.db.bookkeeping_engine, "api-bookkeeping")
    worker = world.engine.services
    rec.attach(worker.db.engine, "worker")
    rec.attach(worker.db.bookkeeping_engine, "worker-bookkeeping")

    plain = list(layout.plain(5))
    users = [
        (seed.user_id(i), seed.session_id(i))
        for i in (*plain, layout.grace[0], layout.escalated[0])
    ]
    token = {
        u: services.tokens.issue(user_id=u, session_id=s, now=h.clock.current).token
        for u, s in users
    }
    active, other, grace, escalated = (
        token[users[0][0]],
        token[users[1][0]],
        token[users[-2][0]],
        token[users[-1][0]],
    )
    trips: dict[str, int] = {}

    async def request(name: str, method: str, path: str, bearer: str, **headers: str) -> None:
        rec.path = name
        before = rec.count()
        response = await h.client.request(method, path, headers={**_bearer(bearer), **headers})
        assert response.status_code == 200, (name, response.status_code, response.text)
        trips[name] = rec.count() - before

    await request(
        "POST /v1/checkins",
        "POST",
        "/v1/checkins",
        active,
        **{"Idempotency-Key": "perf-key-0000000001"},
    )
    await request(
        "POST /v1/checkins (replay)",
        "POST",
        "/v1/checkins",
        active,
        **{"Idempotency-Key": "perf-key-0000000001"},
    )
    await request("GET /v1/home", "GET", "/v1/home", other)
    await request("GET /v1/home (grace)", "GET", "/v1/home", grace)
    await request("GET /v1/home (escalated)", "GET", "/v1/home", escalated)
    await request("GET /v1/activity", "GET", "/v1/activity", other)
    await request("GET /v1/checkins", "GET", "/v1/checkins?limit=20", other)

    # the engine: five people miss their deadline; open, execute, remind; then the dispatcher
    due = [seed.user_id(i) for i in layout.plain(5, from_top=True)]
    owner.execute(
        "UPDATE checkin_configurations SET next_due_at = %s, baseline_at = %s "
        "WHERE user_id = ANY(%s)",
        (h.clock.current - timedelta(minutes=1), h.clock.current - timedelta(seconds=1), due),
    )
    rec.path = "engine tick"
    await world.tick()
    rec.path = "engine tick (executes)"
    await world.tick()
    rec.path = "dispatcher"
    queue_messages(owner, layout, 60, "plans")
    await world.dispatch()
    rec.path = "Hold: ingestion monitor"
    owner.execute("INSERT INTO ingestion_probes (source) VALUES ('perf')")
    probing = HoldMonitor(
        replace(
            world.engine.services,
            settings=world.engine.settings.model_copy(update={"probe_token": SecretStr("p" * 48)}),
        )
    )
    now = h.clock.current
    await probing.evaluate(now)
    await probing.evaluate(now)
    rec.path = "Hold: anomaly thresholds"
    async with worker.db.sessionmaker() as session:
        await probing._active_users(session)
        await probing._has_history(session, now)
        await probing._same_hour_baseline(session, now)
    rec.path = "operator: status"
    await admin.engine_status(worker)
    rec.path = "operator: beta-report"
    await beta.beta_report(worker)
    # retention: everything is "now" in the future, so every rule has something to delete. It
    # runs as the owner here: the purge role (afterme_maintenance) cannot log in in development,
    # and the worker role is not granted DELETE on these tables.
    rec.path = "retention"
    purger = build_services(h.settings, clock=h.clock, database_url=OWNER_URL)
    rec.attach(purger.db.engine, "maintenance")
    try:
        async with purger.db.sessionmaker() as session, session.begin():
            await retention.purge_all(session, now=now + timedelta(days=500))
    finally:
        await purger.db.dispose()
    return trips


async def test_the_hot_paths_use_indexes_and_stay_within_their_round_trips(
    world: World, clock: FrozenClock, owner_db: Any
) -> None:
    owner = psycopg.connect(conninfo("afterme_owner", OWNER_PASSWORD, TEST_DB), autocommit=True)
    try:
        layout = seed.seed(
            conninfo("afterme_owner", OWNER_PASSWORD, TEST_DB), USERS, lambda _t: None
        )
        row = owner.execute("SELECT now()").fetchone()
        assert row is not None
        clock.set(row[0].astimezone(UTC) + timedelta(seconds=1))
        rec = Recorder()
        trips = await _drive(world, layout, rec, owner)

        owner.execute("ANALYZE")
        offenders: list[str] = []
        used: set[tuple[str, str]] = set()
        for captured in rec.statements.values():
            plan = explain(owner, captured, analyze=False, seqscan=False)
            assert plan.error is None, (captured.label, plan.error)
            for table in plan.seq_scans:
                if table in SMALL:
                    continue
                accepted = next(
                    (
                        key
                        for key in KNOWN
                        if captured.path.startswith(key[0]) and key[1] in ("*", table)
                    ),
                    None,
                )
                if accepted is not None:
                    used.add(accepted)
                    continue
                where = " ".join(captured.statement.split())
                where = where[where.find(" FROM ") :][:230]
                offenders.append(f"{captured.path}: {captured.label} -> Seq Scan on {table}{where}")
        missing_expected: list[str] = []
        for prefix, needle, index in EXPECT:
            plans = [
                explain(owner, c, analyze=False, seqscan=False)
                for c in rec.statements.values()
                if c.path.startswith(prefix) and needle in " ".join(c.statement.split())
            ]
            if not any(index in p.indexes for p in plans):
                seen = [(p.captured.path, p.indexes, p.error, p.text[:1500]) for p in plans]
                missing_expected.append(f"{prefix} / {needle!r}: {index} (plans: {seen})")
        assert not missing_expected, "not used:\n" + "\n".join(missing_expected)
        unindexed = _unindexed_foreign_keys(owner)
        assert not unindexed, "foreign keys without an index on the child column:\n" + "\n".join(
            unindexed
        )
        assert not offenders, "no index serves:\n" + "\n".join(sorted(set(offenders)))
        assert set(KNOWN) == used, f"stale entries in KNOWN: {set(KNOWN) - used}"
    finally:
        owner.close()

    assert len(rec.statements) > 40, "the paths did not run"
    assert trips["GET /v1/home"] <= HOME_BUDGET, trips
    assert trips["GET /v1/home (escalated)"] <= HOME_BUDGET + 6, trips
    assert trips["POST /v1/checkins"] <= CHECKIN_BUDGET, trips
    assert trips["POST /v1/checkins (replay)"] <= CHECKIN_REPLAY_BUDGET, trips


def _unindexed_foreign_keys(owner: psycopg.Connection[Any]) -> list[str]:
    rows = owner.execute(
        """
        SELECT c.conrelid::regclass::text, a.attname, c.confrelid::regclass::text
          FROM pg_constraint c
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
         WHERE c.contype = 'f' AND c.confrelid::regclass::text = ANY(%s)
           AND NOT EXISTS (
                 SELECT 1 FROM pg_index i
                  WHERE i.indrelid = c.conrelid AND i.indkey[0] = c.conkey[1]
                    AND (i.indpred IS NULL
                         OR pg_get_expr(i.indpred, i.indrelid)
                            = '(' || a.attname || ' IS NOT NULL)'))
        """,
        (list(FK_PARENTS),),
    ).fetchall()
    return [
        f"{table}.{column} -> {parent}"
        for table, column, parent in rows
        if (table, column) not in FK_NO_INDEX
    ]
