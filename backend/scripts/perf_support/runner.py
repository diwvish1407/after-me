"""The order of a run: database, seed, API, then the phases."""

from __future__ import annotations

import argparse
import asyncio
import os
from collections.abc import Callable
from typing import Any

import psycopg

from perf_support import seed
from perf_support.api_phases import ApiTargets, perf01, perf04
from perf_support.db import checkpoint
from perf_support.engine_phases import perf02, perf03, tick_phase
from perf_support.plans_run import collect_and_explain
from perf_support.report import Report, machine
from perf_support.stack import PerfStack

Say = Callable[[str], None]
FULL_USERS = 100_000
FULL_DUE = 10_000


async def run(
    args: argparse.Namespace,
    names: list[str],
    stack: PerfStack,
    say: Say,
    section: Callable[[str], None],
) -> Report:
    db = stack.db
    due = args.due if args.due is not None else min(FULL_DUE, args.users // 5)
    section(f"AfterMe performance run: {', '.join(n.upper() for n in names)}")
    say(f"  database {db.name} on {db.host}:{db.port}; users {args.users:,}; logs in {stack.work}")
    mach = machine(
        db.owner_conninfo.replace(f"dbname={db.name}", "dbname=postgres"),
        environment=args.environment,
    )
    report = Report(users=args.users, machine=mach)
    _load(report, "at the start")
    say(f"  load average at the start: {report.sections['load_average']['at the start']}")
    report.full_scale = args.users >= FULL_USERS and due >= FULL_DUE
    say(f"  machine: {report.machine_text()}")

    if args.reuse:
        stack.port = stack._free_port()
        layout = seed.Layout.for_users(args.users)
    else:
        section("Creating and seeding the database")
        stack.create_database()
        say(f"  {db.name} recreated and migrated")
        layout = await asyncio.to_thread(seed.seed, db.owner_conninfo, args.users, say)
        checkpoint(db)

    with psycopg.connect(db.owner_conninfo, autocommit=True) as owner:
        report.sections["dataset"] = _dataset(owner)
        say("  dataset: " + ", ".join(f"{k} {v:,}" for k, v in report.sections["dataset"].items()))
        api_phases = {"perf-04", "perf-01"} & set(names)
        if api_phases:
            section("API process")
            stack.start_api()
            say(f"  API on {stack.base_url}")
            targets = ApiTargets(rps=args.rps, seconds=args.seconds)
            if "perf-04" in names:
                section("PERF-04  GET /v1/home")
                report.add(await perf04(stack, layout, owner, targets, say))
            if "perf-01" in names:
                section("PERF-01  POST /v1/checkins")
                first, second = await perf01(stack, layout, owner, targets, say)
                report.add(first)
                report.add(second)
            stack.stop_api()
            _load(report, "after the API phases")
        if "tick" in names:
            section("TICK  the engine tick and the Hold evaluation")
            check, _detail = await tick_phase(stack, layout, say)
            report.add(check)
            _load(report, "after the tick")
        if "perf-03" in names:
            section("PERF-03  the outbox dispatcher")
            report.add(await perf03(stack, layout, owner, say))
            _load(report, "after PERF-03")
        if "perf-02" in names:
            section("PERF-02  users due in the same minute, one worker")
            report.add(await perf02(stack, layout, owner, due, say))
            _load(report, "after PERF-02")
        if "plans" in names:
            section("PLANS  EXPLAIN (ANALYZE, BUFFERS) of the hot paths")
            check, _run = await collect_and_explain(
                stack, layout, owner, say, markdown_path=args.plans_md
            )
            report.add(check)
    return report


def _load(report: Report, when: str) -> None:
    """The machine's load average: other work on a laptop moves every number."""
    one, five, _fifteen = os.getloadavg()
    report.sections.setdefault("load_average", {})[when] = {
        "1min": round(one, 1),
        "5min": round(five, 1),
    }


def _dataset(owner: psycopg.Connection[Any]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for table in (
        "users",
        "sessions",
        "checkin_events",
        "audit_logs",
        "notifications",
        "escalation_incidents",
        "incident_actions",
    ):
        row = owner.execute(f"SELECT count(*) FROM {table}").fetchone()  # noqa: S608
        counts[table] = int(row[0]) if row else 0
    size = owner.execute("SELECT pg_database_size(current_database())").fetchone()
    counts["database_mib"] = int(size[0]) // 2**20 if size else 0
    return counts
