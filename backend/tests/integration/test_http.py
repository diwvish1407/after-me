"""HTTP plumbing: problem+json shapes, request IDs, security headers, body limit, version gate."""

from __future__ import annotations

import io
import json
import logging
from collections.abc import AsyncIterator

import httpx
import pytest

from app.core.config import AppEnv, Settings
from app.core.logging import build_formatter
from app.main import create_app
from tests.support import make_settings, problem


async def test_unknown_route_is_problem_404(client: httpx.AsyncClient) -> None:
    response = await client.get("/v1/does-not-exist")
    assert response.status_code == 404
    assert problem(response)["code"] == "not_found"


async def test_wrong_method_is_problem_405_with_allow(client: httpx.AsyncClient) -> None:
    response = await client.put("/v1/me")
    assert response.status_code == 405
    assert problem(response)["code"] == "method_not_allowed"
    assert response.headers["allow"] == "GET"


async def test_validation_error_shape(client: httpx.AsyncClient) -> None:
    response = await client.post(
        "/v1/auth/login",
        json={"email": "nope", "device": {"platform": "ios"}, "tier": "premium"},
    )
    assert response.status_code == 422
    body = problem(response)
    assert body["code"] == "validation_failed"
    errors = {(e["field"], e["code"]) for e in body["errors"]}
    assert ("email", "invalid_email") in errors
    assert ("password", "required") in errors
    assert ("device.platform", "invalid_choice") in errors
    assert ("device.app_version", "required") in errors
    assert ("tier", "unknown_field") in errors
    assert all(set(e) == {"field", "code", "message"} for e in body["errors"])


async def test_validation_errors_never_echo_input(client: httpx.AsyncClient) -> None:
    secret = "my-very-secret-password-value"
    response = await client.post(
        "/v1/auth/register/start",
        json={"email": "x@example.com", "password": secret, "display_name": "", "tz": secret},
    )
    assert response.status_code == 422
    assert secret not in response.text


async def test_malformed_json_is_422(client: httpx.AsyncClient) -> None:
    response = await client.post(
        "/v1/auth/login", content=b"{not json", headers={"content-type": "application/json"}
    )
    assert response.status_code == 422
    assert problem(response)["errors"][0]["code"] == "invalid_json"


async def test_body_over_64kb_is_413_by_content_length(client: httpx.AsyncClient) -> None:
    response = await client.post(
        "/v1/_test/echo",
        content=json.dumps({"x": "a" * 70_000}).encode(),
        headers={"content-type": "application/json"},
    )
    assert response.status_code == 413
    assert problem(response)["code"] == "payload_too_large"


async def test_streamed_body_over_64kb_is_413(client: httpx.AsyncClient) -> None:
    async def chunks() -> AsyncIterator[bytes]:
        yield b'{"x": "'
        for _ in range(20):
            yield b"a" * 4096
        yield b'"}'

    response = await client.post(
        "/v1/_test/echo", content=chunks(), headers={"content-type": "application/json"}
    )
    assert response.status_code == 413
    assert problem(response)["code"] == "payload_too_large"


async def test_body_under_limit_is_accepted(client: httpx.AsyncClient) -> None:
    response = await client.post("/v1/_test/echo", json={"x": "a" * 60_000})
    assert response.status_code == 200
    assert response.json() == {"keys": 1}


async def test_bogus_content_length_is_rejected(client: httpx.AsyncClient) -> None:
    response = await client.post(
        "/v1/_test/echo",
        content=b"{}",
        headers={"content-type": "application/json", "content-length": "abc"},
    )
    assert response.status_code == 413


async def test_request_id_is_echoed_or_generated(client: httpx.AsyncClient) -> None:
    echoed = await client.get("/health/live", headers={"X-Request-ID": "abc-123_x.y"})
    assert echoed.headers["x-request-id"] == "abc-123_x.y"
    generated = await client.get("/health/live")
    assert len(generated.headers["x-request-id"]) == 32
    unsafe = await client.get("/health/live", headers={"X-Request-ID": "bad id\twith spaces"})
    assert unsafe.headers["x-request-id"] != "bad id\twith spaces"
    error = await client.get("/v1/nope", headers={"X-Request-ID": "trace-1"})
    assert problem(error)["request_id"] == "trace-1"


async def test_security_headers(client: httpx.AsyncClient) -> None:
    for response in (await client.get("/health/live"), await client.get("/v1/me")):
        assert response.headers["cache-control"] == "no-store"
        assert response.headers["x-content-type-options"] == "nosniff"
        assert response.headers["referrer-policy"] == "no-referrer"
        assert response.headers["x-frame-options"] == "DENY"
        assert "frame-ancestors 'none'" in response.headers["content-security-policy"]
        assert "strict-transport-security" not in response.headers  # test env


async def test_hsts_outside_dev_and_test(settings: Settings) -> None:
    staging = Settings.model_construct(
        **{**dict(settings), "app_env": AppEnv.STAGING}, _fields_set=settings.model_fields_set
    )
    app = create_app(staging)
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="https://api.afterme.test"
    ) as c:
        response = await c.get("/health/live")
        docs = await c.get("/v1/openapi.json")
    await app.state.services.db.dispose()
    assert response.headers["strict-transport-security"].startswith("max-age=")
    assert docs.status_code == 200  # docs exist outside prod


async def test_openapi_and_docs_are_disabled_in_prod(settings: Settings) -> None:
    prod = Settings.model_construct(
        **{**dict(settings), "app_env": AppEnv.PROD}, _fields_set=settings.model_fields_set
    )
    app = create_app(prod)
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="https://api.afterme.test"
    ) as c:
        for path in ("/v1/openapi.json", "/v1/docs", "/v1/docs/oauth2-redirect", "/docs"):
            assert (await c.get(path)).status_code == 404
    await app.state.services.db.dispose()


async def test_docs_available_in_test(client: httpx.AsyncClient) -> None:
    response = await client.get("/v1/openapi.json")
    assert response.status_code == 200
    assert "/v1/auth/login" in response.json()["paths"]
    docs = await client.get("/v1/docs")
    assert docs.status_code == 200
    assert "content-security-policy" not in docs.headers


@pytest.mark.settings(min_client_version="1.2.0")
async def test_client_version_gate(client: httpx.AsyncClient) -> None:
    old = await client.get("/v1/me", headers={"X-AfterMe-Client": "android/1.1.9+40"})
    assert old.status_code == 426
    assert problem(old)["code"] == "upgrade_required"
    for header in ("android/1.2.0+41", "android/2.0.0", "garbage", ""):
        response = await client.get("/v1/me", headers={"X-AfterMe-Client": header})
        assert response.status_code == 401, header  # passes the gate, then needs a token
    assert (await client.get("/v1/me")).status_code == 401  # header missing: allowed
    health = await client.get("/health/live", headers={"X-AfterMe-Client": "android/0.0.1"})
    assert health.status_code == 200


async def test_unhandled_error_is_generic_500(client: httpx.AsyncClient) -> None:
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(build_formatter(json=True))
    logging.getLogger().addHandler(handler)
    try:
        response = await client.get("/v1/_test/boom")
    finally:
        logging.getLogger().removeHandler(handler)
    assert response.status_code == 500
    body = problem(response)
    assert body["code"] == "internal_error"
    assert "leak@example.com" not in response.text
    assert "internal detail" not in response.text
    assert "RuntimeError" not in response.text
    logs = stream.getvalue()
    assert "RuntimeError" in logs
    assert "internal detail" not in logs
    assert "leak@example.com" not in logs


@pytest.mark.settings(db_statement_timeout_ms=200)
async def test_statement_timeout_is_retryable_503(client: httpx.AsyncClient) -> None:
    response = await client.get("/v1/_test/slow")
    assert response.status_code == 503
    assert problem(response)["code"] == "service_unavailable"
    assert response.headers["retry-after"] == "1"


async def test_database_error_is_generic_500(client: httpx.AsyncClient) -> None:
    response = await client.get("/v1/_test/db-error")
    assert response.status_code == 500
    assert problem(response)["code"] == "internal_error"
    assert "division" not in response.text.lower()


def test_make_settings_helper_is_test_env() -> None:
    assert make_settings().app_env is AppEnv.TEST
