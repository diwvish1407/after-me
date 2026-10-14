"""SEC-23: the test-support routes cannot be reached where they could do harm (TEST_PLAN §5.2).

Test support moves the clock for every account in the database it points at and reads mail from
disk. Four boundaries keep it out of any environment that matters; each is tested here:

1. it is refused at startup in production (``test_test_support.py``), **and** whenever the email
   provider is a real one, because moving time opens incidents and alerts real contacts;
2. a staging configuration cannot enable it either way (a real provider is refused with test
   support on; a development provider is refused in staging);
3. a production process that is told to enable it by its environment never gets as far as an app;
4. where it *is* mounted, every route, including the one that moves time backwards, answers 401
   without the token, and the guard sits on the router, not on each endpoint.

(That the route set is exactly the documented four is asserted in ``test_authorization_matrix.py``.)
"""

from __future__ import annotations

import base64
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import httpx
import pytest
from pydantic import ValidationError

from app.core.config import AppEnv, Settings, load_settings
from app.main import create_app
from app.testsupport import router as support_module
from tests.support import make_settings

TOKEN = "t" * 40
WHSEC = "whsec_" + base64.b64encode(b"0123456789abcdef0123456789abcdef").decode()
REAL_PROVIDERS: list[dict[str, Any]] = [
    {"email_provider": "resend", "email_api_key": "re_test_key_00000000"},
    {"email_provider": "postmark", "email_api_key": "pm_test_key_00000000"},
    {"email_provider": "smtp", "smtp_host": "smtp.example.test"},
]
# Everything a staging environment must set explicitly, so that the only thing left to refuse
# in the tests below is test support itself.
STAGING: dict[str, Any] = {
    "app_env": "staging",
    "public_base_url": "https://afterme.example",
    "api_base_url": "https://api.afterme.example",
    "argon2_time_cost": 3,
    "argon2_memory_cost_kib": 65536,
    "argon2_parallelism": 4,
    "trusted_proxy_hops": 1,
    "worker_database_url": "postgresql+psycopg://afterme_worker:secret@db/afterme?sslmode=verify-full",
    "maintenance_database_url": (
        "postgresql+psycopg://afterme_maintenance:secret@db/afterme?sslmode=verify-full"
    ),
    "probe_token": "p" * 48,
    "kms_provider": "gcp_kms",
    "kms_key_name": (
        "projects/afterme-prod/locations/asia-south1/keyRings/afterme/cryptoKeys/instruction-kek"
    ),
    "support_email": "support@afterme.example",
    "abuse_email": "abuse@afterme.example",
    "push_provider": "fcm",
    "fcm_project_id": "afterme-staging",
    "email_from": "AfterMe <alerts@mail.afterme.example>",
    "email_provider": "resend",
    "email_api_key": "re_test_key_00000000",
    "email_webhook_secret": WHSEC,
}

# --- 1 and 2: startup refuses it --------------------------------------------------------------


@pytest.mark.no_db
@pytest.mark.parametrize("provider", REAL_PROVIDERS, ids=lambda p: p["email_provider"])
def test_test_support_is_refused_with_a_real_email_provider(provider: dict[str, Any]) -> None:
    with pytest.raises(ValidationError, match="needs a development email provider"):
        make_settings(test_support_enabled=True, test_support_token=TOKEN, **provider)
    # the same settings without test support are fine, so the refusal is test support's
    assert make_settings(**provider).test_support_enabled is False


@pytest.mark.no_db
@pytest.mark.parametrize("provider", ["console", "recording"])
def test_test_support_is_allowed_with_a_development_provider_outside_production(
    provider: str,
) -> None:
    ok = make_settings(test_support_enabled=True, test_support_token=TOKEN, email_provider=provider)
    assert ok.test_support_enabled is True
    assert ok.app_env is AppEnv.TEST


def _problems(**values: Any) -> str:
    """What the configuration says is wrong with ``values`` (empty when it loads). Every problem
    is reported at once, so one of them being test support is visible whatever else is."""
    try:
        make_settings(**values)
    except ValidationError as exc:
        return str(exc)
    return ""


@pytest.mark.no_db
def test_a_staging_configuration_cannot_enable_test_support() -> None:
    # without test support, nothing in the configuration is about it
    assert "TEST_SUPPORT" not in _problems(**STAGING)
    # with a real provider (what staging has): refused because the provider is real
    real = _problems(**STAGING, test_support_enabled=True, test_support_token=TOKEN)
    assert "TEST_SUPPORT_ENABLED needs a development email provider" in real
    # with a development provider (what test support wants): refused because it is staging
    dev = {**STAGING, "email_provider": "recording", "email_api_key": None}
    development = _problems(**dev, test_support_enabled=True, test_support_token=TOKEN)
    assert "EMAIL_PROVIDER=recording is for development and tests" in development
    # ... and a development provider alone is no way into staging either
    assert "EMAIL_PROVIDER=recording is for development and tests" in _problems(**dev)


@pytest.mark.no_db
def test_test_support_is_refused_in_production_whatever_else_is_configured() -> None:
    prod = {**STAGING, "app_env": "prod"}
    assert "TEST_SUPPORT" not in _problems(**prod)
    for values in (prod, {**prod, "email_provider": "recording", "email_api_key": None}):
        refused = _problems(**values, test_support_enabled=True, test_support_token=TOKEN)
        assert "TEST_SUPPORT_ENABLED must never be set in production" in refused


# --- 3: the environment cannot force it on in production ---------------------------------------


@pytest.mark.no_db
@pytest.mark.parametrize(
    ("env", "reason"),
    [
        ("prod", "TEST_SUPPORT_ENABLED must never be set in production"),
        ("staging", "EMAIL_PROVIDER=console is for development and tests"),
    ],
)
def test_a_production_process_told_to_enable_test_support_does_not_start(
    env: str, reason: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("AFTERME_APP_ENV", env)
    monkeypatch.setenv("AFTERME_TEST_SUPPORT_ENABLED", "true")
    monkeypatch.setenv("AFTERME_TEST_SUPPORT_TOKEN", TOKEN)
    with pytest.raises(ValidationError) as refused:
        load_settings()
    message = str(refused.value)
    assert reason in message
    assert TOKEN not in message  # the secret is not echoed into the startup log


@pytest.mark.no_db
async def test_a_production_app_has_no_test_routes_at_all() -> None:
    prod = Settings.model_construct(
        **{**dict(make_settings()), "app_env": AppEnv.PROD},
        _fields_set=make_settings().model_fields_set,
    )
    app = create_app(prod)
    try:
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="https://api.afterme.test"
        ) as client:
            for method, path in (
                ("GET", "/test/clock"),
                ("POST", "/test/clock/advance"),
                ("POST", "/test/clock/reset"),
                ("GET", "/test/mail"),
            ):
                answered = await client.request(method, path, headers={"X-Test-Token": TOKEN})
                assert answered.status_code == 404, (method, path)
    finally:
        await app.state.services.db.dispose()


# --- 4: where it is mounted, the token guards every route --------------------------------------


@pytest.fixture
async def support(tmp_path: Path) -> AsyncIterator[httpx.AsyncClient]:
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


def test_the_guard_is_on_the_router_so_a_new_endpoint_cannot_skip_it() -> None:
    guards = [d.dependency for d in support_module.router.dependencies]
    assert support_module.require_token in guards
    # and every endpoint of it inherits that (FastAPI merges router dependencies into routes)
    assert support_module.router.routes


async def test_a_refused_reset_does_not_move_the_clock(support: httpx.AsyncClient) -> None:
    allowed = {"X-Test-Token": TOKEN}
    moved = await support.post("/test/clock/advance", json={"seconds": 3600}, headers=allowed)
    assert moved.json()["offset_seconds"] == 3600
    try:
        for headers in ({}, {"X-Test-Token": ""}, {"X-Test-Token": TOKEN[:-1]}):
            refused = await support.post("/test/clock/reset", headers=headers)
            assert refused.status_code == 401
            assert TOKEN not in refused.text  # not an oracle for the secret
            assert refused.headers["content-type"].startswith("application/problem+json")
        still = await support.get("/test/clock", headers=allowed)
        assert still.json()["offset_seconds"] == 3600  # the unauthenticated resets did nothing
        done = await support.post("/test/clock/reset", headers=allowed)
        assert done.json()["offset_seconds"] == 0
    finally:
        await support.post("/test/clock/reset", headers=allowed)  # leave no offset behind
