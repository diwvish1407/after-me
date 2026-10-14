"""Query plans of the hot paths.

The application's own code runs (a request through the ASGI app, an engine tick, a dispatcher
pass, a retention purge, the beta report) while a :class:`Recorder` listens on the SQLAlchemy
engines and keeps every distinct statement with the parameters of its first call. Each is then
explained, with the parameters the application used, by :func:`explain`:
``EXPLAIN (ANALYZE, BUFFERS)`` inside a transaction that is rolled back (so a DELETE does not
delete). This way nothing is retyped: a statement that changes in the code changes in the plan.

``tests/perf`` uses the same recorder with ``enable_seqscan = off`` on a small seed: a Seq Scan
that is still there then has no index to use.
"""

from __future__ import annotations

import re
import time
from collections import Counter
from dataclasses import dataclass, field
from typing import Any

import psycopg
from sqlalchemy import event
from sqlalchemy.engine import Engine as SyncEngine
from sqlalchemy.ext.asyncio import AsyncEngine

from perf_support import BACKEND_DIR  # noqa: F401 - puts backend/ on sys.path

TRIVIAL = re.compile(
    r"^\s*(SELECT now\(\)|SELECT pg_advisory_xact_lock|SELECT current_user|SET |BEGIN|COMMIT|"
    r"ROLLBACK|SELECT 1\b)",
    re.IGNORECASE,
)
_TABLE = re.compile(r"\b(?:FROM|INTO|UPDATE|JOIN)\s+(?:ONLY\s+)?\"?([a-z_]+)\"?", re.IGNORECASE)
# `x NOT IN (a, b, c ...)` / `IN (...)` with a different number of parameters on each call is
# one statement, not one per length
_LIST = re.compile(r"(?:%\([a-z_]+_\d+(?:_\d+)?\)s(?:::\w+)?(?:\s*,\s*)?){2,}")
_SEQ = re.compile(r"Seq Scan on (\w+)(?: (\w+))?")
_EXEC = re.compile(r"Execution Time: ([\d.]+) ms")
_PLAN_TIME = re.compile(r"Planning Time: ([\d.]+) ms")
_INDEX = re.compile(
    r"(?:Index Only Scan|Index Scan)(?: Backward)? using (\w+)|Bitmap Index Scan on (\w+)"
)
_SHARED = re.compile(r"Buffers: shared (.*)")


@dataclass
class Captured:
    path: str  # the scenario that issued it
    statement: str
    parameters: dict[str, Any]
    calls: int = 1
    total_ms: float = 0.0
    role: str = "main"
    failed: bool = False  # raised when it ran (a statement timeout): explained without ANALYZE

    @property
    def verb(self) -> str:
        return self.statement.lstrip().split(None, 1)[0].upper()

    @property
    def label(self) -> str:
        flat = " ".join(self.statement.split())
        tables = []
        for name in _TABLE.findall(flat):
            if name not in tables:
                tables.append(name)
        return f"{self.verb} {', '.join(tables[:4])}"


@dataclass
class Recorder:
    """Attach to async engines; ``path`` names what is running (set it before each scenario)."""

    path: str = ""
    statements: dict[str, Captured] = field(default_factory=dict)
    per_engine: Counter[str] = field(default_factory=Counter)
    _starts: dict[int, float] = field(default_factory=dict)

    def attach(self, engine: AsyncEngine, role: str) -> None:
        sync = engine.sync_engine
        event.listen(sync, "before_cursor_execute", self._before)
        event.listen(sync, "after_cursor_execute", self._after_for(role))
        event.listen(sync, "handle_error", self._failed_for(role))

    def _before(
        self, conn: Any, cursor: Any, statement: str, parameters: Any, context: Any, many: bool
    ) -> None:
        context._perf_start = time.perf_counter()

    def _after_for(self, role: str) -> Any:
        def after(
            conn: SyncEngine, cursor: Any, statement: str, parameters: Any, context: Any, many: bool
        ) -> None:
            elapsed = (time.perf_counter() - context._perf_start) * 1000
            self.per_engine[role] += 1
            if many or not isinstance(parameters, dict) or TRIVIAL.match(statement):
                return
            key = _LIST.sub("%(list)s", " ".join(statement.split()))
            known = self.statements.get(key)
            if known is None:
                self.statements[key] = Captured(
                    self.path, statement, dict(parameters), total_ms=elapsed, role=role
                )
            else:
                known.calls += 1
                known.total_ms += elapsed

        return after

    def _failed_for(self, role: str) -> Any:
        """A statement that raised (a statement timeout): kept, so that it can be explained."""

        def failed(context: Any) -> None:
            statement = context.statement
            parameters = context.parameters
            if not statement or not isinstance(parameters, dict) or TRIVIAL.match(statement):
                return
            key = _LIST.sub("%(list)s", " ".join(statement.split()))
            if key not in self.statements:
                self.statements[key] = Captured(
                    self.path, statement, dict(parameters), role=role, failed=True
                )

        return failed

    def count(self) -> int:
        return sum(self.per_engine.values())


@dataclass
class Plan:
    captured: Captured
    text: str
    execution_ms: float
    planning_ms: float
    seq_scans: list[str]
    indexes: list[str]
    shared_buffers: str
    error: str | None = None

    @property
    def big_seq_scans(self) -> list[str]:
        return self.seq_scans


def explain(
    conn: psycopg.Connection[Any],
    captured: Captured,
    *,
    analyze: bool = True,
    seqscan: bool = True,
) -> Plan:
    """The plan of one captured statement, in a transaction that is rolled back."""
    options = "ANALYZE, BUFFERS" if analyze else "COSTS OFF"
    sql = f"EXPLAIN ({options}) {captured.statement}"
    text = ""
    error: str | None = None
    try:
        with conn.transaction(force_rollback=True):
            conn.execute("SET LOCAL statement_timeout = '120s'")
            if not seqscan:
                conn.execute("SET LOCAL enable_seqscan = off")
            rows = conn.execute(sql, captured.parameters).fetchall()  # type: ignore[arg-type]
            text = "\n".join(str(r[0]) for r in rows)
    except psycopg.Error as exc:
        error = f"{type(exc).__name__}: {str(exc).splitlines()[0]}"
    seq = [m.group(1) for m in _SEQ.finditer(text)]
    exec_ms = _EXEC.search(text)
    plan_ms = _PLAN_TIME.search(text)
    shared = _SHARED.search(text)
    return Plan(
        captured=captured,
        text=text,
        execution_ms=float(exec_ms.group(1)) if exec_ms else float("nan"),
        planning_ms=float(plan_ms.group(1)) if plan_ms else float("nan"),
        seq_scans=seq,
        indexes=sorted({name for pair in _INDEX.findall(text) for name in pair if name}),
        shared_buffers=shared.group(1) if shared else "",
        error=error,
    )


def table_rows(conn: psycopg.Connection[Any]) -> dict[str, int]:
    rows = conn.execute(
        "SELECT relname, reltuples::bigint FROM pg_class c JOIN pg_namespace n "
        "ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r'"
    ).fetchall()
    return {str(r[0]): int(r[1]) for r in rows}


def markdown(plans: list[Plan], sizes: dict[str, int], *, full: bool) -> str:
    lines = [
        "| path | statement | calls | exec ms | seq scans | indexes |",
        "|---|---|---:|---:|---|---|",
    ]
    for p in sorted(
        plans,
        key=lambda x: (x.captured.path, -x.execution_ms if x.execution_ms == x.execution_ms else 0),
    ):
        seq = ", ".join(f"{t} ({sizes.get(t, 0):,} rows)" for t in p.seq_scans) or "-"
        lines.append(
            f"| {p.captured.path} | `{p.captured.label}` | {p.captured.calls} | "
            f"{p.execution_ms:.2f} | {seq} | {', '.join(p.indexes) or '-'} |"
        )
    if full:
        for p in plans:
            lines += [
                "",
                f"### {p.captured.path}: {p.captured.label}",
                "",
                "```sql",
                " ".join(p.captured.statement.split()),
                "```",
                "",
                "```",
                p.text or (p.error or ""),
                "```",
            ]
    return "\n".join(lines)
