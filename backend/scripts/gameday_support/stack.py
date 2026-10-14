"""One scenario's world: its database, its real API and worker processes, its people."""

from __future__ import annotations

import contextlib
import signal
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from .checks import scrub
from .procs import (
    CliResult,
    Database,
    HarnessError,
    Secrets,
    port_is_free,
    process_env,
    recreate_database,
    run_admin,
    spawn,
    tail,
    terminate,
    wait_for,
)
from .report import Report
from .world import Api, Mailbox, Observer, People, Sim


@dataclass
class Context:
    """What every scenario shares: where results go, the run's secrets, the database."""

    report: Report
    db: Database
    keys: Secrets
    work: Path
    port_start: int
    out: Callable[[str], None] = print

    def say(self, text: str = "") -> None:
        self.out(scrub(text, self.keys.values()))

    def section(self, title: str) -> None:
        self.say()
        self.say("=" * 100)
        self.say(title)
        self.say("=" * 100)

    def phase(self, title: str) -> None:
        self.say()
        self.say(f"  -- {title}")

    def block(self, title: str, lines: list[str]) -> None:
        """A paste-able excerpt for the runbook."""
        self.say()
        self.say(f"  What the operator would see: {title}")
        for line in lines:
            self.say(f"      | {line}")


class Stack:
    """A fresh database with the real API (uvicorn) and the real worker (``python -m
    workers.engine``) started against it, test support on, rate limits off, a one-second tick."""

    def __init__(self, ctx: Context, label: str) -> None:
        self.ctx = ctx
        self.label = label
        self.work = ctx.work / label
        self.work.mkdir(parents=True, exist_ok=True)
        self.mail_dir = self.work / "mail"
        self.mail_dir.mkdir(exist_ok=True)
        self.port = 0
        self.api_proc: subprocess.Popen[bytes] | None = None
        self.worker_proc: subprocess.Popen[bytes] | None = None
        self._starts = 0
        self._api_log: Path | None = None
        self._worker_log: Path | None = None
        self.monitored = False
        self.api: Api
        self.obs: Observer
        self.sim: Sim
        self.people: People
        self.mailbox: Mailbox

    # ------------------------------------------------------------------ environment

    @property
    def probe_token(self) -> str | None:
        return self.ctx.keys.probe_token if self.monitored else None

    def env(self) -> dict[str, str]:
        return process_env(
            self.ctx.db,
            self.ctx.keys,
            port=self.port,
            mail_dir=self.mail_dir,
            probe_token=self.probe_token,
        )

    def _free_port(self) -> int:
        for port in range(self.ctx.port_start, self.ctx.port_start + 100):
            if port_is_free(port):
                return port
        msg = f"no free port from {self.ctx.port_start}"
        raise HarnessError(msg)

    # ------------------------------------------------------------------ lifecycle

    def create(self) -> None:
        """Drop and recreate the database, migrate it, connect, and start the API and worker."""
        self.port = self._free_port()
        self.ctx.say(
            f"  database {self.ctx.db.name} recreated and migrated; API on 127.0.0.1:{self.port}"
        )
        recreate_database(self.ctx.db, self.env())
        self.obs = Observer(self.ctx.db.owner_conninfo)
        self.api = Api(f"http://127.0.0.1:{self.port}", self.ctx.keys.test_token)
        self.mailbox = Mailbox(self.api, self.mail_dir)
        self.sim = Sim(self.api, self.obs)
        self.people = People(self.api, self.obs, self.mailbox)

    def start_api(self, *, monitored: bool | None = None) -> None:
        if monitored is not None:
            self.monitored = monitored
        self._starts += 1
        log = self.work / f"api-{self._starts}.log"
        self.api_proc = spawn(
            [
                sys.executable,
                "-m",
                "uvicorn",
                "app.main:app",
                "--host",
                "127.0.0.1",
                "--port",
                str(self.port),
                "--no-access-log",
                "--no-proxy-headers",
            ],
            self.env(),
            log,
        )
        self._api_log = log
        wait_for(
            "the API to be ready",
            self.api.is_ready,
            timeout=60,
            watch=[("the API", self.api_proc, log)],
        )
        self.sim.probe_token = self.probe_token

    def start_worker(self, *, monitored: bool | None = None) -> None:
        if monitored is not None:
            self.monitored = monitored
        self._starts += 1
        log = self.work / f"worker-{self._starts}.log"
        self.worker_proc = spawn([sys.executable, "-m", "workers.engine"], self.env(), log)
        self._worker_log = log
        wait_for(
            "the worker to start",
            lambda: "worker.started" in log.read_text(errors="replace"),
            timeout=60,
            watch=[("the worker", self.worker_proc, log)],
        )
        self.sim.probe_token = self.probe_token

    def stop_api(self, sig: int = signal.SIGTERM) -> int | None:
        code = terminate(self.api_proc, sig)
        self.api_proc = None
        return code

    def stop_worker(self, sig: int = signal.SIGTERM) -> int | None:
        code = terminate(self.worker_proc, sig)
        self.worker_proc = None
        return code

    def close(self) -> None:
        """Stop what this scenario started. The database is dropped by the caller."""
        self.stop_worker(signal.SIGKILL)
        self.stop_api(signal.SIGKILL)
        for name in ("api", "obs"):
            target = getattr(self, name, None)
            if target is not None:
                with contextlib.suppress(Exception):  # best effort while cleaning up
                    target.close()

    # ------------------------------------------------------------------ the operator

    def admin(self, *args: str) -> CliResult:
        """The operator CLI as an operator runs it (the worker role, the same environment)."""
        return run_admin(self.env(), *args)

    def log_tail(self, which: str = "worker", lines: int = 20) -> str:
        path = getattr(self, f"_{which}_log", None)
        return scrub(tail(path, lines), self.ctx.keys.values()) if path else "(no log)"
