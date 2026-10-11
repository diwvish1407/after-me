"""Small building blocks: hashing, client IP, clock, client-version parsing, problem bodies."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest

from app.auth.codes import code_matches, generate_code, hash_code
from app.core.clock import FrozenClock
from app.core.errors import (
    InvalidCode,
    NotFound,
    RateLimited,
    ValidationFailed,
    error_for_status,
    problem_body,
    problem_type,
)
from app.core.middleware import parse_client_version
from app.core.net import UNKNOWN_IP, client_ip
from app.security.hashing import Pepper, sha256
from app.security.rate_limit import LOGIN_PER_IP, RateLimit, RateLimitResult

pytestmark = pytest.mark.no_db

PEPPER_A = "a" * 40
PEPPER_B = "b" * 40


def test_sha256_is_deterministic() -> None:
    assert sha256("x") == sha256(b"x")
    assert len(sha256("x")) == 32


def test_pepper_hmac_is_context_bound() -> None:
    pepper = Pepper(PEPPER_A)
    assert pepper.hmac("ip", "1.2.3.4") != pepper.hmac("rate", "1.2.3.4")
    assert pepper.hmac("ctx", "a", "b") != pepper.hmac("ctx", "ab")
    assert pepper.ip_hash("1.2.3.4") == pepper.hmac("ip", "1.2.3.4")
    assert len(pepper.subject_key("ctx", "x")) == 40


def test_pepper_rotation_accepts_previous() -> None:
    old = Pepper(PEPPER_A)
    rotated = Pepper(PEPPER_B, previous=PEPPER_A)
    stored = old.hmac("ctx", "value")
    assert rotated.verify(stored, "ctx", "value")
    assert not Pepper(PEPPER_B).verify(stored, "ctx", "value")
    assert not rotated.verify(stored, "ctx", "other")


def test_codes() -> None:
    codes = {generate_code() for _ in range(200)}
    assert all(len(c) == 6 and c.isdigit() for c in codes)
    assert len(codes) > 150
    pepper = Pepper(PEPPER_A)
    user = uuid.uuid4()
    stored = hash_code(pepper, user_id=user, purpose="signup_verify", code="123456")
    assert code_matches(pepper, stored, user_id=user, purpose="signup_verify", code="123456")
    assert not code_matches(pepper, stored, user_id=user, purpose="signup_verify", code="123457")
    assert not code_matches(
        pepper, stored, user_id=uuid.uuid4(), purpose="signup_verify", code="123456"
    )
    assert not code_matches(pepper, stored, user_id=user, purpose="email_change", code="123456")


def _scope(peer: str | None, *forwarded: str) -> dict[str, object]:
    return {
        "type": "http",
        "client": (peer, 1234) if peer else None,
        "headers": [(b"x-forwarded-for", v.encode()) for v in forwarded],
    }


def test_client_ip_ignores_forwarded_without_trusted_hops() -> None:
    assert client_ip(_scope("10.0.0.1", "1.2.3.4"), 0) == "10.0.0.1"


def test_client_ip_uses_trusted_hops_from_the_right() -> None:
    assert client_ip(_scope("10.0.0.1", "6.6.6.6, 1.2.3.4"), 1) == "1.2.3.4"
    assert client_ip(_scope("10.0.0.1", "6.6.6.6, 1.2.3.4, 10.0.0.2"), 2) == "1.2.3.4"
    assert client_ip(_scope("10.0.0.1", "6.6.6.6", "1.2.3.4"), 1) == "1.2.3.4"
    # Fewer entries than hops: the request did not pass through every proxy, so even the first
    # entry may have been written by the client. Only the peer is not (Phase 9, F10).
    assert client_ip(_scope("10.0.0.1", "1.2.3.4"), 3) == "10.0.0.1"
    assert client_ip(_scope("10.0.0.1", "6.6.6.6"), 2) == "10.0.0.1"


def test_an_ipv4_mapped_ipv6_address_is_the_ipv4_client() -> None:
    """A dual-stack listener reports 1.2.3.4 as ::ffff:1.2.3.4; keyed as an IPv6 /64 every IPv4
    client would share one rate-limit bucket (Phase 9, F7)."""
    from app.core.net import rate_limit_subject

    assert client_ip(_scope("::ffff:203.0.113.9"), 0) == "203.0.113.9"
    assert client_ip(_scope("10.0.0.1", "::ffff:198.51.100.7"), 1) == "198.51.100.7"
    assert rate_limit_subject("::ffff:203.0.113.9") == "203.0.113.9"
    assert rate_limit_subject("::ffff:198.51.100.7") != rate_limit_subject("::ffff:203.0.113.9")
    assert rate_limit_subject("2001:db8::1") == "2001:db8::/64"


def test_client_ip_falls_back_on_garbage() -> None:
    assert client_ip(_scope("10.0.0.1", "not-an-ip"), 1) == "10.0.0.1"
    assert client_ip(_scope("10.0.0.1"), 1) == "10.0.0.1"
    assert client_ip(_scope(None), 0) == UNKNOWN_IP
    assert client_ip(_scope("::1", "2001:db8::1"), 1) == "2001:db8::1"


async def test_frozen_clock() -> None:
    start = datetime(2026, 1, 1, tzinfo=UTC)
    clock = FrozenClock(start)
    assert await clock.now(None) == start  # type: ignore[arg-type]
    assert clock.advance(minutes=5) == start + timedelta(minutes=5)
    assert clock.advance(timedelta(seconds=1)) == start + timedelta(minutes=5, seconds=1)
    clock.set(start)
    assert clock.current == start
    with pytest.raises(ValueError, match="timezone-aware"):
        FrozenClock(datetime(2026, 1, 1))  # noqa: DTZ001


@pytest.mark.parametrize(
    ("header", "expected"),
    [
        ("android/1.2.3+45", (1, 2, 3)),
        ("android/1.2.3", (1, 2, 3)),
        ("android/10.0.0+1", (10, 0, 0)),
        (None, None),
        ("", None),
        ("ios/1.2.3", None),
        ("android/1.2", None),
        ("android/1.2.3-beta", None),
    ],
)
def test_parse_client_version(header: str | None, expected: tuple[int, int, int] | None) -> None:
    assert parse_client_version(header) == expected


def test_problem_body_shape() -> None:
    body = problem_body(InvalidCode(), public_base_url="https://x.test", request_id="r1")
    assert body == {
        "type": "https://x.test/problems/invalid-code",
        "title": "Invalid code",
        "status": 400,
        "code": "invalid_code",
        "detail": "That code is wrong or has expired.",
        "request_id": "r1",
    }
    extras = problem_body(
        ValidationFailed([{"field": "email", "code": "required", "message": "m"}]),
        public_base_url="https://x.test",
        request_id=None,
    )
    assert extras["errors"] == [{"field": "email", "code": "required", "message": "m"}]
    assert problem_type("https://x.test", "rate_limited") == "https://x.test/problems/rate-limited"


def test_rate_limited_sets_retry_after() -> None:
    error = RateLimited(retry_after=0)
    assert error.headers["Retry-After"] == "1"
    assert error_for_status(404) is NotFound
    assert error_for_status(418).status_code == 400
    assert error_for_status(599).status_code == 500


def test_rate_limit_windows_are_aligned() -> None:
    rule = RateLimit("r", 3, timedelta(minutes=15))
    start, end = rule.window_bounds(datetime(2026, 10, 8, 9, 7, 30, tzinfo=UTC))
    assert start == datetime(2026, 10, 8, 9, 0, tzinfo=UTC)
    assert end == datetime(2026, 10, 8, 9, 15, tzinfo=UTC)
    result = RateLimitResult(rule=LOGIN_PER_IP, count=11, reset_after=42)
    assert result.exceeded
    assert result.remaining == 0
    assert result.headers() == {
        "RateLimit-Limit": "10",
        "RateLimit-Remaining": "0",
        "RateLimit-Reset": "42",
    }


def test_rate_limit_subject_buckets_ipv6_by_64_and_leaves_ipv4_alone() -> None:
    from app.core.net import rate_limit_subject

    assert rate_limit_subject("203.0.113.9") == "203.0.113.9"
    assert rate_limit_subject("2001:db8:1:2::1") == rate_limit_subject("2001:db8:1:2:ffff::9")
    assert rate_limit_subject("2001:db8:1:2::1") != rate_limit_subject("2001:db8:1:3::1")
    assert rate_limit_subject("not-an-ip") == "not-an-ip"
