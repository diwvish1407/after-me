"""Health endpoints (API_SPEC §14). Unauthenticated, not rate-limited, no version gate.

* ``/health/live``: the process is up.
* ``/health/ready``: the database is reachable and its schema is one this code can run on.

Which schema is "one this code can run on" (docs/DEPLOYMENT.md §5, expand/contract):

* the database revision is this image's Alembic head: ready;
* the database revision is **unknown to this image's migration scripts**: the schema is *ahead*
  (a newer release migrated it, and this image is the previous release being rolled back to, or
  an old revision starting an instance while the new one rolls out). Every migration keeps the
  previous release working (additive only; drops and renames one release later, enforced by
  ``tests/security/test_migrations.py``), so this is ready, and a warning ``health.schema_ahead``
  is logged once per process. Without this a rollback after any migrating release could never
  become ready;
* the database revision is a revision this image knows but **older** than its head (the code is
  ahead of the schema: the migration has not run), or there is no revision at all, or it cannot
  be read: not ready. New code never serves an old schema.
"""

from __future__ import annotations

import asyncio
from functools import cache
from typing import Final, Literal

from alembic.script import ScriptDirectory
from fastapi import APIRouter, Request
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from starlette.responses import JSONResponse

from app.api.deps import ServicesDep
from app.core.config import BACKEND_DIR
from app.core.errors import ServiceUnavailable, problem_response
from app.core.logging import get_logger
from app.core.middleware import get_request_id

MIGRATIONS_DIR: Final = BACKEND_DIR / "migrations"
READY_TIMEOUT_SECONDS: Final = 3.0

router = APIRouter(prefix="/health", tags=["health"])
_log = get_logger("afterme.health")

SchemaState = Literal["at_head", "ahead", "behind", "missing"]


@cache
def _scripts() -> ScriptDirectory:
    return ScriptDirectory(str(MIGRATIONS_DIR))


@cache
def expected_heads() -> frozenset[str]:
    return frozenset(_scripts().get_heads())


@cache
def known_revisions() -> frozenset[str]:
    """Every revision this image's migration scripts contain."""
    return frozenset(script.revision for script in _scripts().walk_revisions())


def schema_state(current: frozenset[str]) -> SchemaState:
    """Where the database's schema stands relative to this image's code (module docstring)."""
    if not current:
        return "missing"
    if current == expected_heads():
        return "at_head"
    if not current <= known_revisions():
        return "ahead"  # a revision this image has never heard of: a newer release migrated
    return "behind"  # a revision this image knows, but not its head: the migration has not run


class _Once:
    """``health.schema_ahead`` is worth one line per process, not one per probe."""

    def __init__(self) -> None:
        self.done = False

    def __call__(self, revisions: frozenset[str]) -> None:
        if self.done:
            return
        self.done = True
        _log.warning(
            "health.schema_ahead",
            database_revisions=sorted(revisions),
            code_heads=sorted(expected_heads()),
        )


warn_schema_ahead = _Once()


@router.get("/live")
async def live() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/ready", response_model=None)
async def ready(request: Request, services: ServicesDep) -> dict[str, str] | JSONResponse:
    database = "ok"
    migrations = "ok"
    try:
        async with asyncio.timeout(READY_TIMEOUT_SECONDS), services.db.engine.connect() as conn:
            rows = await conn.execute(text("SELECT version_num FROM alembic_version"))
            current = frozenset(str(r[0]) for r in rows)
    except (SQLAlchemyError, OSError, TimeoutError):
        database, migrations = "unavailable", "unknown"
    else:
        state = schema_state(current)
        if state == "ahead":
            warn_schema_ahead(current)
        elif state == "behind":
            migrations = "not_at_head"
        elif state == "missing":
            migrations = "missing"
    if database == "ok" and migrations == "ok":
        return {"status": "ready"}
    return problem_response(
        ServiceUnavailable(
            "The service is not ready.", checks={"database": database, "migrations": migrations}
        ),
        public_base_url=services.settings.public_base_url,
        request_id=get_request_id(request.scope),
    )
