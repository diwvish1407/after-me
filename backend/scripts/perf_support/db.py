"""The throwaway database of the performance harness.

It reuses the game-day harness for everything that changes a cluster (``drop_database``,
``create_database``, ``recreate_database``): the only difference is which names are acceptable.
``afterme_perf`` and its suffixed variants only, never a protected name, and never a host that
is not this machine (also when ``PGHOST`` points somewhere else).
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Final

from perf_support import BACKEND_DIR  # noqa: F401 - puts scripts/ and backend/ on sys.path

from gameday_support.checks import PROTECTED_DATABASES, is_loopback_host  # isort: skip
from gameday_support.procs import (  # isort: skip
    Database,
    _psql,
    HarnessError,
    create_database,
    drop_database,
    recreate_database,
)

DATABASE_NAME_RE: Final = re.compile(r"^afterme_perf[a-z0-9_]{0,30}$")
DEFAULT_DATABASE: Final = "afterme_perf"

__all__ = [
    "DEFAULT_DATABASE",
    "HarnessError",
    "PerfDatabase",
    "create_database",
    "drop_database",
    "recreate_database",
    "valid_database_name",
]


def valid_database_name(name: str) -> bool:
    return bool(DATABASE_NAME_RE.fullmatch(name)) and name not in PROTECTED_DATABASES


@dataclass(frozen=True)
class PerfDatabase(Database):
    """A ``gameday_support`` Database that accepts the perf names instead of the game-day ones."""

    def __post_init__(self) -> None:  # replaces the game-day name check
        if not valid_database_name(self.name):
            msg = f"refusing to work in database {self.name!r}: only afterme_perf[...]"
            raise HarnessError(msg)
        if not is_loopback_host(self.host):
            msg = f"refusing a database host that is not this machine: {self.host!r}"
            raise HarnessError(msg)
        pghost = os.environ.get("PGHOST", "")
        if pghost and not is_loopback_host(pghost) and not pghost.startswith("/"):
            msg = f"refusing to run with PGHOST={pghost!r}: the harness only works on this machine"
            raise HarnessError(msg)

    @classmethod
    def from_environment(cls, name: str) -> PerfDatabase:
        env = os.environ
        return cls(
            name=name,
            host=env.get("AFTERME_PERF_PG_HOST", "localhost"),
            port=int(env.get("AFTERME_PERF_PG_PORT", "5432")),
            owner_password=env.get("AFTERME_OWNER_DB_PASSWORD", cls.owner_password),
            api_password=env.get("AFTERME_API_DB_PASSWORD", cls.api_password),
            worker_password=env.get("AFTERME_WORKER_DB_PASSWORD", cls.worker_password),
        )


def checkpoint(db: Database) -> None:
    """Flush what the seed wrote (as the superuser: the owner role cannot), so that a checkpoint
    does not land in the middle of a measurement."""
    _psql(db, "CHECKPOINT", dbname=db.name, what="checkpoint")
