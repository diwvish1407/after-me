"""The engine tick and the Hold evaluation (in-process), PERF-03 (the dispatcher) and PERF-02
(10,000 users due in one minute, one real worker).

The tick and the dispatcher run in this process, as the ``afterme_worker`` role, against the
same throwaway database; the real worker process is used where the *loop* is what is measured
(PERF-02, and the loop's share of PERF-03).
"""

from __future__ import annotations

import asyncio
import math
import random
import time
import uuid
from collections import Counter
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from itertools import pairwise
from typing import Any

import psycopg
from sqlalchemy.ext.asyncio import AsyncSession

from perf_support import seed
from perf_support.db import HarnessError
from perf_support.load import percentile
from perf_support.report import Check
from perf_support.stack import PerfStack

from app.api.container import AppServices, build_worker_services  # isort: skip
from app.engine.dispatcher import BATCH as DISPATCH_BATCH  # isort: skip
from app.engine.dispatcher import CONCURRENCY as DISPATCH_CONCURRENCY  # isort: skip
from app.engine.dispatcher import Dispatcher  # isort: skip
from app.engine.hold import ANOMALY_WINDOW, HoldMonitor  # isort: skip
from app.engine.runtime import BATCH as TICK_BATCH  # isort: skip
from app.engine.runtime import MAX_PAGES, Engine, TickReport  # isort: skip
from app.engine.store import EngineStore  # isort: skip
from app.notifications.email import EmailMessage, ProviderResult  # isort: skip
from app.notifications.push import PushMessage  # isort: skip

PERF02_SECONDS = 120.0
PERF03_PER_SECOND = 50.0
PERF03_MESSAGES = 5_000
IDLE_SECONDS = 8.0
IDLE_AFTER = 3
IDLE_PASS_MS = 5

Say = Callable[[str], None]


# --------------------------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------------------------


def stats(values: list[float]) -> dict[str, float]:
    return {
        "n": len(values),
        "p50": round(percentile(values, 50), 2),
        "p95": round(percentile(values, 95), 2),
        "max": round(max(values), 2) if values else float("nan"),
    }


async def timed(
    services: AppServices, fn: Callable[[AsyncSession], Awaitable[Any]], repeat: int = 30
) -> dict[str, float]:
    """Wall time (ms) of ``fn`` in its own session, ``repeat`` times."""
    times: list[float] = []
    for _ in range(repeat):
        async with services.db.sessionmaker() as session:
            started = time.perf_counter()
            await fn(session)
            times.append((time.perf_counter() - started) * 1000)
    return stats(times)


def worker_services(stack: PerfStack, **kwargs: Any) -> AppServices:
    return build_worker_services(stack.settings(), **kwargs)


# --------------------------------------------------------------------------------------------
# the tick and the Hold evaluation
# --------------------------------------------------------------------------------------------


async def tick_phase(
    stack: PerfStack, layout: seed.Layout, say: Say
) -> tuple[Check, dict[str, Any]]:
    """The tick with ``users`` accounts: nobody is due, a few thousand are inside their reminder
    window. The first tick queues those reminders (a burst); the ones after it are the steady
    state, which is what runs every ``TICK_SECONDS`` for as long as the system lives."""
    services = worker_services(stack)
    engine = Engine(services, instance_id="perf-tick")
    try:
        say("    ticks (in process, as the worker role)")
        burst: list[float] = []
        reports: list[TickReport] = []
        for _ in range(6):
            started = time.perf_counter()
            report = await engine.tick()
            burst.append((time.perf_counter() - started) * 1000)
            reports.append(report)
            say(
                f"      tick {len(burst)}: {burst[-1]:8.0f} ms  "
                f"pre-reminders={report.pre_reminders} backlog={report.backlog} "
                f"errors={report.errors}"
            )
            if not report.backlog and report.pre_reminders == 0:
                break
        steady: list[float] = []
        for _ in range(15):
            started = time.perf_counter()
            report = await engine.tick()
            steady.append((time.perf_counter() - started) * 1000)
            assert report.errors == 0  # noqa: S101
        say(f"      steady: {stats(steady)}")

        now = datetime.now().astimezone()
        queries: dict[str, dict[str, float]] = {}

        async def probe(name: str, fn: Callable[[AsyncSession], Awaitable[Any]]) -> None:
            queries[name] = await timed(services, fn)
            say(f"      {name:<34} {queries[name]}")

        say("    the statements of the tick, one by one (ms)")
        await probe("due scan (open incidents)", lambda s: EngineStore.due_deadlines(s, now, 200))
        await probe(
            "due actions (users)", lambda s: EngineStore.users_with_due_actions(s, now, 200)
        )
        await probe("reminder candidates", lambda s: EngineStore.reminder_candidates(s, now, 200))
        await probe("open hold?", lambda s: EngineStore.open_hold(s))  # noqa: PLW0108
        monitor = HoldMonitor(services)

        async def evaluate(_s: AsyncSession) -> None:
            await monitor.evaluate(datetime.now().astimezone())

        await probe("Hold evaluation (whole step)", evaluate)
        await probe("  anomaly: incidents in the hour", lambda s: _recent(s, now))
        await probe("  anomaly: active users", lambda s: monitor._active_users(s))  # noqa: PLW0108
        await probe("  anomaly: has history?", lambda s: monitor._has_history(s, now))
        await probe("  anomaly: same-hour baseline", lambda s: monitor._same_hour_baseline(s, now))
    finally:
        await services.db.dispose()
    budget_ms = stack.tick_seconds * 1000 * 0.1
    detail = {
        "burst_ticks_ms": [round(v) for v in burst],
        "steady_ms": stats(steady),
        "statements_ms": queries,
        "budget_ms": budget_ms,
    }
    check = Check(
        "TICK",
        f"engine tick with {layout.users:,} users (nobody due)",
        f"informational: steady p95 < {budget_ms:.0f} ms (10% of the tick period)",
        f"first {burst[0]:.0f} ms (reminder burst), steady p50 {percentile(steady, 50):.0f} / "
        f"p95 {percentile(steady, 95):.0f} ms; due scan p95 "
        f"{queries['due scan (open incidents)']['p95']:.1f} ms; Hold evaluation p95 "
        f"{queries['Hold evaluation (whole step)']['p95']:.1f} ms",
        None,
        detail,
    )
    return check, detail


async def _recent(session: AsyncSession, now: datetime) -> int:
    from sqlalchemy import func, select  # noqa: PLC0415

    from app.incidents.models import EscalationIncident  # noqa: PLC0415

    since = now - ANOMALY_WINDOW
    return int(
        (
            await session.execute(
                select(func.count()).where(
                    EscalationIncident.opened_at > since, EscalationIncident.opened_at <= now
                )
            )
        ).scalar_one()
    )


# --------------------------------------------------------------------------------------------
# PERF-03: the dispatcher
# --------------------------------------------------------------------------------------------


@dataclass
class LatencyEmailProvider:
    """A fake provider that answers after ``low``..``high`` seconds (the network)."""

    low: float
    high: float
    name: str = "latency"
    sent: int = 0
    rng: random.Random = field(default_factory=lambda: random.Random(7))  # noqa: S311

    async def send(self, msg: EmailMessage, *, idempotency_key: str) -> ProviderResult:
        if self.high > 0:
            await asyncio.sleep(self.rng.uniform(self.low, self.high))
        self.sent += 1
        return ProviderResult(provider=self.name, message_id=idempotency_key)


@dataclass
class LatencyPushProvider:
    low: float
    high: float
    name: str = "latency"
    sent: int = 0
    rng: random.Random = field(default_factory=lambda: random.Random(11))  # noqa: S311

    async def send(self, msg: PushMessage, *, idempotency_key: str) -> ProviderResult:
        if self.high > 0:
            await asyncio.sleep(self.rng.uniform(self.low, self.high))
        self.sent += 1
        return ProviderResult(provider=self.name, message_id=idempotency_key)


def clear_queue(owner: psycopg.Connection[Any]) -> None:
    """A clean queue and no Hold left over from an earlier phase: both would make a phase wait
    for something other than what it measures."""
    holds = owner.execute(
        "SELECT count(*) FROM system_holds WHERE ended_at IS NULL OR exit_processed_at IS NULL"
    ).fetchone()
    if holds and int(holds[0]):
        msg = "a Hold is in force in the perf database: start from a fresh seed"
        raise HarnessError(msg)
    owner.execute("DELETE FROM notifications WHERE status IN ('queued', 'sending')")


def queue_messages(
    owner: psycopg.Connection[Any], layout: seed.Layout, total: int, tag: str
) -> dict[str, int]:
    """``total`` queued messages: about 4 % escalation alerts to contacts (of the escalated
    accounts, whose stage has executed), the rest reminders to people (half email, half push).
    Returns how many of each were queued."""
    contacts = min(len(layout.escalated), max(1, total // 25))
    people = (total - contacts) // 2
    owner.execute(
        """
        INSERT INTO notifications (user_id, audience, category, contact_id, incident_id,
                                   action_id, channel, template_key, params, send_after,
                                   dedupe_key)
        SELECT a.user_id, 'contact', 'contact_escalation', c.contact_id, a.incident_id, a.id,
               'email', 'contact_alert',
               jsonb_build_object('missed_due_at', i.missed_due_at,
                                  'last_checkin_at', i.missed_due_at - interval '1 day'),
               a.executed_at, 'notif:' || a.id || ':' || %(tag)s || ':' || c.contact_id
          FROM incident_actions a
          JOIN escalation_incidents i ON i.id = a.incident_id
          JOIN escalation_step_contacts c ON c.step_id = a.step_id
         WHERE a.kind = 'execute_stage' AND a.status = 'executed'
           AND i.status = 'escalated' AND i.opened_at > now() - interval '2 days'
         ORDER BY a.user_id
         LIMIT %(contacts)s
        """,
        {"tag": tag, "contacts": contacts},
    )
    # reminders: one email and one push for each of `people` accounts whose deadline is ahead
    owner.execute(
        """
        INSERT INTO notifications (user_id, audience, category, device_id, channel, template_key,
                                   params, send_after, dedupe_key)
        SELECT c.user_id, 'user', 'user', CASE WHEN ch = 'push' THEN d.id END, ch,
               'checkin_pre_reminder',
               jsonb_build_object('due_at', to_char(c.next_due_at AT TIME ZONE 'UTC',
                                                   'YYYY-MM-DD"T"HH24:MI:SS') || '+00:00'),
               now() - interval '1 minute',
               'prereminder:' || c.user_id || ':' || %(tag)s || ':' || ch
          FROM (SELECT user_id, next_due_at FROM checkin_configurations
                 WHERE status = 'active' ORDER BY user_id LIMIT %(people)s) c
          JOIN devices d ON d.user_id = c.user_id
         CROSS JOIN (VALUES ('email'), ('push')) AS t(ch)
        """,
        {"tag": tag, "people": people},
    )
    row = owner.execute(
        "SELECT count(*) FILTER (WHERE audience = 'contact'), "
        "count(*) FILTER (WHERE audience = 'user') FROM notifications WHERE status = 'queued'"
    ).fetchone()
    assert row is not None  # noqa: S101
    return {"contact": int(row[0]), "user": int(row[1])}


@dataclass
class DispatchRun:
    queued: int
    sent: int
    other: dict[str, int]
    seconds: float
    passes: int
    cpu_seconds: float
    rate: float
    per_pass_ms: list[float]

    def as_dict(self) -> dict[str, Any]:
        return {
            "queued": self.queued,
            "sent": self.sent,
            "other": self.other,
            "seconds": round(self.seconds, 2),
            "passes": self.passes,
            "messages_per_second": round(self.rate, 1),
            "cpu_fraction": round(self.cpu_seconds / self.seconds, 2) if self.seconds else None,
            "per_pass_ms": stats(self.per_pass_ms),
        }


async def run_dispatcher(
    stack: PerfStack,
    owner: psycopg.Connection[Any],
    layout: seed.Layout,
    total: int,
    low: float,
    high: float,
    tag: str,
) -> DispatchRun:
    """Dispatch passes back to back (no pause) until the queue is empty."""
    clear_queue(owner)
    tag = f"{tag}{int(time.time())}"  # dedupe keys are unique: a rerun on the same database
    queue_messages(owner, layout, total, tag)
    queued = int(
        owner.execute("SELECT count(*) FROM notifications WHERE status = 'queued'").fetchone()[0]
    )  # type: ignore[index]
    email = LatencyEmailProvider(low, high)
    push = LatencyPushProvider(low, high)
    services = worker_services(stack, email_provider=email)
    dispatcher = Dispatcher(services, push=push)
    passes: list[float] = []
    started = time.perf_counter()
    cpu = time.process_time()
    try:
        deadline = started + 600
        while time.perf_counter() < deadline:
            begun = time.perf_counter()
            await dispatcher.dispatch()
            passes.append((time.perf_counter() - begun) * 1000)
            left = owner.execute(
                "SELECT count(*) FROM notifications WHERE status = 'queued'"
            ).fetchone()
            if left is None or int(left[0]) == 0:
                break
            if len(passes) > IDLE_AFTER and passes[-1] < IDLE_PASS_MS:  # only waiting rows left
                break
    finally:
        await services.db.dispose()
    seconds = time.perf_counter() - started
    cpu_seconds = time.process_time() - cpu
    outcome = Counter(
        {
            str(r[0]): int(r[1])
            for r in owner.execute(
                "SELECT coalesce(cancelled_reason, status), count(*) FROM notifications "
                "WHERE dedupe_key LIKE %s GROUP BY 1",
                (f"%:{tag}:%",),
            ).fetchall()
        }
    )
    sent = outcome.pop("sent", 0)
    return DispatchRun(
        queued=queued,
        sent=sent,
        other=dict(outcome),
        seconds=seconds,
        passes=len(passes),
        cpu_seconds=cpu_seconds,
        rate=sent / seconds if seconds else 0.0,
        per_pass_ms=passes,
    )


async def worker_loop_rate(
    stack: PerfStack, owner: psycopg.Connection[Any], layout: seed.Layout, say: Say, seconds: int
) -> dict[str, Any]:
    """The real worker process drains a queue of reminders: what the loop (tick, then a
    dispatcher pass of at most ``BATCH`` messages, then a pause) lets through."""
    clear_queue(owner)
    tag = f"w{int(time.time())}"
    queue_messages(owner, layout, 2_000, tag)
    stack.start_worker()
    queued = int(
        owner.execute(
            "SELECT count(*) FROM notifications WHERE dedupe_key LIKE %s", (f"%:{tag}:%",)
        ).fetchone()[0]  # type: ignore[index]
    )
    marks: list[tuple[float, int]] = []
    try:
        began = time.perf_counter()
        while time.perf_counter() - began < seconds:
            await asyncio.sleep(0.25)
            sent = int(
                owner.execute(
                    "SELECT count(*) FROM notifications WHERE status = 'sent' "
                    "AND dedupe_key LIKE %s",
                    (f"%:{tag}:%",),
                ).fetchone()[0]  # type: ignore[index]
            )
            marks.append((time.perf_counter() - began, sent))
            plateau = [m for m in marks if m[0] > marks[-1][0] - IDLE_SECONDS]
            if sent > 0 and all(m[1] == sent for m in plateau) and plateau[0][0] > IDLE_SECONDS:
                break  # nothing more is being sent: the rest waits for a reason of its own
    finally:
        stack.stop_worker()
    final = marks[-1][1]
    first = next((m for m in marks if m[1] > 0), marks[-1])
    done = next((m for m in marks if m[1] >= final), marks[-1])
    span = done[0] - first[0]
    # from the first message seen to the last one sent; with a span under a second the number is
    # the batch the first look found, so say so rather than divide by almost nothing
    rate = (final - first[1]) / span if span >= 1.0 else float("nan")
    overall = final / done[0] if done[0] else 0.0
    say(
        f"      worker loop: {final}/{queued} sent; first seen at {first[0]:.1f} s, all at "
        f"{done[0]:.1f} s -> {overall:.0f} messages/s from the worker's start"
        + (f", {rate:.0f}/s after the first look" if not math.isnan(rate) else "")
    )
    return {
        "queued": queued,
        "sent": final,
        "seconds_to_last": round(done[0], 1),
        "messages_per_second": round(overall, 1),
        "messages_per_second_after_first_look": None if math.isnan(rate) else round(rate, 1),
    }


async def perf03(
    stack: PerfStack,
    layout: seed.Layout,
    owner: psycopg.Connection[Any],
    say: Say,
    *,
    loop_seconds: int = 75,
) -> Check:
    say(f"    PERF-03: {PERF03_MESSAGES:,} queued messages, fake provider with 20 to 50 ms latency")
    slow = await run_dispatcher(stack, owner, layout, PERF03_MESSAGES, 0.020, 0.050, "a")
    say(
        f"      with latency: {slow.sent:,} sent in {slow.seconds:.1f} s = {slow.rate:.1f}/s "
        f"({slow.passes} passes, cpu {slow.cpu_seconds / slow.seconds:.0%}, other={slow.other})"
    )
    fast = await run_dispatcher(stack, owner, layout, 2_000, 0.0, 0.0, "b")
    say(
        f"      no latency  : {fast.sent:,} sent in {fast.seconds:.1f} s = {fast.rate:.1f}/s "
        f"(the dispatcher's own ceiling, cpu {fast.cpu_seconds / fast.seconds:.0%})"
    )
    say("    PERF-03b: the real worker process, same queue shape, fake (instant) providers")
    loop = await worker_loop_rate(stack, owner, layout, say, loop_seconds)
    theoretical = DISPATCH_CONCURRENCY / 0.035
    bound = _bound(slow, theoretical)
    ok = slow.rate >= PERF03_PER_SECOND and loop["messages_per_second"] >= PERF03_PER_SECOND
    return Check(
        "PERF-03",
        "Outbox dispatcher",
        f">= {PERF03_PER_SECOND:.0f} messages/s with a fake provider",
        f"in-process {slow.rate:.0f}/s with 20-50 ms latency (ceiling {fast.rate:.0f}/s without); "
        f"worker loop (tick every {stack.tick_seconds} s) {loop['messages_per_second']:.1f}/s; "
        f"bounded by: {bound}",
        ok,
        {
            "with_latency": slow.as_dict(),
            "without_latency": fast.as_dict(),
            "worker_loop": loop,
            "batch": DISPATCH_BATCH,
            "concurrency": DISPATCH_CONCURRENCY,
            "latency_bound_per_second": round(theoretical, 1),
            "bounded_by": bound,
        },
    )


def _bound(run: DispatchRun, latency_bound: float) -> str:
    cpu = run.cpu_seconds / run.seconds if run.seconds else 0
    if cpu > 0.8:  # noqa: PLR2004
        return (
            f"the single event loop (cpu {cpu:.0%}); concurrency {DISPATCH_CONCURRENCY} not reached"
        )
    if run.rate > 0.8 * latency_bound:
        return f"provider latency x concurrency ({DISPATCH_CONCURRENCY})"
    return (
        f"database round trips per message (cpu {cpu:.0%}), batches of {DISPATCH_BATCH}: each pass "
        "waits for its slowest message"
    )


# --------------------------------------------------------------------------------------------
# PERF-02: 10,000 users due in the same minute
# --------------------------------------------------------------------------------------------


async def perf02(
    stack: PerfStack,
    layout: seed.Layout,
    owner: psycopg.Connection[Any],
    due_users: int,
    say: Say,
) -> Check:
    numbers = layout.plain(due_users, from_top=True)
    ids = [seed.user_id(i) for i in numbers]
    clear_queue(owner)
    log = stack.start_worker()
    say(
        f"    worker started (tick every {stack.tick_seconds} s); {len(ids):,} users get a deadline"
    )
    await asyncio.sleep(2)
    # The due minute: the next whole minute at least 40 s away. Every one of them is due at its
    # first second (the harsh case of "in the same minute"). Reminders are off for them: in
    # production their reminders would have been delivered an hour earlier.
    row = owner.execute(
        "SELECT date_trunc('minute', now() + interval '100 seconds'), now()"
    ).fetchone()
    assert row is not None  # noqa: S101
    due_at: datetime = row[0]
    owner.execute(
        """
        UPDATE checkin_configurations
           SET next_due_at = %(due)s, baseline_at = now(), reminder_lead_minutes = 0,
               updated_at = now()
         WHERE user_id = ANY(%(ids)s)
        """,
        {"due": due_at, "ids": ids},
    )
    # Nobody else of the seed (spread over 24 hours: about 70 a minute) is due at that instant:
    # the counts below are of these people only.
    owner.execute(
        "UPDATE checkin_configurations SET next_due_at = next_due_at + interval '2 minutes' "
        "WHERE status = 'active' AND next_due_at = %(due)s AND NOT (user_id = ANY(%(ids)s))",
        {"due": due_at, "ids": ids},
    )
    say(f"      due minute {due_at:%H:%M:%S}; waiting for the worker")
    beats: list[tuple[float, datetime]] = []
    waiting_peak = 0
    t0 = time.perf_counter()
    opened = 0
    deadline = t0 + 100 + PERF02_SECONDS + 600
    last_beat: datetime | None = None
    while time.perf_counter() < deadline:
        await asyncio.sleep(0.25)
        current = owner.execute(
            "SELECT max(last_beat_at) FROM service_heartbeats WHERE service = 'engine'"
        ).fetchone()
        beat = current[0] if current else None
        if beat is not None and beat != last_beat:
            beats.append((time.perf_counter() - t0, beat))
            last_beat = beat
        locks = owner.execute("SELECT count(*) FROM pg_locks WHERE NOT granted").fetchone()
        waiting_peak = max(waiting_peak, int(locks[0]) if locks else 0)
        counted = owner.execute(
            "SELECT count(*) FROM escalation_incidents WHERE missed_due_at = %s", (due_at,)
        ).fetchone()
        opened = int(counted[0]) if counted else 0
        if opened >= len(ids):
            break
    stats_row = owner.execute(
        "SELECT min(opened_at), max(opened_at) FROM escalation_incidents WHERE missed_due_at = %s",
        (due_at,),
    ).fetchone()
    assert stats_row is not None  # noqa: S101
    first_open, last_open = stats_row
    to_last = (last_open - due_at).total_seconds() if last_open else float("nan")
    to_first = (first_open - due_at).total_seconds() if first_open else float("nan")
    say(
        f"      incidents opened: {opened:,}/{len(ids):,}; first {to_first:.1f} s and last "
        f"{to_last:.1f} s after the due minute"
    )

    # then the first reminders of every incident ("missed"): enqueued when their action runs
    reminders_done: float | None = None
    deadline = time.perf_counter() + 600
    while time.perf_counter() < deadline:
        done = owner.execute(
            "SELECT count(*) FROM incident_actions a JOIN escalation_incidents i "
            "ON i.id = a.incident_id WHERE i.missed_due_at = %s AND a.kind = 'user_reminder' "
            "AND a.variant = 'missed' AND a.status = 'executed'",
            (due_at,),
        ).fetchone()
        if done and int(done[0]) >= opened:
            last_exec = owner.execute(
                "SELECT max(a.executed_at) FROM incident_actions a JOIN escalation_incidents i "
                "ON i.id = a.incident_id WHERE i.missed_due_at = %s AND a.kind = 'user_reminder' "
                "AND a.variant = 'missed'",
                (due_at,),
            ).fetchone()
            reminders_done = (last_exec[0] - due_at).total_seconds() if last_exec else None
            break
        await asyncio.sleep(1)
    stack.stop_worker()
    verification = _verify_perf02(owner, due_at, len(ids))
    ticks = [b - a for (_, a), (_, b) in pairwise(beats)]
    tick_gaps = [t.total_seconds() for t in ticks if t.total_seconds() < 120]  # noqa: PLR2004
    errors = _log_errors(log)
    say(f"      worker loop iterations (heartbeat to heartbeat, s): {stats(tick_gaps)}")
    say(f"      verification: {verification}; peak lock waits {waiting_peak}; log errors {errors}")
    ok = (
        opened == len(ids)
        and to_last <= PERF02_SECONDS
        and verification["ok"]
        and waiting_peak == 0
        and errors == 0
    )
    return Check(
        "PERF-02",
        f"{len(ids):,} users due in one minute, one worker",
        f"all incidents opened within {PERF02_SECONDS:.0f} s of the due minute",
        f"{opened:,}/{len(ids):,} opened; first +{to_first:.0f} s, last +{to_last:.0f} s; first "
        f"reminders all queued +{reminders_done or float('nan'):.0f} s; duplicates "
        f"{verification['duplicate_incidents']}, reminder anomalies "
        f"{verification['reminder_anomalies']}, lock waits {waiting_peak}",
        ok,
        {
            "due_users": len(ids),
            "due_at": due_at.isoformat(),
            "opened": opened,
            "first_open_s": to_first,
            "last_open_s": to_last,
            "reminders_queued_s": reminders_done,
            "loop_iterations_s": stats(tick_gaps),
            "heartbeats": [(round(t, 1), b.isoformat()) for t, b in beats[:60]],
            "peak_ungranted_locks": waiting_peak,
            "worker_log_errors": errors,
            "verification": verification,
            "tick_batch": TICK_BATCH,
            "tick_max_pages": MAX_PAGES,
        },
    )


def _verify_perf02(owner: psycopg.Connection[Any], due_at: datetime, due: int) -> dict[str, Any]:
    def one(sql: str, *params: Any) -> int:
        row = owner.execute(sql, params).fetchone()  # type: ignore[arg-type]
        return int(row[0]) if row else 0

    duplicate_incidents = one(
        "SELECT count(*) FROM (SELECT user_id FROM escalation_incidents WHERE missed_due_at = %s "
        "GROUP BY user_id HAVING count(*) > 1) q",
        due_at,
    )
    incidents = one("SELECT count(*) FROM escalation_incidents WHERE missed_due_at = %s", due_at)
    # every incident has the whole timeline exactly once: 3 reminders and 1 stage
    bad_timeline = one(
        """
        SELECT count(*) FROM (
          SELECT i.id FROM escalation_incidents i
          LEFT JOIN incident_actions a ON a.incident_id = i.id
          WHERE i.missed_due_at = %s
          GROUP BY i.id
          HAVING count(*) FILTER (WHERE a.kind = 'user_reminder' AND a.variant = 'missed') <> 1
              OR count(*) FILTER (WHERE a.kind = 'user_reminder' AND a.variant = 'midpoint') <> 1
              OR count(*) FILTER (WHERE a.kind = 'user_reminder' AND a.variant = 'last_chance') <> 1
              OR count(*) FILTER (WHERE a.kind = 'execute_stage') <> 1
        ) q
        """,
        due_at,
    )
    # the first reminder of every incident: one push per device and one email, never more
    reminder_anomalies = one(
        """
        SELECT count(*) FROM (
          SELECT a.id,
                 count(*) FILTER (WHERE n.channel = 'email') AS emails,
                 count(*) FILTER (WHERE n.channel = 'push') AS pushes
            FROM escalation_incidents i
            JOIN incident_actions a ON a.incident_id = i.id AND a.kind = 'user_reminder'
                                   AND a.variant = 'missed' AND a.status = 'executed'
            LEFT JOIN notifications n ON n.action_id = a.id
           WHERE i.missed_due_at = %s
           GROUP BY a.id
          HAVING count(*) FILTER (WHERE n.channel = 'email') <> 1
              OR count(*) FILTER (WHERE n.channel = 'push') <> 1
        ) q
        """,
        due_at,
    )
    duplicate_dedupe = one(
        "SELECT count(*) FROM (SELECT dedupe_key FROM notifications GROUP BY dedupe_key "
        "HAVING count(*) > 1) q"
    )
    holds = one("SELECT count(*) FROM system_holds")
    violations = one(
        "SELECT count(*) FROM audit_logs WHERE action = 'system.consistency_violation'"
    )
    opened_audits = one(
        "SELECT count(*) FROM audit_logs a JOIN escalation_incidents i ON i.id = a.resource_id "
        "WHERE a.action = 'incident.opened' AND i.missed_due_at = %s",
        due_at,
    )
    config_open = one(
        "SELECT count(*) FROM checkin_configurations c JOIN escalation_incidents i "
        "ON i.user_id = c.user_id WHERE i.missed_due_at = %s AND c.status = 'incident_open'",
        due_at,
    )
    result = {
        "incidents": incidents,
        "duplicate_incidents": duplicate_incidents,
        "bad_timelines": bad_timeline,
        "reminder_anomalies": reminder_anomalies,
        "duplicate_dedupe_keys": duplicate_dedupe,
        "holds_entered": holds,
        "consistency_violations": violations,
        "opened_audit_records": opened_audits,
        "configs_incident_open": config_open,
    }
    result["ok"] = (
        incidents == due
        and duplicate_incidents == 0
        and bad_timeline == 0
        and reminder_anomalies == 0
        and duplicate_dedupe == 0
        and holds == 0
        and violations == 0
        and opened_audits == due
        and config_open == due
    )
    return result


def _log_errors(log: Any) -> int:
    try:
        text = log.read_text(errors="replace")
    except OSError:
        return -1
    return sum(
        1
        for line in text.splitlines()
        if '"level": "error"' in line or '"level": "critical"' in line or "Traceback" in line
    )


__all__ = ["perf02", "perf03", "tick_phase", "timedelta", "uuid"]
