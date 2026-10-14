"""The ``plans`` phase: run the hot paths of the application and explain every statement."""

from __future__ import annotations

import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field, replace
from datetime import datetime
from pathlib import Path
from typing import Any

import httpx
import psycopg
from pydantic import SecretStr

from perf_support import seed
from perf_support.engine_phases import LatencyEmailProvider, LatencyPushProvider, queue_messages
from perf_support.plans import Plan, Recorder, explain, markdown, table_rows
from perf_support.report import Check
from perf_support.stack import PerfStack

from app.api.container import build_services, build_worker_services  # isort: skip
from app.engine.dispatcher import Dispatcher  # isort: skip
from app.engine.hold import HoldMonitor  # isort: skip
from app.engine.runtime import Engine, TickReport  # isort: skip
from app.main import create_app  # isort: skip
from app.maintenance import retention  # isort: skip
from app.ops import admin, beta  # isort: skip

Say = Callable[[str], None]
BIG_TABLE_ROWS = 5_000  # a Seq Scan on a table at least this large is a finding


@dataclass
class RoundTrips:
    request: str
    main: int
    bookkeeping: int
    ms: float


@dataclass
class PlanRun:
    plans: list[Plan] = field(default_factory=list)
    trips: list[RoundTrips] = field(default_factory=list)
    retention: dict[str, dict[str, float]] = field(default_factory=dict)
    sizes: dict[str, int] = field(default_factory=dict)


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


async def _api(
    stack: PerfStack, layout: seed.Layout, rec: Recorder, run: PlanRun, say: Say
) -> None:
    app = create_app(stack.settings())
    services = app.state.services
    rec.attach(services.db.engine, "api")
    rec.attach(services.db.bookkeeping_engine, "api-bookkeeping")
    plain = layout.plain(10)
    tokens = stack.mint(
        [
            (seed.user_id(i), seed.session_id(i))
            for i in (*plain, layout.grace[0], layout.escalated[0])
        ]
    )
    active, replayer, grace, escalated = tokens[0], tokens[1], tokens[-2], tokens[-1]
    transport = httpx.ASGITransport(app=app, client=("127.0.0.1", 51000))
    key = f"plans-{uuid.uuid4().hex}"

    async def call(name: str, method: str, path: str, token: str, **kwargs: Any) -> None:
        rec.path = name
        for _ in range(2):  # the second call: warm caches, and the statements are the same
            before = dict(rec.per_engine)
            started = time.perf_counter()
            headers = {**_bearer(token), **kwargs.get("headers", {})}
            response = await client.request(method, path, headers=headers)
            elapsed = (time.perf_counter() - started) * 1000
            after = rec.per_engine
            assert response.status_code < 300, (name, response.status_code, response.text)  # noqa: PLR2004, S101
        run.trips.append(
            RoundTrips(
                name,
                after["api"] - before.get("api", 0),
                after["api-bookkeeping"] - before.get("api-bookkeeping", 0),
                elapsed,
            )
        )

    async with httpx.AsyncClient(transport=transport, base_url="http://perf.test") as client:
        rec.path = "POST /v1/checkins (first)"
        before = dict(rec.per_engine)
        response = await client.post(
            "/v1/checkins", headers={**_bearer(active), "Idempotency-Key": key}
        )
        assert response.status_code == 200, response.text  # noqa: PLR2004, S101
        run.trips.append(
            RoundTrips(
                "POST /v1/checkins (first)",
                rec.per_engine["api"] - before.get("api", 0),
                rec.per_engine["api-bookkeeping"] - before.get("api-bookkeeping", 0),
                0.0,
            )
        )
        rec.path = "POST /v1/checkins (replay)"
        before = dict(rec.per_engine)
        response = await client.post(
            "/v1/checkins", headers={**_bearer(active), "Idempotency-Key": key}
        )
        assert response.headers.get("idempotent-replayed") == "true"  # noqa: S101
        run.trips.append(
            RoundTrips(
                "POST /v1/checkins (replay)",
                rec.per_engine["api"] - before.get("api", 0),
                rec.per_engine["api-bookkeeping"] - before.get("api-bookkeeping", 0),
                0.0,
            )
        )
        await call("GET /v1/home (active)", "GET", "/v1/home", replayer)
        await call("GET /v1/home (grace)", "GET", "/v1/home", grace)
        await call("GET /v1/home (escalated)", "GET", "/v1/home", escalated)
        await call("GET /v1/activity", "GET", "/v1/activity", active)
        await call("GET /v1/checkins", "GET", "/v1/checkins?limit=20", active)
    await services.db.dispose()
    say(f"    API: {len(rec.statements)} distinct statements so far")


async def _worker(
    stack: PerfStack, layout: seed.Layout, owner: psycopg.Connection[Any], rec: Recorder, say: Say
) -> None:
    settings = stack.settings()
    services = build_worker_services(settings)
    rec.attach(services.db.engine, "worker")
    rec.attach(services.db.bookkeeping_engine, "worker-bookkeeping")
    engine = Engine(services, instance_id="perf-plans")
    numbers = layout.plain(30, from_top=True)
    owner.execute(
        "UPDATE checkin_configurations SET next_due_at = now() - interval '1 minute', "
        "baseline_at = now() - interval '1 second', reminder_lead_minutes = 60 "
        "WHERE user_id = ANY(%s)",
        ([seed.user_id(i) for i in list(numbers)[:20]],),
    )
    owner.execute(
        "UPDATE checkin_configurations SET next_due_at = now() + interval '30 minutes' "
        "WHERE user_id = ANY(%s)",
        ([seed.user_id(i) for i in list(numbers)[20:]],),
    )
    report = TickReport()
    now = datetime.now().astimezone()
    rec.path = "tick: heartbeat + Hold evaluation"
    await engine.hold.evaluate(now)
    rec.path = "tick: open due incidents"
    await engine.open_due_incidents(now, report)
    rec.path = "tick: execute due actions"
    await engine.execute_due_actions(datetime.now().astimezone(), report)
    rec.path = "tick: pre-deadline reminders"
    await engine.enqueue_pre_deadline_reminders(datetime.now().astimezone(), report)
    say(
        f"    engine: opened {report.opened}, executed {report.executed}, "
        f"reminders {report.pre_reminders}"
    )

    # the Hold monitor as it runs where an external monitor is configured (probes on)
    probing = settings.model_copy(update={"probe_token": SecretStr("p" * 48)})
    owner.execute("INSERT INTO ingestion_probes (source) VALUES ('perf')")
    monitor = HoldMonitor(replace(services, settings=probing))
    for round_ in ("first (no watermark)", "next"):
        rec.path = f"Hold: ingestion monitor, {round_}"
        await monitor.evaluate(datetime.now().astimezone())
    rec.path = "Hold: anomaly thresholds"
    now = datetime.now().astimezone()
    async with services.db.sessionmaker() as session:
        await monitor._active_users(session)
        await monitor._has_history(session, now)
        await monitor._same_hour_baseline(session, now)

    # the dispatcher: reminders to people and escalation alerts to contacts
    owner.execute("DELETE FROM notifications WHERE status IN ('queued', 'sending')")
    queue_messages(owner, layout, 200, f"plans{int(time.time())}")
    push = LatencyPushProvider(0, 0)
    email = LatencyEmailProvider(0, 0)
    dispatch_services = build_worker_services(settings, email_provider=email)
    rec.attach(dispatch_services.db.engine, "dispatcher")
    rec.attach(dispatch_services.db.bookkeeping_engine, "dispatcher-bookkeeping")
    dispatcher = Dispatcher(dispatch_services, push=push)
    rec.path = "dispatcher: one pass of 100"
    await dispatcher.dispatch()
    await dispatch_services.db.dispose()
    await services.db.dispose()


async def _operator(stack: PerfStack, rec: Recorder, say: Say) -> None:
    services = build_worker_services(stack.settings())
    rec.attach(services.db.engine, "operator")
    rec.path = "afterme-admin status"
    await admin.engine_status(services)
    rec.path = "afterme-admin beta-report"
    started = time.perf_counter()
    await beta.beta_report(services)
    say(f"    beta-report: {time.perf_counter() - started:.2f} s")
    await services.db.dispose()


async def _retention(stack: PerfStack, rec: Recorder, run: PlanRun, say: Say) -> None:
    """Every purge rule once, as the maintenance job runs them (as the owner here: the
    maintenance role cannot log in in development)."""
    settings = stack.settings()
    services = build_services(
        settings, database_url=settings.maintenance_database_url.get_secret_value()
    )
    rec.attach(services.db.engine, "maintenance")
    rules = (*retention.RULES, retention.audit_rule(settings.audit_retention_days))
    for rule in rules:
        rec.path = f"retention: {rule.name}"
        started = time.perf_counter()
        batches = 0
        removed = 0
        longest = 0.0
        # the same loop as ``retention.purge``, one batch (= one transaction) at a time, so the
        # time a batch holds its locks is visible
        failure: str | None = None
        for _ in range(retention.MAX_BATCHES):
            batch_started = time.perf_counter()
            try:
                async with services.db.sessionmaker() as session, session.begin():
                    now = await services.clock.now(session)
                    batch_started = time.perf_counter()
                    count = await _one_batch(session, rule, now)
                    longest = max(longest, time.perf_counter() - batch_started)
            except Exception as exc:  # a statement timeout is a finding, not a crash
                failure = type(exc).__name__
                longest = max(longest, time.perf_counter() - batch_started)
                break
            batches += 1
            removed += count
            if count < retention.BATCH:
                break
        run.retention[rule.name] = {
            "removed": removed,
            "batches": batches,
            "seconds": round(time.perf_counter() - started, 2),
            "longest_batch_s": round(longest, 3),
            "failed": failure,
        }
        say(
            f"      {rule.name:<24} removed {removed:>7,} in {batches:>2} batches, "
            f"longest batch {longest * 1000:6.0f} ms" + (f"  FAILED {failure}" if failure else "")
        )
    await services.db.dispose()


async def _one_batch(session: Any, rule: retention.Rule, now: datetime) -> int:
    from sqlalchemy import delete, select  # noqa: PLC0415

    cutoff = now - rule.keep
    model = rule.id_column.class_
    due = select(rule.id_column).where(rule.time_column < cutoff)
    guard = rule.guard(now) if callable(rule.guard) else rule.guard
    if guard is not None:
        due = due.where(guard)
    due = due.order_by(rule.time_column).limit(retention.BATCH)
    result = await session.execute(
        delete(model).where(rule.id_column.in_(due)).returning(rule.id_column)
    )
    return len(result.all())


async def collect_and_explain(
    stack: PerfStack,
    layout: seed.Layout,
    owner: psycopg.Connection[Any],
    say: Say,
    *,
    markdown_path: Path | None,
) -> tuple[Check, PlanRun]:
    rec = Recorder()
    run = PlanRun()
    say("    running the hot paths (API, engine, dispatcher, Hold, operator, retention)")
    await _api(stack, layout, rec, run, say)
    await _worker(stack, layout, owner, rec, say)
    await _operator(stack, rec, say)
    owner.execute("ANALYZE")
    # retention last: it deletes, and the other paths should see the full tables
    # (the statements are captured with their parameters first and explained afterwards)
    await _retention(stack, rec, run, say)
    run.sizes = table_rows(owner)
    say(f"    explaining {len(rec.statements)} distinct statements (EXPLAIN ANALYZE, BUFFERS)")
    owner.execute("ANALYZE")
    for captured in rec.statements.values():
        run.plans.append(explain(owner, captured, analyze=not captured.failed))
    big = sorted(
        {
            (p.captured.path, t)
            for p in run.plans
            for t in p.seq_scans
            if run.sizes.get(t, 0) >= BIG_TABLE_ROWS
        }
    )
    slowest = sorted(
        run.plans, key=lambda p: -(p.execution_ms if p.execution_ms == p.execution_ms else 0)
    )[:8]
    say("    slowest statements (execution ms):")
    for p in slowest:
        say(
            f"      {p.execution_ms:9.2f}  {p.captured.path}: {p.captured.label}  seq={p.seq_scans}"
        )
    say(f"    Seq Scans on tables of {BIG_TABLE_ROWS:,}+ rows: {big or 'none'}")
    for trip in run.trips:
        say(
            f"    round trips {trip.request:<32} main {trip.main:>2} + "
            f"bookkeeping {trip.bookkeeping}"
        )
    if markdown_path is not None:
        markdown_path.write_text(  # noqa: ASYNC240 - a file in a harness, once
            markdown(run.plans, run.sizes, full=True) + "\n"
        )
        say(f"    plans written to {markdown_path}")
    errors = [p for p in run.plans if p.error]
    check = Check(
        "PLANS",
        "EXPLAIN (ANALYZE, BUFFERS) of the hot paths",
        "informational: no Seq Scan on a large table",
        f"{len(run.plans)} statements; seq scans on large tables: {len(big)}; "
        f"slowest {slowest[0].execution_ms:.1f} ms; could not explain: {len(errors)}",
        None,
        {
            "statements": [
                {
                    "path": p.captured.path,
                    "statement": p.captured.label,
                    "calls": p.captured.calls,
                    "execution_ms": p.execution_ms,
                    "planning_ms": p.planning_ms,
                    "seq_scans": p.seq_scans,
                    "indexes": p.indexes,
                    "error": p.error,
                }
                for p in run.plans
            ],
            "round_trips": [t.__dict__ for t in run.trips],
            "retention": run.retention,
            "large_seq_scans": big,
        },
    )
    return check, run
