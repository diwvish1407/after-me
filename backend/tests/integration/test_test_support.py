"""Test support (TEST_PLAN §2): the movable clock and the mail reader, and the rules that keep
them out of production."""

from __future__ import annotations

import re
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import pytest

from app.core.config import Settings
from app.main import create_app
from tests.support import PASSWORD, make_settings

TOKEN = "t" * 40


@pytest.fixture
async def support_client(tmp_path: Path) -> AsyncIterator[httpx.AsyncClient]:
    settings = make_settings(
        test_support_enabled=True,
        test_support_token=TOKEN,
        email_provider="console",
        dev_mail_dir=tmp_path / "mail",
        rate_limit_enabled=False,
    )
    app = create_app(settings)
    transport = httpx.ASGITransport(app=app, client=("203.0.113.10", 51000))
    async with httpx.AsyncClient(transport=transport, base_url="https://api.afterme.test") as c:
        yield c
    await app.state.services.db.dispose()


def _headers(token: str | None = TOKEN) -> dict[str, str]:
    return {} if token is None else {"X-Test-Token": token}


async def test_nothing_is_mounted_unless_enabled(client: httpx.AsyncClient) -> None:
    for path in ("/test/clock", "/test/mail"):
        assert (await client.get(path)).status_code == 404


async def test_every_call_needs_the_token(support_client: httpx.AsyncClient) -> None:
    for token in (None, "wrong", TOKEN[:-1]):
        assert (await support_client.get("/test/clock", headers=_headers(token))).status_code == 401
        advance = await support_client.post(
            "/test/clock/advance", json={"seconds": 60}, headers=_headers(token)
        )
        assert advance.status_code == 401
    assert (await support_client.get("/test/mail", headers=_headers(None))).status_code == 401
    assert (await support_client.get("/test/clock", headers=_headers())).status_code == 200


async def test_the_clock_moves_forward_for_everything_that_reads_it(
    support_client: httpx.AsyncClient,
) -> None:
    before = (await support_client.get("/test/clock", headers=_headers())).json()
    assert before["offset_seconds"] == 0

    moved = await support_client.post(
        "/test/clock/advance", json={"seconds": 3 * 86_400 + 90}, headers=_headers()
    )
    assert moved.status_code == 200
    state = moved.json()
    assert state["offset_seconds"] == 3 * 86_400 + 90
    now = datetime.now(UTC)
    shown = datetime.fromisoformat(state["server_time"])
    assert abs(shown - (now + timedelta(days=3, seconds=90))) < timedelta(seconds=10)

    again = await support_client.post(
        "/test/clock/advance", json={"seconds": 10}, headers=_headers()
    )
    assert again.json()["offset_seconds"] == 3 * 86_400 + 100

    # an ordinary endpoint reports the same time (the services share one clock)
    health = await support_client.get("/test/clock", headers=_headers())
    assert health.json()["offset_seconds"] == 3 * 86_400 + 100

    reset = await support_client.post("/test/clock/reset", headers=_headers())
    assert reset.json()["offset_seconds"] == 0


async def test_bad_steps_are_refused(support_client: httpx.AsyncClient) -> None:
    for seconds in (0, -5, 400 * 86_400 + 1):
        response = await support_client.post(
            "/test/clock/advance", json={"seconds": seconds}, headers=_headers()
        )
        assert response.status_code == 422, seconds
    extra = await support_client.post(
        "/test/clock/advance", json={"seconds": 5, "days": 1}, headers=_headers()
    )
    assert extra.status_code == 422
    state = await support_client.get("/test/clock", headers=_headers())
    assert state.json()["offset_seconds"] == 0


async def test_the_mail_reader_returns_what_the_console_provider_wrote(
    support_client: httpx.AsyncClient,
) -> None:
    body = {
        "email": "reader@example.com",
        "password": PASSWORD,
        "display_name": "Reader",
        "timezone": "Asia/Kolkata",
        "locale": "en",
    }
    started = await support_client.post("/v1/auth/register/start", json=body)
    assert started.status_code == 202, started.text

    found = await support_client.get(
        "/test/mail",
        params={"to": "Reader@Example.com", "template": "signup_code"},
        headers=_headers(),
    )
    messages = found.json()["messages"]
    assert len(messages) == 1
    assert messages[0]["template"] == "signup_code"
    assert messages[0]["to"] == "reader@example.com"
    assert re.search(r"\b\d{6}\b", messages[0]["text"]) is not None

    other = await support_client.get(
        "/test/mail", params={"to": "someone@else.com"}, headers=_headers()
    )
    assert other.json() == {"messages": []}
    bad = await support_client.get("/test/mail", params={"template": "../x"}, headers=_headers())
    assert bad.status_code == 422


def test_test_support_is_refused_in_production_and_needs_a_token_outside_tests() -> None:
    with pytest.raises(ValueError, match="never be set in production"):
        make_settings(app_env="prod", test_support_enabled=True, test_support_token=TOKEN)
    owasp = {"argon2_time_cost": 3, "argon2_memory_cost_kib": 65_536, "argon2_parallelism": 4}
    with pytest.raises(ValueError, match="TEST_SUPPORT_TOKEN is required"):
        make_settings(app_env="dev", test_support_enabled=True, **owasp)
    with pytest.raises(ValueError, match="TEST_SUPPORT_TOKEN is required"):
        make_settings(app_env="dev", test_support_enabled=True, test_support_token="short", **owasp)
    ok = make_settings(
        app_env="dev",
        test_support_enabled=True,
        test_support_token=TOKEN,
        argon2_time_cost=3,
        argon2_memory_cost_kib=65_536,
        argon2_parallelism=4,
    )
    assert isinstance(ok, Settings)
    assert make_settings().test_support_enabled is False
