"""SEC-23: the test-only routes cannot be exposed (TEST_PLAN §5.2).

``/test/*`` moves the clock for the API *and* the worker and reads the mail the console provider
wrote: reachable in a real environment, it would open incidents and alert contacts for every
account. Four things keep it out, and each is tested here:

1. configuration refuses it with a real email provider, in staging and in production, and
   refuses it without a long token (``test_support_enabled`` is the only switch);
2. the guard is a dependency of the *router*, so no route in it can be added without the token,
   and it fails closed;
3. an unauthorised call does nothing (the clock is not moved or reset, no mail is read);
4. nothing is mounted at all unless the switch is on, and then the routes appear in no schema.

The route set itself and the 401 for every route are in ``test_authorization_matrix.py``
(``test_every_test_support_route_has_a_policy_and_a_token_guard``).
"""

from __future__ import annotations

import base64
from collections.abc import AsyncIterator
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import httpx
import psycopg
import pytest
from fastapi import FastAPI, HTTPException

from app.core.config import load_settings
from app.main import create_app
from app.testsupport.router import require_token
from tests.security.sec_support import snapshot
from tests.support import PASSWORD, make_settings
from tests.unit.test_config import SECURE_PROD

TOKEN = "t" * 40
KEY = "k" * 24
WEBHOOK_SECRET = "whsec_" + base64.b64encode(b"0123456789abcdef0123456789abcdef").decode()
Db = psycopg.Connection[dict[str, Any]]

# What a real provider needs to be configured at all, so that the refusal below is about test
# support and nothing else.
REAL_PROVIDERS = {
    "resend": {"email_api_key": KEY},
    "postmark": {"email_api_key": KEY},
    "smtp": {"smtp_host": "smtp.example.com"},
}


# --- 1. configuration ---------------------------------------------------------------------------


@pytest.mark.no_db
@pytest.mark.parametrize("provider", sorted(REAL_PROVIDERS))
def test_test_support_is_refused_with_a_real_email_provider(provider: str) -> None:
    provider_settings = REAL_PROVIDERS[provider]
    with pytest.raises(ValueError, match="needs a development email provider"):
        make_settings(
            test_support_enabled=True,
            test_support_token=TOKEN,
            email_provider=provider,
            **provider_settings,
        )
    # control: the same provider is a valid configuration without test support, and test support
    # is a valid configuration with a development provider: only the pair is refused
    assert make_settings(email_provider=provider, **provider_settings).email_provider == provider
    for development in ("console", "recording"):
        accepted = make_settings(
            test_support_enabled=True, test_support_token=TOKEN, email_provider=development
        )
        assert accepted.test_support_enabled


@pytest.mark.no_db
def test_test_support_needs_a_long_token_and_is_off_by_default() -> None:
    assert make_settings().test_support_enabled is False
    for token in (None, "", "short", "t" * 31):
        with pytest.raises(ValueError, match="TEST_SUPPORT_TOKEN is required"):
            make_settings(
                test_support_enabled=True, test_support_token=token, email_provider="console"
            )
    ok = make_settings(
        test_support_enabled=True, test_support_token="t" * 32, email_provider="console"
    )
    assert ok.test_support_enabled


def _production_like(env: str, provider: str, **extra: Any) -> dict[str, Any]:
    """A production-like configuration that is otherwise correct for ``provider``."""
    values: dict[str, Any] = {**SECURE_PROD, "app_env": env, "email_provider": provider}
    if provider == "resend":
        values.update(email_api_key=KEY, email_webhook_secret=WEBHOOK_SECRET)
    values.update(extra)
    return values


@pytest.mark.no_db
@pytest.mark.parametrize("env", ["prod", "staging"])
def test_a_correct_production_like_configuration_loads_without_test_support(env: str) -> None:
    """The control for the refusals below: it is the switch that is refused."""
    settings = make_settings(**_production_like(env, "resend"))
    assert settings.is_production_like
    assert settings.test_support_enabled is False


@pytest.mark.no_db
@pytest.mark.parametrize("provider", ["console", "recording", "resend"])
def test_production_refuses_test_support_with_any_email_provider(provider: str) -> None:
    with pytest.raises(ValueError, match="TEST_SUPPORT_ENABLED must never be set in production"):
        make_settings(
            **_production_like(
                "prod", provider, test_support_enabled=True, test_support_token=TOKEN
            )
        )


@pytest.mark.no_db
@pytest.mark.parametrize(
    ("provider", "reason"),
    [
        ("console", "EMAIL_PROVIDER=console is for development and tests"),
        ("recording", "EMAIL_PROVIDER=recording is for development and tests"),
        ("resend", "TEST_SUPPORT_ENABLED needs a development email provider"),
    ],
)
def test_staging_refuses_test_support_with_any_email_provider(provider: str, reason: str) -> None:
    """Staging has no way to turn it on: a development provider is refused there, and a real one
    is refused by test support (docs/API_SPEC §14 says staging uses it: the build is stricter)."""
    with pytest.raises(ValueError, match=reason):
        make_settings(
            **_production_like(
                "staging", provider, test_support_enabled=True, test_support_token=TOKEN
            )
        )


@pytest.mark.no_db
def test_the_environment_alone_cannot_switch_it_on_in_production(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The way a deployment would really get it wrong: one environment variable."""
    monkeypatch.setenv("AFTERME_APP_ENV", "prod")
    monkeypatch.setenv("AFTERME_TEST_SUPPORT_ENABLED", "true")
    monkeypatch.setenv("AFTERME_TEST_SUPPORT_TOKEN", TOKEN)
    with pytest.raises(ValueError, match="TEST_SUPPORT_ENABLED must never be set in production"):
        load_settings()


# --- 2. the guard fails closed -----------------------------------------------------------------


async def test_the_guard_refuses_when_no_token_is_configured() -> None:
    """Configuration already refuses the state; the guard must not depend on that."""
    unconfigured = SimpleNamespace(settings=SimpleNamespace(test_support_token=None))
    for presented in (None, "", "None", "null", TOKEN):
        with pytest.raises(HTTPException) as caught:
            await require_token(unconfigured, presented)  # type: ignore[arg-type]
        assert caught.value.status_code == 401


async def test_the_guard_compares_the_whole_token() -> None:
    configured = make_settings(
        test_support_enabled=True, test_support_token=TOKEN, email_provider="console"
    )
    services: Any = SimpleNamespace(settings=configured)
    assert await require_token(services, TOKEN) is None
    for presented in (None, "", TOKEN[:-1], TOKEN + "t", TOKEN.upper(), " " + TOKEN):
        with pytest.raises(HTTPException) as caught:
            await require_token(services, presented)
        assert caught.value.status_code == 401, presented


# --- 3. an unauthorised call does nothing -------------------------------------------------------


@pytest.fixture
async def support_app(tmp_path: Path) -> AsyncIterator[FastAPI]:
    app = create_app(
        make_settings(
            test_support_enabled=True,
            test_support_token=TOKEN,
            email_provider="console",
            dev_mail_dir=tmp_path / "mail",
            rate_limit_enabled=False,
        )
    )
    yield app
    await app.state.services.db.dispose()


@pytest.fixture
async def support(support_app: FastAPI) -> AsyncIterator[httpx.AsyncClient]:
    transport = httpx.ASGITransport(app=support_app, client=("203.0.113.10", 51000))
    async with httpx.AsyncClient(transport=transport, base_url="https://api.afterme.test") as c:
        yield c


AUTHORISED = {"X-Test-Token": TOKEN}
WRONG_TOKENS: list[dict[str, str]] = [
    {},
    {"X-Test-Token": ""},
    {"X-Test-Token": "wrong"},
    {"X-Test-Token": TOKEN[:-1]},
    {"X-Test-Token": "t" * 41},
    {"Authorization": f"Bearer {TOKEN}"},  # the right secret in the wrong header
    {"X-Probe-Token": TOKEN},
]


async def test_unauthorised_calls_neither_move_nor_reset_the_clock(
    support: httpx.AsyncClient, owner_db: Db
) -> None:
    moved = await support.post("/test/clock/advance", json={"seconds": 3600}, headers=AUTHORISED)
    assert moved.status_code == 200
    assert moved.json()["offset_seconds"] == 3600
    before = snapshot(owner_db, ["system_flags"])
    assert any("test_clock_offset_seconds" in row for row in before["system_flags"])

    for headers in WRONG_TOKENS:
        for method, path, body in (
            ("POST", "/test/clock/advance", {"seconds": 86_400}),
            ("POST", "/test/clock/reset", None),
            ("GET", "/test/clock", None),
        ):
            refused = await support.request(method, path, json=body, headers=headers)
            assert refused.status_code == 401, (method, path, headers)
            assert "offset_seconds" not in refused.text
    # the 401s did not touch the stored offset ...
    assert snapshot(owner_db, ["system_flags"]) == before
    # ... and the token still reads 3600, not 0 (reset) and not 90 000 (advance)
    state = await support.get("/test/clock", headers=AUTHORISED)
    assert state.json()["offset_seconds"] == 3600

    # control: with the token, reset really does reset (so a no-op above would be visible)
    reset = await support.post("/test/clock/reset", headers=AUTHORISED)
    assert reset.json()["offset_seconds"] == 0


async def test_the_mail_reader_shows_nothing_without_the_token(
    support: httpx.AsyncClient, tmp_path: Path
) -> None:
    started = await support.post(
        "/v1/auth/register/start",
        json={
            "email": "reader@example.com",
            "password": PASSWORD,
            "display_name": "Reader",
            "timezone": "Asia/Kolkata",
            "locale": "en",
        },
    )
    assert started.status_code == 202, started.text
    assert list((tmp_path / "mail").glob("*.txt")), "the console provider wrote the code"

    shown = await support.get("/test/mail", params={"to": "reader@example.com"}, headers=AUTHORISED)
    assert shown.status_code == 200
    assert len(shown.json()["messages"]) == 1

    for headers in WRONG_TOKENS:
        refused = await support.get(
            "/test/mail", params={"to": "reader@example.com"}, headers=headers
        )
        assert refused.status_code == 401, headers
        assert "reader@example.com" not in refused.text
        assert "signup_code" not in refused.text


async def test_the_routes_are_in_no_schema(support: httpx.AsyncClient) -> None:
    """Test support is not advertised, even to someone who can read the docs (non-production)."""
    schema = await support.get("/v1/openapi.json")
    assert schema.status_code == 200
    assert "/test" not in schema.text
    assert "X-Test-Token" not in schema.text


# --- 4. nothing is mounted unless the switch is on ---------------------------------------------


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("GET", "/test/clock"),
        ("POST", "/test/clock/advance"),
        ("POST", "/test/clock/reset"),
        ("GET", "/test/mail"),
    ],
)
async def test_without_the_switch_the_routes_do_not_exist_even_with_a_token(
    client: httpx.AsyncClient, owner_db: Db, method: str, path: str
) -> None:
    before = snapshot(owner_db)
    response = await client.request(method, path, json={"seconds": 60}, headers=AUTHORISED)
    assert response.status_code == 404
    assert snapshot(owner_db) == before
