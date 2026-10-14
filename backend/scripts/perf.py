#!/usr/bin/env python3
"""Repeatable performance harness: TEST_PLAN §9 (PERF-01..04) plus the tick and Hold costs.

    make perf                                   # 100,000 users, the full run (about 20 minutes)
    make perf ARGS="--users 10000"              # a quick run (about 6 minutes); scaled targets
    make perf ARGS="--only perf-04,perf-01"     # some phases
    make perf ARGS="--only plans --keep"        # the query plans of the hot paths (docs in
                                                # tests/perf/PLANS.md), keep the database
    uv run python scripts/perf.py --help

Everything happens on a throwaway database, ``afterme_perf`` (dropped and recreated, migrated
as the owner role, then filled with bulk SQL: no sign-ups), with the real API (uvicorn) and the
real worker on ports from 8020. It refuses a database that is not on this machine, and never
touches ``afterme_dev`` or ``afterme_test*``. The machine, PostgreSQL version and settings are
recorded in the report: laptop numbers are indicative; run it again against the cloud
environment before relying on a number.

It prints what it does and a PASS / FAIL table, writes a JSON report (``--json``), and exits 0
only if every target passes. Phases:

``perf-04``  GET /v1/home p95 in four account states        ``perf-01``  POST /v1/checkins at 50 rps
``tick``     the engine tick and the Hold evaluation          ``perf-03``  the outbox dispatcher
``perf-02``  10,000 users due in one minute, one worker       ``plans``    EXPLAIN ANALYZE

Needs: the backend's ``.venv`` (``make setup``), PostgreSQL on this machine with a superuser
that ``psql -h localhost -d postgres`` reaches as your OS user, and the roles of
``scripts/dev_db_setup.sh``.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import signal
import sys
import time
import traceback
from pathlib import Path
from types import FrameType

sys.path.insert(0, str(Path(__file__).resolve().parent))

from perf_support import BACKEND_DIR
from perf_support.db import (
    DEFAULT_DATABASE,
    HarnessError,
    PerfDatabase,
    valid_database_name,
)
from perf_support.report import Check, Report, machine
from perf_support.stack import PerfStack

PHASES = ("perf-04", "perf-01", "tick", "perf-03", "perf-02", "plans")
FULL_USERS = 100_000
FULL_DUE = 10_000


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="perf.py",
        description="Repeatable performance harness (TEST_PLAN §9). See the module docstring.",
    )
    parser.add_argument(
        "--users", type=int, default=FULL_USERS, help="%(default)s for the full run"
    )
    parser.add_argument(
        "--only", default=",".join(PHASES), help="comma-separated phases (default: all of them)"
    )
    parser.add_argument("--db", default=DEFAULT_DATABASE, help="throwaway database (%(default)s)")
    parser.add_argument("--json", type=Path, default=None, help="write the JSON report here")
    parser.add_argument("--plans-md", type=Path, default=None, help="write the query plans here")
    parser.add_argument("--keep", action="store_true", help="keep the database and the logs")
    parser.add_argument("--reuse", action="store_true", help="use the database as it is (no seed)")
    parser.add_argument("--rps", type=int, default=50, help="PERF-01 rate (%(default)s)")
    parser.add_argument("--seconds", type=int, default=60, help="PERF-01 length (%(default)s s)")
    parser.add_argument("--due", type=int, default=None, help="PERF-02 users (10000, or users/5)")
    parser.add_argument("--tick-seconds", type=int, default=15, help="worker tick (%(default)s)")
    parser.add_argument(
        "--environment",
        default="local: laptop, PostgreSQL on the same machine",
        help="report label",
    )
    return parser


def _interrupt(_signum: int, _frame: FrameType | None) -> None:
    raise KeyboardInterrupt


def say(text: str = "") -> None:
    print(text, flush=True)


def section(title: str) -> None:
    say()
    say("=" * 100)
    say(title)
    say("=" * 100)


def main(argv: list[str]) -> int:
    args = _parser().parse_args(argv)
    names = [n.strip().lower() for n in args.only.split(",") if n.strip()]
    unknown = [n for n in names if n not in PHASES]
    if unknown or not names:
        say(f"unknown phase(s) {unknown}; choose from {', '.join(PHASES)}")
        return 2
    if not valid_database_name(args.db):
        say(f"refusing database {args.db!r}: only afterme_perf and its suffixed variants")
        return 2
    if args.users < 2_000:  # noqa: PLR2004
        say("--users must be at least 2000 (the phases need people to pick from)")
        return 2
    # Nothing from the caller's environment may redirect a DROP DATABASE or a connection.
    for key in [k for k in os.environ if k.startswith(("PG", "AFTERME_"))]:
        if key == "PGHOST" and os.environ[key]:
            PerfDatabase.from_environment(args.db)  # refuses a non-loopback PGHOST
        del os.environ[key]
    db = PerfDatabase.from_environment(args.db)
    stack = PerfStack(db, tick_seconds=args.tick_seconds)
    signal.signal(signal.SIGINT, _interrupt)
    signal.signal(signal.SIGTERM, _interrupt)
    started = time.monotonic()
    report: Report | None = None
    interrupted = False
    try:
        report = asyncio.run(_run(args, names, stack))
    except KeyboardInterrupt:
        interrupted = True
        say("interrupted: stopping what was started")
    except HarnessError as exc:
        say(f"the run could not complete: {exc}")
    except Exception:
        say(traceback.format_exc())
    finally:
        stack.close(keep_database=args.keep)
    if report is None:
        return 1
    say()
    say("=" * 100)
    say(f"RESULT  ({time.monotonic() - started:.0f} s)  users={report.users}")
    say("=" * 100)
    say(report.machine_text())
    say()
    say(report.table())
    if not report.full_scale:
        say()
        say(
            "Not the full scale of TEST_PLAN §9 (100,000 users, 10,000 due): these numbers are "
            "indicative only."
        )
    if args.json:
        report.write(args.json)
        say(f"report: {args.json}")
    return 0 if report.passed and not interrupted else 1


async def _run(args: argparse.Namespace, names: list[str], stack: PerfStack) -> Report:
    from perf_support import runner  # noqa: PLC0415

    return await runner.run(args, names, stack, say, section)


__all__ = ["BACKEND_DIR", "Check", "machine"]

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
