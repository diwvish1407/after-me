"""PERF-01 (check-ins) and PERF-04 (Home): HTTP load against the real API process.

Both are open loop (``load.open_loop``) with access tokens minted for seeded sessions. Neither
goes through sign-in: the targets are about the two requests people make all day.
"""

from __future__ import annotations

import asyncio
import uuid
from dataclasses import dataclass
from typing import Any

import psycopg

from perf_support import seed
from perf_support.load import RunResult, Summary, make_client, open_loop, summarise
from perf_support.report import Check
from perf_support.stack import PerfStack

PERF01_P95_MS = 500.0
PERF01_RPS = 50
PERF01_SECONDS = 60
PERF04_P95_MS = 300.0
BODIES_KEPT = 5


@dataclass
class ApiTargets:
    rps: int = PERF01_RPS
    seconds: int = PERF01_SECONDS
    home_rps: int = 20
    home_seconds: int = 20


def _pairs(numbers: range) -> list[tuple[uuid.UUID, uuid.UUID]]:
    return [(seed.user_id(i), seed.session_id(i)) for i in numbers]


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


async def perf01(
    stack: PerfStack,
    layout: seed.Layout,
    owner: psycopg.Connection[Any],
    targets: ApiTargets,
    say: Any,
) -> tuple[Check, Check]:
    """``POST /v1/checkins`` at 50 rps for 60 s, each request from a different person; then the
    cost of replaying 500 of the same taps (the idempotent path: no lock, no write)."""
    total = targets.rps * targets.seconds
    numbers = layout.plain(total + 100)
    if len(numbers) < total + 100:
        say(f"    only {len(numbers)} ordinary accounts for {total} distinct requests; reusing")
    pool = list(numbers)
    tokens = stack.mint(_pairs(numbers))
    keys = [f"perf01-{uuid.uuid4().hex}" for _ in range(total)]
    async with make_client(stack.base_url) as client:
        # warm-up: connections, imports, query plans (not counted)
        warm = len(pool) - 100
        for j in range(100):
            await client.post(
                "/v1/checkins",
                headers={
                    **_bearer(tokens[warm + j]),
                    "Idempotency-Key": f"warm-{uuid.uuid4().hex}",
                },
            )

        def request(i: int) -> tuple[str, str, dict[str, str], Any]:
            n = i % warm
            return (
                "POST",
                "/v1/checkins",
                {**_bearer(tokens[n]), "Idempotency-Key": keys[i]},
                None,
            )

        say(f"    PERF-01: {targets.rps} rps for {targets.seconds} s ({total} check-ins)")
        run = await open_loop(client, request, rate=targets.rps, duration=targets.seconds)
        main = summarise(run.samples, duration=run.duration)
        say(_line("check-in", main, run))

        replays = min(500, total)

        def replay(i: int) -> tuple[str, str, dict[str, str], Any]:
            n = i % warm
            return (
                "POST",
                "/v1/checkins",
                {**_bearer(tokens[n]), "Idempotency-Key": keys[i]},
                None,
            )

        say(f"    PERF-01: replay of {replays} taps at {targets.rps} rps")
        again = await open_loop(client, replay, rate=targets.rps, duration=replays / targets.rps)
        replayed = summarise(again.samples, duration=again.duration)
        say(_line("replay", replayed, again))

    stored = owner.execute(
        "SELECT count(*), count(DISTINCT (user_id, idempotency_key)) FROM checkin_events "
        "WHERE idempotency_key LIKE 'perf01-%%'"
    ).fetchone()
    assert stored is not None  # noqa: S101
    events, distinct = int(stored[0]), int(stored[1])
    exactly_once = events == main.ok == distinct
    p95_ok = main.p95 < PERF01_P95_MS
    check = Check(
        "PERF-01",
        "POST /v1/checkins",
        f"p95 < {PERF01_P95_MS:.0f} ms at {targets.rps} rps for {targets.seconds} s",
        f"p50 {main.p50:.0f} / p95 {main.p95:.0f} / p99 {main.p99:.0f} ms; "
        f"{main.achieved_rps:.1f} rps; errors {main.errors}/{main.count} "
        f"({main.error_rate:.2%}); stored once {events}/{main.ok}",
        p95_ok and main.errors == 0 and exactly_once and run.late_starts < main.count * 0.05,
        {
            "summary": main.as_dict(),
            "generator_late_starts": run.late_starts,
            "events_stored": events,
            "events_distinct": distinct,
            "stored_exactly_once": exactly_once,
        },
    )
    replay_check = Check(
        "PERF-01b",
        "POST /v1/checkins replay (same key)",
        "informational: cost of an idempotent replay",
        f"p50 {replayed.p50:.0f} / p95 {replayed.p95:.0f} / p99 {replayed.p99:.0f} ms; "
        f"replayed {replayed.replayed}/{replayed.count}; errors {replayed.errors}",
        None,
        {"summary": replayed.as_dict()},
    )
    return check, replay_check


def _line(label: str, s: Summary, run: RunResult) -> str:
    return (
        f"      {label:<9} n={s.count} ok={s.ok} p50={s.p50:.0f} p95={s.p95:.0f} "
        f"p99={s.p99:.0f} max={s.max:.0f} ms  {s.achieved_rps:.1f} rps  "
        f"statuses={s.statuses}  generator-late={run.late_starts}"
    )


async def _home_run(
    stack: PerfStack,
    numbers: range,
    targets: ApiTargets,
    say: Any,
    label: str,
    expect: str,
) -> tuple[Summary, list[Any]]:
    tokens = stack.mint(_pairs(numbers))
    async with make_client(stack.base_url) as client:
        # warm-up
        for token in tokens[:20]:
            await client.get("/v1/home", headers=_bearer(token))

        def request(i: int) -> tuple[str, str, dict[str, str], Any]:
            return ("GET", "/v1/home", _bearer(tokens[i % len(tokens)]), None)

        run = await open_loop(
            client,
            request,
            rate=targets.home_rps,
            duration=targets.home_seconds,
            keep_body=lambda i: i < BODIES_KEPT,
        )
    summary = summarise(run.samples, duration=run.duration)
    say(_line(label, summary, run))
    bodies = [s.body for s in run.samples if s.body is not None]
    if expect and bodies:
        say(f"      first response: {expect} -> {_describe(bodies[0])}")
    return summary, bodies


def _describe(body: dict[str, Any]) -> str:
    incident = body.get("incident")
    return (
        f"checkin={body['checkin']['status']} "
        f"incident={incident['status'] if incident else None} "
        f"interruption={body['service']['interruption']}"
    )


async def perf04(
    stack: PerfStack,
    layout: seed.Layout,
    owner: psycopg.Connection[Any],
    targets: ApiTargets,
    say: Any,
) -> Check:
    """``GET /v1/home`` for an active account, an incident in grace, an escalated incident, and
    an active account while a Hold is in force (``service.interruption``)."""
    say(f"    PERF-04: {targets.home_rps} rps for {targets.home_seconds} s in each state")
    states: dict[str, tuple[range, str]] = {
        "active": (layout.plain(300), "active"),
        "grace": (layout.grace, "incident in grace"),
        "escalated": (layout.escalated, "escalated incident"),
    }
    results: dict[str, Summary] = {}
    for name, (numbers, expect) in states.items():
        summary, bodies = await _home_run(stack, numbers, targets, say, name, expect)
        results[name] = summary
        if name == "grace":
            assert all(b["incident"]["status"] == "grace" for b in bodies)  # noqa: S101
        if name == "escalated":
            assert all(b["incident"]["status"] == "escalated" for b in bodies)  # noqa: S101
    # A Hold in force: the same active accounts, with `service.interruption` true.
    owner.execute(
        "INSERT INTO system_holds (reason, started_at, detected_at, created_by, notes) "
        "VALUES ('operator', now(), now(), 'perf', 'PERF-04')"
    )
    try:
        summary, bodies = await _home_run(
            stack, layout.plain(300), targets, say, "hold", "Hold in force"
        )
        results["hold"] = summary
        assert all(b["service"]["interruption"] for b in bodies)  # noqa: S101
    finally:
        owner.execute("DELETE FROM system_holds WHERE notes = 'PERF-04'")
    worst = max(results.values(), key=lambda s: s.p95)
    errors = sum(s.errors for s in results.values())
    per_state = ", ".join(f"{k} {v.p95:.0f}" for k, v in results.items())
    return Check(
        "PERF-04",
        "GET /v1/home",
        f"p95 < {PERF04_P95_MS:.0f} ms in every state",
        f"p95 by state (ms): {per_state}; worst {worst.p95:.0f}; errors {errors}",
        worst.p95 < PERF04_P95_MS and errors == 0,
        {name: s.as_dict() for name, s in results.items()},
    )


def run_async(coro: Any) -> Any:
    return asyncio.run(coro)
