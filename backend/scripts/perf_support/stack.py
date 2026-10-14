"""The throwaway database with the real API (uvicorn) and the real worker started on it.

Reuses the game-day harness for the processes themselves (``spawn``, ``terminate``,
``wait_for``, ``process_env``). What differs from a rehearsal:

* test support is **off** and the clock is the database clock, as in production (a rehearsal
  moves time; a measurement must not);
* rate limiting is **on** (it is part of what a request costs: every authenticated request
  counts once, a check-in twice);
* the worker ticks every 15 s, the production default, unless asked otherwise;
* the people are not made through the API: the sessions are seeded, and their access tokens are
  minted here with the application's own :class:`~app.auth.tokens.AccessTokenService` and the
  signing key of this run's environment.
"""

from __future__ import annotations

import contextlib
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import httpx

from perf_support import BACKEND_DIR  # noqa: F401 - puts scripts/ and backend/ on sys.path
from perf_support.db import PerfDatabase, drop_database, recreate_database

from app.auth.tokens import AccessTokenService  # isort: skip
from app.core.config import Settings  # isort: skip

from gameday_support.procs import (  # isort: skip
    HarnessError,
    Secrets,
    port_is_free,
    process_env,
    reap_stale,
    spawn,
    terminate,
    terminate_all,
    wait_for,
)

PORT_START = 8020
TOKEN_TTL_SECONDS = 4 * 3600
HTTP_OK = 200


@dataclass
class PerfStack:
    db: PerfDatabase
    keys: Secrets = field(default_factory=Secrets)
    tick_seconds: int = 15
    work: Path = field(default_factory=lambda: Path(tempfile.mkdtemp(prefix="afterme-perf.")))
    port: int = 0
    api_proc: subprocess.Popen[bytes] | None = None
    worker_proc: subprocess.Popen[bytes] | None = None
    _starts: int = 0

    # ------------------------------------------------------------------ environment

    def env(self) -> dict[str, str]:
        mail = self.work / "mail"
        mail.mkdir(exist_ok=True)
        env = process_env(
            self.db, self.keys, port=self.port or PORT_START, mail_dir=mail, probe_token=None
        )
        env.update(
            {
                "AFTERME_RATE_LIMIT_ENABLED": "true",
                "AFTERME_TEST_SUPPORT_ENABLED": "false",
                "AFTERME_TICK_SECONDS": str(self.tick_seconds),
                "AFTERME_LOG_LEVEL": "INFO",
            }
        )
        env.pop("AFTERME_TEST_SUPPORT_TOKEN", None)
        return env

    def settings(self) -> Settings:
        """The application's ``Settings`` as the processes see them (for in-process use)."""
        saved = {k: v for k, v in os.environ.items() if k.startswith(("AFTERME_", "PG"))}
        for key in saved:
            del os.environ[key]
        os.environ.update(self.env())
        try:
            return Settings(_env_file=None)
        finally:
            for key in [k for k in os.environ if k.startswith("AFTERME_")]:
                del os.environ[key]
            os.environ.update(saved)

    def _free_port(self) -> int:
        for port in range(PORT_START, PORT_START + 100):
            if port_is_free(port):
                return port
        msg = f"no free port from {PORT_START}"
        raise HarnessError(msg)

    # ------------------------------------------------------------------ lifecycle

    def create_database(self) -> None:
        self.port = self._free_port()
        reap_stale()
        recreate_database(self.db, self.env())

    def start_api(self) -> None:
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
        wait_for(
            "the API to be ready",
            self._ready,
            timeout=60,
            watch=[("the API", self.api_proc, log)],
        )

    def _ready(self) -> bool:
        return httpx.get(f"{self.base_url}/health/ready", timeout=2).status_code == HTTP_OK

    def start_worker(self) -> Path:
        self._starts += 1
        log = self.work / f"worker-{self._starts}.log"
        self.worker_proc = spawn([sys.executable, "-m", "workers.engine"], self.env(), log)
        wait_for(
            "the worker to start",
            lambda: "worker.started" in log.read_text(errors="replace"),
            timeout=60,
            watch=[("the worker", self.worker_proc, log)],
        )
        return log

    def stop_api(self) -> None:
        terminate(self.api_proc, signal.SIGTERM)
        self.api_proc = None

    def stop_worker(self) -> None:
        terminate(self.worker_proc, signal.SIGTERM)
        self.worker_proc = None

    def close(self, *, keep_database: bool) -> None:
        terminate_all()
        if not keep_database:
            with contextlib.suppress(HarnessError):
                drop_database(self.db)
        shutil.rmtree(self.work, ignore_errors=True)

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    # ------------------------------------------------------------------ tokens

    def token_service(self) -> AccessTokenService:
        """The application's own token service with this run's key (same kid, issuer, audience)."""
        settings = self.settings()
        return AccessTokenService(
            signing_keys=settings.jwt_private_keys,
            active_kid=settings.jwt_active_kid,
            issuer=settings.jwt_issuer,
            audience=settings.jwt_audience,
            ttl_seconds=TOKEN_TTL_SECONDS,
        )

    def mint(self, pairs: list[tuple[uuid.UUID, uuid.UUID]]) -> list[str]:
        """Access tokens for ``(user id, session id)`` pairs whose sessions are seeded."""
        service = self.token_service()
        now = datetime.now(UTC)
        return [service.issue(user_id=u, session_id=s, now=now).token for u, s in pairs]


@contextlib.contextmanager
def running(stack: PerfStack, *, keep_database: bool) -> Iterator[PerfStack]:
    try:
        yield stack
    finally:
        stack.close(keep_database=keep_database)
