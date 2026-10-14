"""The machine, the JSON report and the human table.

Laptop numbers are indicative: the report says what produced them (CPU, memory, PostgreSQL
version and settings, local or cloud) so that a run on staging can be compared with a run here.
"""

from __future__ import annotations

import json
import os
import platform
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import psycopg


def _sysctl(name: str) -> str | None:
    done = subprocess.run(  # noqa: S603
        ["sysctl", "-n", name],  # noqa: S607
        capture_output=True,
        text=True,
        check=False,
    )
    return done.stdout.strip() if done.returncode == 0 else None


def _cpu_and_memory() -> tuple[str, int | None, float | None]:
    if sys.platform == "darwin":
        brand = _sysctl("machdep.cpu.brand_string") or platform.processor()
        cores = int(_sysctl("hw.ncpu") or 0) or None
        mem = _sysctl("hw.memsize")
        return brand, cores, int(mem) / 2**30 if mem else None
    brand, memory = platform.processor() or "unknown", None
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                brand = line.split(":", 1)[1].strip()
                break
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal"):
                memory = int(line.split()[1]) / 2**20
                break
    except OSError:
        pass
    return brand, os.cpu_count(), memory


def machine(conninfo: str, *, environment: str) -> dict[str, Any]:
    cpu, cores, memory = _cpu_and_memory()
    settings: dict[str, str] = {}
    version = "unknown"
    with psycopg.connect(conninfo, autocommit=True) as conn:
        row = conn.execute("SHOW server_version").fetchone()
        version = str(row[0]) if row else version
        for name in (
            "shared_buffers",
            "work_mem",
            "max_connections",
            "effective_cache_size",
            "synchronous_commit",
            "random_page_cost",
        ):
            found = conn.execute(f"SHOW {name}").fetchone()
            settings[name] = str(found[0]) if found else "?"
    return {
        "environment": environment,
        "cpu": cpu,
        "cores": cores,
        "memory_gib": round(memory, 1) if memory else None,
        "os": f"{platform.system()} {platform.release()}",
        "python": platform.python_version(),
        "postgresql": version,
        "postgresql_settings": settings,
        "postgresql_location": "same machine as the load generator, API and worker",
    }


@dataclass
class Check:
    ident: str
    title: str
    target: str
    measured: str
    passed: bool | None  # None: informational, not gated
    detail: dict[str, Any] = field(default_factory=dict)
    scale_note: str | None = None


@dataclass
class Report:
    users: int
    machine: dict[str, Any]
    started_at: str = field(default_factory=lambda: datetime.now(UTC).isoformat())
    checks: list[Check] = field(default_factory=list)
    sections: dict[str, Any] = field(default_factory=dict)
    full_scale: bool = True

    def add(self, check: Check) -> None:
        self.checks.append(check)

    @property
    def passed(self) -> bool:
        gated = [c for c in self.checks if c.passed is not None]
        return bool(gated) and all(c.passed for c in gated)

    def as_dict(self) -> dict[str, Any]:
        return {
            "started_at": self.started_at,
            "users": self.users,
            "full_scale": self.full_scale,
            "passed": self.passed,
            "machine": self.machine,
            "checks": [
                {
                    "id": c.ident,
                    "title": c.title,
                    "target": c.target,
                    "measured": c.measured,
                    "result": "INFO" if c.passed is None else ("PASS" if c.passed else "FAIL"),
                    "scale_note": c.scale_note,
                    "detail": c.detail,
                }
                for c in self.checks
            ],
            **self.sections,
        }

    def write(self, path: Path) -> None:
        path.write_text(json.dumps(self.as_dict(), indent=2, default=str) + "\n")

    def table(self) -> str:
        rows = [("ID", "Result", "Target", "Measured")]
        for c in self.checks:
            result = "INFO" if c.passed is None else ("PASS" if c.passed else "FAIL")
            rows.append((c.ident, result, c.target, c.measured))
        widths = [max(len(r[i]) for r in rows) for i in range(4)]
        lines = []
        for n, row in enumerate(rows):
            lines.append("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)))
            if n == 0:
                lines.append("  ".join("-" * w for w in widths))
        return "\n".join(lines)

    def machine_text(self) -> str:
        m = self.machine
        pg = m["postgresql_settings"]
        return (
            f"{m['cpu']} ({m['cores']} cores), {m['memory_gib']} GiB, {m['os']}, "
            f"Python {m['python']}; PostgreSQL {m['postgresql']} "
            f"(shared_buffers {pg['shared_buffers']}, work_mem {pg['work_mem']}), "
            f"{m['environment']}"
        )
