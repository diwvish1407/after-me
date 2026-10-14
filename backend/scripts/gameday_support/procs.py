"""Ports, the real API and worker processes, the operator CLI and the throwaway database.

Everything a run starts is recorded in a pidfile as it starts, and is stopped in ``finally``
blocks, on SIGINT and SIGTERM, and (for what an earlier run that was killed left behind) when
the next run begins. The database is only ever one whose name ``checks.valid_database_name``
accepts.
"""

from __future__ import annotations

import contextlib
import getpass
import json
import os
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat

from . import BACKEND_DIR
from .checks import (
    extract_json,
    is_loopback_host,
    process_matches,
    valid_database_name,
)

PIDDIR = Path(tempfile.gettempdir()) / "afterme-gameday-pids"
KID = "gameday-1"
TICK_SECONDS = 1  # the worker's loop; engine parameters are otherwise the defaults


class HarnessError(Exception):
    """The rehearsal could not get to the state a check needs (not a verdict on the product)."""


# --------------------------------------------------------------------------------------------
# the database
# --------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Database:
    name: str
    host: str = "localhost"
    port: int = 5432
    owner_password: str = "afterme_owner_dev"  # noqa: S105 - the dev-only default of dev_db_setup.sh
    api_password: str = "afterme_api_dev"  # noqa: S105
    worker_password: str = "afterme_worker_dev"  # noqa: S105
    superuser: str = field(default_factory=getpass.getuser)

    def __post_init__(self) -> None:
        if not valid_database_name(self.name):
            msg = f"refusing to work in database {self.name!r}"
            raise HarnessError(msg)
        if not is_loopback_host(self.host):
            msg = f"refusing a database host that is not this machine: {self.host!r}"
            raise HarnessError(msg)

    @classmethod
    def from_environment(cls, name: str) -> Database:
        env = os.environ
        return cls(
            name=name,
            host=env.get("AFTERME_GAMEDAY_PG_HOST", "localhost"),
            port=int(env.get("AFTERME_GAMEDAY_PG_PORT", "5432")),
            owner_password=env.get("AFTERME_OWNER_DB_PASSWORD", cls.owner_password),
            api_password=env.get("AFTERME_API_DB_PASSWORD", cls.api_password),
            worker_password=env.get("AFTERME_WORKER_DB_PASSWORD", cls.worker_password),
        )

    def _url(self, role: str, password: str) -> str:
        return f"postgresql+psycopg://{role}:{password}@{self.host}:{self.port}/{self.name}"

    @property
    def api_url(self) -> str:
        return self._url("afterme_api", self.api_password)

    @property
    def worker_url(self) -> str:
        return self._url("afterme_worker", self.worker_password)

    @property
    def owner_url(self) -> str:
        return self._url("afterme_owner", self.owner_password)

    @property
    def owner_conninfo(self) -> str:
        return (
            f"host={self.host} port={self.port} dbname={self.name} "
            f"user=afterme_owner password={self.owner_password}"
        )


def _run(args: Sequence[str], *, env: dict[str, str], what: str) -> str:
    done = subprocess.run(  # noqa: S603 - fixed argument lists, no shell
        list(args),
        cwd=BACKEND_DIR,
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
        check=False,
    )
    if done.returncode != 0:
        tail_lines = (done.stdout + done.stderr).strip().splitlines()[-12:]
        msg = f"{what} failed (exit {done.returncode}): " + " | ".join(tail_lines)
        raise HarnessError(msg)
    return done.stdout


def _pinned_env() -> dict[str, str]:
    """What a ``psql`` that changes the cluster may see: no ``PG*`` and no ``AFTERME_*`` from
    the caller's shell (a ``PGHOST`` or ``PGSERVICE`` must not redirect a ``DROP DATABASE``)."""
    keep = ("PATH", "HOME", "LANG", "LC_ALL", "TMPDIR")
    return {k: v for k, v in os.environ.items() if k in keep}


def _psql(db: Database, sql: str, *, dbname: str, what: str) -> str:
    """One statement as the PostgreSQL superuser, on the explicit local host, port and user the
    harness derived (``Database`` refuses a host that is not this machine)."""
    return _run(
        [
            "psql",
            "-X",
            "-q",
            "-At",
            "-h",
            db.host,
            "-p",
            str(db.port),
            "-U",
            db.superuser,
            "-d",
            dbname,
            "-v",
            "ON_ERROR_STOP=1",
            "-c",
            sql,
        ],
        env=_pinned_env(),
        what=what,
    )


_ROLES = (
    "afterme_owner",
    "afterme_api",
    "afterme_worker",
    "afterme_maintenance",
    "afterme_readonly",
)


def drop_database(db: Database) -> None:
    """``DROP DATABASE ... WITH (FORCE)``, which also ends the connections of anything of ours
    still running. The name was validated by ``Database``."""
    _psql(
        db,
        f"DROP DATABASE IF EXISTS {db.name} WITH (FORCE)",
        dbname="postgres",
        what=f"dropping {db.name}",
    )


def create_database(db: Database) -> None:
    """The database, hardened as ``scripts/dev_db_setup.sh`` hardens its own, **without**
    touching any role (the script's ``ALTER ROLE ... PASSWORD`` is cluster-wide; the roles must
    already exist, from ``make setup``)."""
    found = _psql(
        db,
        "SELECT rolname FROM pg_roles WHERE rolname ~ '^afterme_'",
        dbname="postgres",
        what="looking for the AfterMe roles",
    ).split()
    missing = [r for r in _ROLES if r not in found]
    if missing:
        msg = (
            f"roles missing: {', '.join(missing)}; run `make setup` (scripts/dev_db_setup.sh) once"
        )
        raise HarnessError(msg)
    name = db.name
    _psql(
        db,
        f"CREATE DATABASE {name} OWNER afterme_owner ENCODING 'UTF8'",
        dbname="postgres",
        what=f"creating {name}",
    )
    for sql in (
        f"REVOKE TEMPORARY ON DATABASE {name} FROM PUBLIC",
        f"GRANT CONNECT ON DATABASE {name} TO afterme_api, afterme_worker",
    ):
        _psql(db, sql, dbname="postgres", what=f"hardening {name}")
    for sql in (
        "ALTER SCHEMA public OWNER TO afterme_owner",
        "REVOKE CREATE ON SCHEMA public FROM PUBLIC",
        "GRANT USAGE ON SCHEMA public TO afterme_api, afterme_worker, "
        "afterme_maintenance, afterme_readonly",
    ):
        _psql(db, sql, dbname=name, what=f"hardening {name}")


def recreate_database(db: Database, env: dict[str, str]) -> None:
    """The throwaway database: dropped, created and hardened, migrated as ``afterme_owner``
    exactly as ``mobile/tool/integration.sh`` does. Only ``db.name`` is ever touched."""
    drop_database(db)
    create_database(db)
    _run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        env=env,
        what=f"migrating {db.name}",
    )


# --------------------------------------------------------------------------------------------
# environment of the processes
# --------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Secrets:
    """Made fresh for every run and never printed."""

    test_token: str = field(default_factory=lambda: secrets.token_hex(32))
    probe_token: str = field(default_factory=lambda: secrets.token_hex(32))
    pepper: str = field(default_factory=lambda: secrets.token_urlsafe(48))
    jwt_pem: str = field(
        default_factory=lambda: (
            Ed25519PrivateKey.generate()
            .private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
            .decode()
        )
    )

    def values(self) -> list[str]:
        return [self.test_token, self.probe_token, self.pepper, self.jwt_pem]


def process_env(
    db: Database,
    keys: Secrets,
    *,
    port: int,
    mail_dir: Path,
    probe_token: str | None,
) -> dict[str, str]:
    """One environment for the API, the worker and the CLI, so that they share the test clock
    (it lives in the database), the token and the mail directory. Nothing is inherited from
    ``AFTERME_*`` in the caller's shell, and ``APP_ENV=test`` keeps ``backend/.env`` (and so
    ``afterme_dev``) out of it entirely."""
    env = {k: v for k, v in os.environ.items() if not k.startswith(("AFTERME_", "PG"))}
    env.update(
        {
            "AFTERME_APP_ENV": "test",
            "AFTERME_DATABASE_URL": db.api_url,
            "AFTERME_WORKER_DATABASE_URL": db.worker_url,
            "AFTERME_MIGRATION_DATABASE_URL": db.owner_url,
            "AFTERME_MAINTENANCE_DATABASE_URL": db.owner_url,
            "AFTERME_JWT_SIGNING_KEYS": json.dumps({KID: keys.jwt_pem}),
            "AFTERME_JWT_ACTIVE_KID": KID,
            "AFTERME_HMAC_PEPPER": keys.pepper,
            "AFTERME_ARGON2_TIME_COST": "1",
            "AFTERME_ARGON2_MEMORY_COST_KIB": "1024",
            "AFTERME_ARGON2_PARALLELISM": "1",
            "AFTERME_RATE_LIMIT_ENABLED": "false",
            "AFTERME_TEST_SUPPORT_ENABLED": "true",
            "AFTERME_TEST_SUPPORT_TOKEN": keys.test_token,
            "AFTERME_EMAIL_PROVIDER": "console",
            "AFTERME_PUSH_PROVIDER": "log",
            "AFTERME_DEV_MAIL_DIR": str(mail_dir),
            "AFTERME_PUBLIC_BASE_URL": f"http://127.0.0.1:{port}",
            "AFTERME_API_BASE_URL": f"http://127.0.0.1:{port}",
            "AFTERME_TICK_SECONDS": str(TICK_SECONDS),
            "AFTERME_LOG_LEVEL": "INFO",
        }
    )
    if probe_token is not None:
        env["AFTERME_PROBE_TOKEN"] = probe_token
    return env


# --------------------------------------------------------------------------------------------
# ports and processes
# --------------------------------------------------------------------------------------------

_STARTED: list[subprocess.Popen[bytes]] = []
_IDENTITIES: dict[int, dict[str, str]] = {}


def port_is_free(port: int) -> bool:
    """Nothing listens on it and it can be bound (a wildcard listener makes a connect succeed
    where a loopback bind alone might not fail)."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(0.5)
        if probe.connect_ex(("127.0.0.1", port)) == 0:
            return False
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def identity(pid: int) -> dict[str, str] | None:
    """What identifies a process across PID reuse: its start time and its full command line."""
    fields: dict[str, str] = {}
    for key, column in (("start", "lstart="), ("command", "command=")):
        done = subprocess.run(  # noqa: S603
            ["ps", "-p", str(pid), "-o", column],  # noqa: S607
            capture_output=True,
            text=True,
            check=False,
        )
        value = done.stdout.strip()
        if done.returncode != 0 or not value:
            return None
        fields[key] = value
    return fields


def _run_file() -> Path:
    return PIDDIR / f"{os.getpid()}.json"


def _remember() -> None:
    """This run's record: itself, and every live child with its start time and command line."""
    live = {
        str(p.pid): _IDENTITIES[p.pid]
        for p in _STARTED
        if p.poll() is None and p.pid in _IDENTITIES
    }
    PIDDIR.mkdir(mode=0o700, exist_ok=True)
    me = identity(os.getpid())
    if live and me:
        _run_file().write_text(
            json.dumps({"harness": {"pid": os.getpid(), **me}, "children": live})
        )
    else:
        _run_file().unlink(missing_ok=True)


def _alive_and_same(pid: int, recorded: dict[str, str]) -> bool:
    observed = identity(pid)
    return observed is not None and process_matches(recorded, observed)


def reap_stale() -> list[int]:
    """Stop what an earlier run that was itself killed left running.

    A child is stopped only when its PID, its start time **and** its full command line still
    match what its run recorded, and its run (the harness process) is gone: a live run is
    refused, never reaped, and a PID that was reused by anything else is left alone."""
    reaped: list[int] = []
    if not PIDDIR.is_dir():
        return reaped
    for path in sorted(PIDDIR.glob("*.json")):
        if path == _run_file():
            continue
        try:
            record = json.loads(path.read_text())
            harness = record["harness"]
            children = record["children"]
        except (OSError, ValueError, KeyError):
            path.unlink(missing_ok=True)
            continue
        if _alive_and_same(int(harness["pid"]), {k: harness[k] for k in ("start", "command")}):
            msg = f"another game-day run is in progress (pid {harness['pid']}); not starting"
            raise HarnessError(msg)
        for raw_pid, recorded in children.items():
            pid = int(raw_pid)
            if _alive_and_same(pid, recorded):
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    if os.getpgid(pid) == pid:  # the session leader we started
                        os.killpg(pid, signal.SIGKILL)
                        reaped.append(pid)
        path.unlink(missing_ok=True)
    return reaped


def spawn(args: Sequence[str], env: dict[str, str], log_path: Path) -> subprocess.Popen[bytes]:
    """A new process in its own session (so the whole group can be stopped), its output in
    ``log_path``."""
    log = log_path.open("ab")
    proc = subprocess.Popen(  # noqa: S603 - fixed argument lists, no shell
        list(args),
        cwd=BACKEND_DIR,
        env=env,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    log.close()  # the child holds its own descriptor
    _STARTED.append(proc)
    seen = identity(proc.pid)
    if seen is not None:
        _IDENTITIES[proc.pid] = seen
    _remember()
    return proc


def terminate(
    proc: subprocess.Popen[bytes] | None, sig: int = signal.SIGTERM, *, wait: float = 10.0
) -> int | None:
    """Signal the process group and wait. A process that ignores SIGTERM is killed."""
    if proc is None:
        return None
    if proc.poll() is None:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, sig)
        try:
            proc.wait(timeout=wait)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5)
    _remember()
    return proc.returncode


def terminate_all() -> None:
    for proc in list(_STARTED):
        terminate(proc, signal.SIGKILL, wait=5)
    _STARTED.clear()
    _IDENTITIES.clear()
    _run_file().unlink(missing_ok=True)


def tail(path: Path, lines: int = 15) -> str:
    try:
        return "\n".join(path.read_text(errors="replace").splitlines()[-lines:])
    except OSError:
        return "(no log)"


def wait_for(
    what: str,
    check: Callable[[], bool],
    *,
    timeout: float,
    every: float = 0.25,
    watch: Sequence[tuple[str, subprocess.Popen[bytes] | None, Path]] = (),
) -> None:
    """Poll ``check`` until it is true. A watched process that exits, or the timeout, is a
    ``HarnessError`` that carries the end of that process's log."""
    deadline = time.monotonic() + timeout
    while True:
        # Liveness first: something else answering on our port must not look like us.
        for name, proc, log in watch:
            if proc is not None and proc.poll() is not None:
                msg = f"{name} exited ({proc.returncode}) while waiting for {what}:\n{tail(log)}"
                raise HarnessError(msg)
        with contextlib.suppress(Exception):  # a not-yet-ready dependency is "not yet"
            if check():
                return
        if time.monotonic() > deadline:
            logs = "\n".join(f"--- {name}\n{tail(log)}" for name, _, log in watch)
            msg = f"timed out after {timeout:.0f}s waiting for {what}\n{logs}"
            raise HarnessError(msg)
        time.sleep(every)


# --------------------------------------------------------------------------------------------
# the operator CLI
# --------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class CliResult:
    code: int
    stdout: str
    stderr: str

    @property
    def document(self) -> dict[str, Any] | None:
        return extract_json(self.stdout)

    @property
    def first_line(self) -> str:
        lines = [line for line in self.stdout.splitlines() if line.strip()]
        return lines[-1] if lines else ""


def run_admin(env: dict[str, str], *args: str, timeout: float = 90.0) -> CliResult:
    """``python -m cli.admin ...`` exactly as an operator runs it, in the processes' environment."""
    done = subprocess.run(  # noqa: S603
        [sys.executable, "-m", "cli.admin", "--operator", "gameday", *args],
        cwd=BACKEND_DIR,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    return CliResult(done.returncode, done.stdout, done.stderr)
