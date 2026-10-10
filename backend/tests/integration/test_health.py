from __future__ import annotations

from typing import Any

import httpx
import psycopg
import pytest

from app.core.config import Settings
from app.main import create_app
from tests.support import problem


async def test_live(client: httpx.AsyncClient) -> None:
    response = await client.get("/health/live")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_ready_when_database_is_at_head(client: httpx.AsyncClient) -> None:
    response = await client.get("/health/ready")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


async def test_not_ready_when_revision_differs(
    client: httpx.AsyncClient, owner_db: psycopg.Connection[dict[str, Any]]
) -> None:
    (current,) = owner_db.execute("SELECT version_num FROM alembic_version").fetchone().values()
    owner_db.execute("UPDATE alembic_version SET version_num = 'stale'")
    try:
        response = await client.get("/health/ready")
    finally:
        owner_db.execute("UPDATE alembic_version SET version_num = %s", (current,))
    assert response.status_code == 503
    body = problem(response)
    assert body["code"] == "service_unavailable"
    assert body["checks"] == {"database": "ok", "migrations": "not_at_head"}


async def test_not_ready_when_database_unreachable(settings: Settings) -> None:
    broken = settings.model_copy(
        update={
            "database_url": settings.database_url.__class__(
                "postgresql+psycopg://afterme_api:wrong@127.0.0.1:1/afterme_test"
            )
        }
    )
    app = create_app(broken)
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="https://api.afterme.test") as c:
        response = await c.get("/health/ready")
    await app.state.services.db.dispose()
    assert response.status_code == 503
    assert problem(response)["checks"] == {"database": "unavailable", "migrations": "unknown"}


@pytest.mark.parametrize("path", ["/health/live", "/health/ready"])
async def test_health_has_no_client_version_gate(client: httpx.AsyncClient, path: str) -> None:
    response = await client.get(path, headers={"X-AfterMe-Client": "android/0.0.0+1"})
    assert response.status_code in (200, 503)
