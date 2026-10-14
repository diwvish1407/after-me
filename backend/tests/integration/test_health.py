from __future__ import annotations

import io
import json
import logging
from collections.abc import Iterator
from typing import Any

import httpx
import psycopg
import pytest

from app.api import health
from app.core.config import Settings
from app.core.logging import build_formatter
from app.main import create_app
from tests.support import problem


@pytest.fixture
def captured() -> Iterator[io.StringIO]:
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(build_formatter(json=True))
    root = logging.getLogger()
    previous = root.level
    root.addHandler(handler)
    root.setLevel(logging.DEBUG)
    try:
        yield stream
    finally:
        root.removeHandler(handler)
        root.setLevel(previous)


def _events(stream: io.StringIO, name: str) -> list[dict[str, Any]]:
    found = []
    for line in stream.getvalue().splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("event") == name:
            found.append(record)
    return found


async def test_live(client: httpx.AsyncClient) -> None:
    response = await client.get("/health/live")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_ready_when_database_is_at_head(client: httpx.AsyncClient) -> None:
    response = await client.get("/health/ready")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def _previous_revision() -> str:
    """The revision just before this image's head: a schema the code is AHEAD of."""
    (head,) = health.expected_heads()
    previous = health._scripts().get_revision(head).down_revision
    assert isinstance(previous, str)
    return previous


async def test_not_ready_when_the_code_is_ahead_of_the_schema(
    client: httpx.AsyncClient, owner_db: psycopg.Connection[dict[str, Any]]
) -> None:
    """The migration has not run: new code never serves an old schema."""
    (current,) = owner_db.execute("SELECT version_num FROM alembic_version").fetchone().values()
    owner_db.execute("UPDATE alembic_version SET version_num = %s", (_previous_revision(),))
    try:
        response = await client.get("/health/ready")
    finally:
        owner_db.execute("UPDATE alembic_version SET version_num = %s", (current,))
    assert response.status_code == 503
    body = problem(response)
    assert body["code"] == "service_unavailable"
    assert body["checks"] == {"database": "ok", "migrations": "not_at_head"}


async def test_not_ready_without_a_revision(
    client: httpx.AsyncClient, owner_db: psycopg.Connection[dict[str, Any]]
) -> None:
    (current,) = owner_db.execute("SELECT version_num FROM alembic_version").fetchone().values()
    owner_db.execute("DELETE FROM alembic_version")
    try:
        response = await client.get("/health/ready")
    finally:
        owner_db.execute("INSERT INTO alembic_version (version_num) VALUES (%s)", (current,))
    assert response.status_code == 503
    assert problem(response)["checks"] == {"database": "ok", "migrations": "missing"}


async def test_ready_when_the_schema_is_ahead_so_a_rollback_can_start(
    client: httpx.AsyncClient,
    owner_db: psycopg.Connection[dict[str, Any]],
    captured: io.StringIO,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """INF-1: after a release migrated to a revision this image has never heard of, the
    previous image (a rollback, or an old revision scaling out mid-deploy) must still become
    ready. Expand/contract keeps that schema compatible (docs/DEPLOYMENT.md §5)."""
    monkeypatch.setattr(health, "warn_schema_ahead", health._Once())
    (current,) = owner_db.execute("SELECT version_num FROM alembic_version").fetchone().values()
    owner_db.execute("UPDATE alembic_version SET version_num = '20991231_9999'")
    try:
        first = await client.get("/health/ready")
        second = await client.get("/health/ready")
    finally:
        owner_db.execute("UPDATE alembic_version SET version_num = %s", (current,))
    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json() == {"status": "ready"}
    [warning] = _events(captured, "health.schema_ahead")  # once per process, not per probe
    assert warning["database_revisions"] == ["20991231_9999"]


@pytest.mark.no_db
def test_schema_state_rules() -> None:
    heads = health.expected_heads()
    assert health.schema_state(heads) == "at_head"
    assert health.schema_state(frozenset({_previous_revision()})) == "behind"
    assert health.schema_state(frozenset({"unknown_future"})) == "ahead"
    assert health.schema_state(frozenset()) == "missing"


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
