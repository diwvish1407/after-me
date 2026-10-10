"""Routes that exist only in tests (never registered by ``create_app``)."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Body, Response
from sqlalchemy import text

from app.api.deps import DbSession, ReauthUserDep

test_router = APIRouter(prefix="/v1/_test", tags=["test-only"])


@test_router.get("/reauth", status_code=204, response_class=Response)
async def reauth_protected(current: ReauthUserDep) -> Response:
    assert current.user_id
    return Response(status_code=204)


@test_router.get("/boom")
async def boom() -> None:
    msg = "internal detail for leak@example.com at /srv/secret"
    raise RuntimeError(msg)


@test_router.get("/slow")
async def slow(session: DbSession) -> dict[str, str]:
    await session.execute(text("SELECT pg_sleep(5)"))
    return {"status": "finished"}


@test_router.get("/db-error")
async def db_error(session: DbSession) -> dict[str, str]:
    await session.execute(text("SELECT 1/0"))
    return {"status": "unreachable"}


@test_router.post("/echo")
async def echo(payload: dict[str, Any] = Body(...)) -> dict[str, int]:  # noqa: B008
    return {"keys": len(payload)}
