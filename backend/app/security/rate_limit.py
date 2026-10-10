"""PostgreSQL fixed-window rate limiting (API_SPEC §16).

Each hit is one ``INSERT … ON CONFLICT DO UPDATE … RETURNING count`` on ``rate_limit_counters``
in an independent transaction, so a counter survives the error response it causes. Keys are
pseudonymous: ``<rule>:<HMAC(pepper, subject)>``; raw IPs and emails are never stored.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Final

from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert

from app.core.db import Database
from app.core.errors import RateLimited
from app.security.hashing import Pepper
from app.security.models import RateLimitCounter

_EPOCH: Final = datetime(2000, 1, 1, tzinfo=UTC)


@dataclass(frozen=True)
class RateLimit:
    name: str
    limit: int
    window: timedelta

    def window_bounds(self, now: datetime) -> tuple[datetime, datetime]:
        seconds = self.window.total_seconds()
        index = math.floor((now - _EPOCH).total_seconds() / seconds)
        start = _EPOCH + timedelta(seconds=index * seconds)
        return start, start + self.window


# --- Phase 1 limits (API_SPEC §16) ---------------------------------------------------------
REGISTER_PER_IP: Final = RateLimit("register_ip", 5, timedelta(hours=1))
REGISTER_PER_EMAIL: Final = RateLimit("register_email", 3, timedelta(hours=1))
VERIFY_PER_IP: Final = RateLimit("verify_ip", 20, timedelta(hours=1))
LOGIN_PER_IP: Final = RateLimit("login_ip", 10, timedelta(minutes=15))
LOGIN_PER_ACCOUNT: Final = RateLimit("login_account", 5, timedelta(minutes=15))
REFRESH_PER_SESSION: Final = RateLimit("refresh_session", 60, timedelta(hours=1))
REAUTH_PER_SESSION: Final = RateLimit("reauth_session", 5, timedelta(minutes=15))

# --- Phase 2 limits (API_SPEC §16) ---------------------------------------------------------
FORGOT_PER_EMAIL: Final = RateLimit("forgot_email", 3, timedelta(hours=1))
FORGOT_PER_IP: Final = RateLimit("forgot_ip", 10, timedelta(hours=1))
WEB_RESET_PER_IP: Final = RateLimit("web_reset_ip", 10, timedelta(hours=1))
EMAIL_CHANGE_PER_USER: Final = RateLimit("email_change_user", 5, timedelta(hours=1))

# --- Phase 3 limits (API_SPEC §16) ---------------------------------------------------------
CONTACT_CREATE_PER_USER: Final = RateLimit("contact_create_user", 20, timedelta(days=1))
INVITATION_PER_USER: Final = RateLimit("invitation_user", 10, timedelta(days=1))
INVITATION_RESEND_PER_CONTACT: Final = RateLimit("invitation_resend_contact", 3, timedelta(days=7))
WEB_CONTACT_PER_IP: Final = RateLimit("web_contact_ip", 20, timedelta(hours=1))

# Check-ins (API_SPEC §16): generous on purpose. A user who cannot check in can be escalated, so
# the limit only has to stop a runaway client; retries of one tap replay without counting.
CHECKIN_PER_USER: Final = RateLimit("checkin_user", 30, timedelta(hours=1))

# The uptime monitor probes every minute (ESCALATION_ENGINE §7.2); 10 a minute is generous.
PROBE_PER_IP: Final = RateLimit("probe_ip", 10, timedelta(minutes=1))

DEFAULT_PER_USER: Final = RateLimit("user_default", 300, timedelta(minutes=1))
DEFAULT_PER_IP: Final = RateLimit("ip_default", 60, timedelta(minutes=1))


@dataclass(frozen=True)
class RateLimitResult:
    rule: RateLimit
    count: int
    reset_after: int  # seconds until the window ends

    @property
    def exceeded(self) -> bool:
        return self.count > self.rule.limit

    @property
    def remaining(self) -> int:
        return max(self.rule.limit - self.count, 0)

    def headers(self) -> dict[str, str]:
        return {
            "RateLimit-Limit": str(self.rule.limit),
            "RateLimit-Remaining": str(self.remaining),
            "RateLimit-Reset": str(self.reset_after),
        }


class RateLimiter:
    def __init__(self, *, db: Database, pepper: Pepper, enabled: bool) -> None:
        self._db = db
        self._pepper = pepper
        self.enabled = enabled

    def key_for(self, rule: RateLimit, subject: str) -> str:
        return f"{rule.name}:{self._pepper.subject_key('rate_limit:' + rule.name, subject)}"

    async def hit(
        self, checks: Sequence[tuple[RateLimit, str]], *, now: datetime
    ) -> list[RateLimitResult]:
        """Count one hit against every ``(rule, subject)`` in one independent transaction."""
        if not self.enabled or not checks:
            return []
        results: list[RateLimitResult] = []
        async with self._db.independent_session() as session:
            for rule, subject in checks:
                key = self.key_for(rule, subject)
                window_start, window_end = rule.window_bounds(now)
                # Keep the table bounded: older windows of this key are dead weight.
                await session.execute(
                    delete(RateLimitCounter).where(
                        RateLimitCounter.key == key, RateLimitCounter.expires_at <= now
                    )
                )
                stmt = (
                    insert(RateLimitCounter)
                    .values(key=key, window_start=window_start, count=1, expires_at=window_end)
                    .on_conflict_do_update(
                        index_elements=[RateLimitCounter.key, RateLimitCounter.window_start],
                        set_={"count": RateLimitCounter.count + 1},
                    )
                    .returning(RateLimitCounter.count)
                )
                count = (await session.execute(stmt)).scalar_one()
                reset_after = max(1, math.ceil((window_end - now).total_seconds()))
                results.append(RateLimitResult(rule=rule, count=count, reset_after=reset_after))
        return results

    async def check(
        self, rule: RateLimit, subject: str, *, now: datetime
    ) -> RateLimitResult | None:
        """Read the current window's count without counting a hit; raise 429 once the limit is
        used up. Used where only *failed* attempts consume the budget (per-account login):
        the caller records failures with ``hit``."""
        if not self.enabled:
            return None
        window_start, window_end = rule.window_bounds(now)
        async with self._db.independent_session() as session:
            count = (
                await session.execute(
                    select(RateLimitCounter.count).where(
                        RateLimitCounter.key == self.key_for(rule, subject),
                        RateLimitCounter.window_start == window_start,
                    )
                )
            ).scalar_one_or_none() or 0
        result = RateLimitResult(
            rule=rule,
            count=count,
            reset_after=max(1, math.ceil((window_end - now).total_seconds())),
        )
        if count >= rule.limit:
            raise RateLimited(retry_after=result.reset_after, headers=result.headers())
        return result

    async def enforce(
        self, checks: Sequence[tuple[RateLimit, str]], *, now: datetime
    ) -> RateLimitResult | None:
        """Count the hits; raise ``429 rate_limited`` if any limit is exceeded.

        Returns the most restrictive result (for ``RateLimit-*`` response headers).
        """
        results = await self.hit(checks, now=now)
        if not results:
            return None
        exceeded = [r for r in results if r.exceeded]
        if exceeded:
            worst = max(exceeded, key=lambda r: r.reset_after)
            raise RateLimited(retry_after=worst.reset_after, headers=worst.headers())
        return min(results, key=lambda r: (r.remaining, -r.reset_after))
