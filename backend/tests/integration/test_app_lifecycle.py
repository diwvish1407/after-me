"""Application lifecycle, the module-level app, and the production database clock."""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from datetime import timedelta
from typing import Any

import httpx
import pytest
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import DbClock
from app.core.config import Settings
from app.main import create_app
from app.notifications.email import RecordingEmailProvider
from tests.support import DEVICE, PASSWORD, bearer, jwt_private_key_pem


async def test_lifespan_runs_through_the_middleware_stack(settings: Settings) -> None:
    app = create_app(settings)
    sent: list[dict[str, Any]] = []
    messages = iter([{"type": "lifespan.startup"}, {"type": "lifespan.shutdown"}])

    async def receive() -> dict[str, Any]:
        return next(messages)

    async def send(message: dict[str, Any]) -> None:
        sent.append(message)

    await app({"type": "lifespan", "asgi": {"version": "3.0"}, "state": {}}, receive, send)
    assert [m["type"] for m in sent] == [
        "lifespan.startup.complete",
        "lifespan.shutdown.complete",
    ]


def test_module_level_app_is_created_lazily_once(monkeypatch: pytest.MonkeyPatch) -> None:
    import app.main as main_module

    monkeypatch.setenv("AFTERME_APP_ENV", "test")
    monkeypatch.setenv("AFTERME_HMAC_PEPPER", "p" * 40)
    monkeypatch.setenv("AFTERME_JWT_SIGNING_KEYS", json.dumps({"k1": jwt_private_key_pem()}))
    monkeypatch.setenv("AFTERME_JWT_ACTIVE_KID", "k1")
    monkeypatch.setenv("AFTERME_ARGON2_TIME_COST", "1")
    monkeypatch.setenv("AFTERME_ARGON2_MEMORY_COST_KIB", "1024")
    monkeypatch.setattr(main_module, "_app", None)
    first = main_module.app
    assert isinstance(first, FastAPI)
    assert main_module.app is first
    with pytest.raises(AttributeError):
        _ = main_module.not_there  # type: ignore[attr-defined]
    await_dispose = first.state.services.db.dispose  # no connections were opened
    assert callable(await_dispose)


async def test_full_flow_with_the_database_clock(settings: Settings) -> None:
    """Production uses DbClock (PostgreSQL now()); the whole auth flow must work with it."""
    mail = RecordingEmailProvider()
    app = create_app(settings, clock=DbClock(), email_provider=mail)
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="https://api.afterme.test"
    ) as client:
        start = await client.post(
            "/v1/auth/register/start",
            json={
                "email": "dbclock@example.com",
                "password": PASSWORD,
                "display_name": "Clock",
                "timezone": "UTC",
            },
        )
        assert start.status_code == 202
        code = next(w for w in mail.messages[-1].text.split() if w.rstrip(".").isdigit())
        verified = await client.post(
            "/v1/auth/register/verify",
            json={
                "email": "dbclock@example.com",
                "code": code.rstrip("."),
                "password": PASSWORD,
                "device": DEVICE,
            },
        )
        assert verified.status_code == 201, verified.text
        tokens = verified.json()
        assert (await client.get("/v1/me", headers=bearer(tokens))).status_code == 200
        refreshed = await client.post(
            "/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]}
        )
        assert refreshed.status_code == 200
    await app.state.services.db.dispose()


async def test_db_clock_is_constant_within_a_transaction(settings: Settings) -> None:
    app = create_app(settings)
    clock = DbClock()
    async with app.state.services.db.sessionmaker() as session:
        session: AsyncSession
        first = await clock.now(session)
        second = await clock.now(session)
        assert first == second
        assert first.utcoffset() == timedelta(0)
        await session.rollback()
        third = await clock.now(session)
        assert third >= first
    await app.state.services.db.dispose()


async def test_error_after_response_started_is_contained(app: FastAPI) -> None:
    async def body() -> AsyncIterator[bytes]:
        yield b"partial"
        msg = "boom after start"
        raise RuntimeError(msg)

    @app.get("/v1/_test/stream-error")
    async def stream_error() -> StreamingResponse:
        return StreamingResponse(body())

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="https://api.afterme.test") as c:
        # The response had started, so the error propagates and the server aborts the stream.
        with pytest.raises(RuntimeError, match="boom after start"):
            await c.get("/v1/_test/stream-error")
