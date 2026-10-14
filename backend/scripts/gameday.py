#!/usr/bin/env python3
"""Game-day rehearsal of OPS-01, OPS-02 and OPS-03, locally (TEST_PLAN §7; docs/GAMEDAYS.md).

    make gameday                                  # all three, about five minutes
    make gameday ARGS="--only ops-02"             # one scenario
    uv run python scripts/gameday.py --help

Each scenario starts from a freshly created throwaway database (``afterme_gameday``, dropped and
recreated, migrated with the owner role as ``mobile/tool/integration.sh`` does), the real API
(uvicorn) and the real worker (``python -m workers.engine``) on ports from 8010, test support on
with a shared random token, rate limits off and a one-second worker tick, and the test clock.
OPS-03 drives the real ``Engine`` and ``Dispatcher`` in-process, because a worker subprocess
cannot take an injected HTTP transport.

It prints what it does, what the operator would see (paste-able excerpts for the runbook) and a
PASS / FAIL table. The exit status is 0 only if every check passes. A check that asserts something
a design document promises and fails prints ``FAIL (defect)``: the product does not do what its
documents say. It is safe to run twice, and it stops everything it started, also on Ctrl-C.

Needs: the backend's ``.venv`` (``make setup``), PostgreSQL running locally with a superuser that
``psql -h localhost -d postgres`` reaches as your OS user, and the roles of
``scripts/dev_db_setup.sh`` (``make setup``; the harness changes no role). It never
touches ``afterme_dev``, ``afterme_test``, ``afterme_it`` or any database but its own.
"""

from __future__ import annotations

import argparse
import shutil
import signal
import sys
import tempfile
import time
import traceback
from collections.abc import Callable
from pathlib import Path
from types import FrameType

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gameday_support import BACKEND_DIR, ops01, ops02, ops03
from gameday_support.checks import scrub, valid_database_name
from gameday_support.procs import (
    Database,
    HarnessError,
    Secrets,
    drop_database,
    reap_stale,
    terminate_all,
)
from gameday_support.report import Report
from gameday_support.stack import Context

SCENARIOS: dict[str, tuple[str, Callable[[Context], None], tuple[str, ...]]] = {
    "ops-01": ("OPS-01", ops01.run, ops01.REQUIRED),
    "ops-02": ("OPS-02", ops02.run, ops02.REQUIRED),
    "ops-03": ("OPS-03", ops03.run, ops03.REQUIRED),
}
DEFAULT_DATABASE = "afterme_gameday"
DEFAULT_PORT = 8010
_REACHED = "the rehearsal reached every state it checks"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="gameday.py",
        description="Rehearse the operational game days OPS-01..03 locally (see docs/GAMEDAYS.md).",
    )
    parser.add_argument(
        "--only",
        default=",".join(SCENARIOS),
        help="comma-separated scenarios to run (default: all of %(default)s)",
    )
    parser.add_argument(
        "--db", default=DEFAULT_DATABASE, help="throwaway database (default: %(default)s)"
    )
    parser.add_argument(
        "--port", type=int, default=DEFAULT_PORT, help="first port to try (default: %(default)s)"
    )
    parser.add_argument(
        "--keep",
        action="store_true",
        help="keep the logs directory and the database after the run (for looking around)",
    )
    return parser


def _interrupt(_signum: int, _frame: FrameType | None) -> None:
    raise KeyboardInterrupt


def _preflight() -> None:
    if shutil.which("psql") is None:
        msg = "psql is not on PATH (PostgreSQL's client is needed to create the database)"
        raise HarnessError(msg)
    if not (BACKEND_DIR / "alembic.ini").is_file():
        msg = f"alembic.ini not found under {BACKEND_DIR}"
        raise HarnessError(msg)


def _run_one(
    ctx: Context, ident: str, scenario: Callable[[Context], None], required: tuple[str, ...]
) -> None:
    """One scenario; whatever it raises becomes a failed row, never a crash of the run. A run
    that finishes without having made every check it is meant to make is a failure too (a
    renamed or skipped check must not read as a pass)."""
    try:
        scenario(ctx)
        made = {row.ident for row in ctx.report.rows}
        missing = [i for i in required if i not in made]
        if missing:
            ctx.report.fail(
                f"{ident}.manifest", "every planned check was made", f"missing {missing}"
            )
    except HarnessError as exc:
        ctx.report.fail(f"{ident}.run", _REACHED, str(exc))
    except KeyboardInterrupt:
        raise
    except Exception as exc:  # a harness bug must show up as a failure
        detail = "".join(traceback.format_exception_only(type(exc), exc)).strip()
        ctx.report.fail(f"{ident}.run", _REACHED, detail)
        ctx.say(traceback.format_exc())
    finally:
        terminate_all()


def _run_all(ctx: Context, names: list[str]) -> bool:
    """Run the scenarios in order. Returns ``True`` when the run was interrupted."""
    try:
        _preflight()
        reaped = reap_stale()
        if reaped:
            ctx.say(f"stopped {len(reaped)} process(es) an earlier run left behind: {reaped}")
        ctx.say(f"AfterMe game-day rehearsal: {', '.join(n.upper() for n in names)}")
        ctx.say(f"  database {ctx.db.name} on {ctx.db.host}:{ctx.db.port}; logs in {ctx.work}")
        for name in names:
            ident, scenario, required = SCENARIOS[name]
            _run_one(ctx, ident, scenario, required)
    except KeyboardInterrupt:
        ctx.say("interrupted: stopping what was started")
        ctx.report.fail("run", "the run was completed", "interrupted")
        return True
    except HarnessError as exc:
        ctx.report.fail("run", "the run could start", str(exc))
    return False


def _clean_up(ctx: Context, *, keep: bool) -> None:
    """Whatever happened: nothing of ours keeps running, and the database goes (unless kept)."""
    terminate_all()
    if keep:
        return
    try:
        drop_database(ctx.db)
    except HarnessError as exc:
        ctx.say(f"could not drop {ctx.db.name}: {exc}")


def _print_result(ctx: Context, started: float) -> None:
    report = ctx.report
    ctx.say()
    ctx.say("=" * 100)
    ctx.say(f"RESULT  ({time.monotonic() - started:.0f} s)")
    ctx.say("=" * 100)
    ctx.say(report.table())
    if report.defects():
        ctx.say()
        ctx.say("Product defects (the documents promise what the code does not do):")
        ctx.say(report.defect_list())


def main(argv: list[str]) -> int:
    args = _parser().parse_args(argv)
    names = [n.strip().lower() for n in args.only.split(",") if n.strip()]
    unknown = [n for n in names if n not in SCENARIOS]
    if unknown or not names:
        print(f"unknown scenario(s) {unknown}; choose from {', '.join(SCENARIOS)}", file=sys.stderr)
        return 2
    if not valid_database_name(args.db):
        print(
            f"refusing database {args.db!r}: only afterme_gameday and its suffixed variants",
            file=sys.stderr,
        )
        return 2

    keys = Secrets()

    def out(text: str) -> None:
        print(scrub(text, keys.values()), flush=True)

    work = Path(tempfile.mkdtemp(prefix="afterme-gameday."))
    ctx = Context(
        report=Report(out=out),
        db=Database.from_environment(args.db),
        keys=keys,
        work=work,
        port_start=args.port,
        out=out,
    )
    signal.signal(signal.SIGINT, _interrupt)
    signal.signal(signal.SIGTERM, _interrupt)
    started = time.monotonic()
    interrupted = False
    try:
        interrupted = _run_all(ctx, names)
    finally:
        _clean_up(ctx, keep=args.keep)
    _print_result(ctx, started)
    # The logs are kept unless every check passed (also for a product defect, which is the
    # case in which someone looks), and when asked.
    if ctx.report.passed and not interrupted and not args.keep:
        shutil.rmtree(work, ignore_errors=True)
    else:
        ctx.say(f"logs: {work}")
    return ctx.report.exit_code()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
