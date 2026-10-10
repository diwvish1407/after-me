"""Health endpoints (API_SPEC §14). Unauthenticated, not rate-limited, no version gate.

* ``/health/live``: the process is up.
* ``/health/ready``: the database is reachable and its Alembic revision is the code's head.
"""

from __future__ import annotations

import asyncio
from functools import cache
from typing import Final

from alembic.script import ScriptDirectory
from fastapi import APIRouter, Request
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from starlette.responses import JSONResponse

from app.api.deps import ServicesDep
from app.core.config import BACKEND_DIR
from app.core.errors import ServiceUnavailable, problem_response
from app.core.middleware import get_request_id

MIGRATIONS_DIR: Final = BACKEND_DIR / "migrations"
READY_TIMEOUT_SECONDS: Final = 3.0

router = APIRouter(prefix="/health", tags=["health"])


@cache
def expected_heads() -> frozenset[str]:
    return frozenset(ScriptDirectory(str(MIGRATIONS_DIR)).get_heads())


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
        if current != expected_heads():
            migrations = "not_at_head"
    if database == "ok" and migrations == "ok":
        return {"status": "ready"}
    return problem_response(
        ServiceUnavailable(
            "The service is not ready.", checks={"database": database, "migrations": migrations}
        ),
        public_base_url=services.settings.public_base_url,
        request_id=get_request_id(request.scope),
    )
