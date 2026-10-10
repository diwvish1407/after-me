"""Rate limits (API_SPEC §16; TEST_PLAN SEC-09, SEC-21)."""

from __future__ import annotations

from typing import Any

import httpx
import psycopg
import pytest
from fastapi import FastAPI

from tests.support import Harness, bearer, problem

Db = psycopg.Connection[dict[str, Any]]


def _client_from(app: FastAPI, ip: str) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app, client=(ip, 52000)),
        base_url="https://api.afterme.test",
    )


def _assert_429(response: httpx.Response) -> None:
    assert response.status_code == 429, response.text
    assert problem(response)["code"] == "rate_limited"
    assert int(response.headers["retry-after"]) >= 1
    assert response.headers["ratelimit-remaining"] == "0"
    assert int(response.headers["ratelimit-limit"]) >= 1
    assert int(response.headers["ratelimit-reset"]) >= 1


async def test_login_per_ip(h: Harness, owner_db: Db) -> None:
    for i in range(10):
        response = await h.login(f"user{i}@example.com", "some password here")
        assert response.status_code == 401
    _assert_429(await h.login("user99@example.com", "some password here"))
    keys = [r["key"] for r in owner_db.execute("SELECT key FROM rate_limit_counters").fetchall()]
    assert all("203.0.113.10" not in k and "@" not in k for k in keys)  # HMAC'd subjects only
    # Another IP is unaffected.
    async with _client_from(h.app, "198.51.100.20") as other:
        response = await other.post(
            "/v1/auth/login",
            json={
                "email": "user0@example.com",
                "password": "some password here",
                "device": {
                    "platform": "android",
                    "app_version": "1.0.0",
                    "os_version": "15",
                    "locale": "en",
                },
            },
        )
        assert response.status_code == 401


async def test_login_per_account_across_ips(h: Harness) -> None:
    await h.signup("target@example.com")
    for i in range(5):
        async with _client_from(h.app, f"198.51.100.{i + 1}") as c:
            h.client = c
            assert (await h.login("target@example.com", "wrong guess number")).status_code == 401
    async with _client_from(h.app, "198.51.100.200") as c:
        h.client = c
        _assert_429(await h.login("target@example.com"))  # even the right password
        h.clock.advance(minutes=15)
        assert (await h.login("target@example.com")).status_code == 200


async def test_forwarded_for_is_ignored_without_trusted_proxies(h: Harness) -> None:
    for i in range(10):
        response = await h.login(
            "spoof@example.com", "wrong password", headers={"X-Forwarded-For": f"10.9.8.{i}"}
        )
        assert response.status_code in (401, 429)
    _assert_429(
        await h.login("other@example.com", "wrong password", headers={"X-Forwarded-For": "1.1.1.1"})
    )


@pytest.mark.settings(trusted_proxy_hops=1)
async def test_forwarded_for_spoofing_beyond_trusted_hops(h: Harness) -> None:
    # Behind one proxy: the client is the right-most entry. Entries further left are spoofable.
    for i in range(10):
        response = await h.login(
            f"s{i}@example.com",
            "wrong password",
            headers={"X-Forwarded-For": f"6.6.6.{i}, 192.0.2.50"},
        )
        assert response.status_code == 401
    _assert_429(
        await h.login(
            "s99@example.com", "wrong password", headers={"X-Forwarded-For": "7.7.7.7, 192.0.2.50"}
        )
    )
    # A genuinely different client (as reported by the trusted proxy) is not limited.
    response = await h.login(
        "s100@example.com", "wrong password", headers={"X-Forwarded-For": "192.0.2.51"}
    )
    assert response.status_code == 401


async def test_register_start_per_ip_and_per_email(h: Harness) -> None:
    for _ in range(3):
        assert (await h.register("same@example.com")).status_code == 202
    _assert_429(await h.register("same@example.com"))
    assert (await h.register("different@example.com")).status_code == 202
    _assert_429(await h.register("third@example.com"))  # 6th request from this IP this hour
    h.clock.advance(hours=1)
    assert (await h.register("third@example.com")).status_code == 202


async def test_resend_shares_the_register_limits(h: Harness) -> None:
    await h.register("shared@example.com")
    for _ in range(2):
        h.clock.advance(seconds=61)
        response = await h.client.post(
            "/v1/auth/register/resend", json={"email": "shared@example.com"}
        )
        assert response.status_code == 202
    h.clock.advance(seconds=61)
    _assert_429(
        await h.client.post("/v1/auth/register/resend", json={"email": "shared@example.com"})
    )


async def test_verify_per_ip(h: Harness) -> None:
    for _ in range(20):
        assert (await h.verify("nobody@example.com", "123456")).status_code == 400
    _assert_429(await h.verify("nobody@example.com", "123456"))


async def test_reauth_per_session(h: Harness) -> None:
    tokens = await h.signup("re@example.com")
    for _ in range(5):
        assert (await h.reauth(tokens, "wrong password value")).status_code == 401
    _assert_429(await h.reauth(tokens))
    other = (await h.login("re@example.com")).json()
    assert (await h.reauth(other)).status_code == 204  # a different session has its own budget


async def test_default_unauthenticated_limit_per_ip(h: Harness) -> None:
    for _ in range(60):
        assert (await h.refresh("rt_unknown_token_value_000000000000000")).status_code == 401
    _assert_429(await h.refresh("rt_unknown_token_value_000000000000000"))


async def test_default_authenticated_limit_per_user(h: Harness) -> None:
    tokens = await h.signup("busy@example.com")
    for _ in range(300):
        response = await h.client.get("/v1/me", headers=bearer(tokens))
        assert response.status_code == 200
    assert response.headers["ratelimit-limit"] == "300"
    assert response.headers["ratelimit-remaining"] == "0"
    _assert_429(await h.client.get("/v1/me", headers=bearer(tokens)))
    h.clock.advance(minutes=1)
    assert (await h.client.get("/v1/me", headers=bearer(tokens))).status_code == 200


async def test_refresh_per_session(h: Harness) -> None:
    tokens = await h.signup("refresher@example.com")
    current = tokens["refresh_token"]
    for i in range(60):
        async with _client_from(h.app, f"10.0.{i // 50}.{i % 50 + 1}") as c:
            h.client = c
            response = await h.refresh(current)
            assert response.status_code == 200, i
            current = response.json()["refresh_token"]
    async with _client_from(h.app, "10.1.1.1") as c:
        h.client = c
        _assert_429(await h.refresh(current))


async def test_success_responses_carry_ratelimit_headers(h: Harness) -> None:
    response = await h.register("headers@example.com")
    assert response.status_code == 202
    assert response.headers["ratelimit-limit"] == "3"  # the most restrictive: 3/h per email
    assert response.headers["ratelimit-remaining"] == "2"


@pytest.mark.no_rate_limit
async def test_rate_limiting_can_be_disabled_for_tests(h: Harness, owner_db: Db) -> None:
    for _ in range(12):
        assert (await h.login("free@example.com", "some password here")).status_code == 401
    assert owner_db.execute("SELECT count(*) AS n FROM rate_limit_counters").fetchone() == {"n": 0}


@pytest.mark.settings(trusted_proxy_hops=1)
async def test_ipv6_clients_are_limited_per_64_not_per_address(h: Harness) -> None:
    """Rotating addresses inside one /64 must not buy a fresh per-IP allowance."""
    for i in range(10):
        response = await h.login(
            f"v6-{i}@example.com",
            "wrong password",
            headers={"X-Forwarded-For": f"2001:db8:aaaa:1::{i + 1:x}"},
        )
        assert response.status_code == 401
    same_64 = await h.login(
        "v6-next@example.com",
        "wrong password",
        headers={"X-Forwarded-For": "2001:db8:aaaa:1::ffff"},
    )
    _assert_429(same_64)
    other_64 = await h.login(
        "v6-other@example.com", "wrong password", headers={"X-Forwarded-For": "2001:db8:aaaa:2::1"}
    )
    assert other_64.status_code == 401
