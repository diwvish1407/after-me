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
# The hard per-address budgets are per (address, network): a stranger who knows an address spends
# their own network's budget, never the owner's (Phase 9, F1). The ``*_PER_EMAIL`` ceilings across
# networks only stop a flood and are deliberately higher.
REGISTER_PER_EMAIL_NETWORK: Final = RateLimit("register_email_net", 3, timedelta(hours=1))
REGISTER_PER_EMAIL: Final = RateLimit("register_email", 12, timedelta(hours=1))
VERIFY_PER_IP: Final = RateLimit("verify_ip", 20, timedelta(hours=1))
LOGIN_PER_IP: Final = RateLimit("login_ip", 10, timedelta(minutes=15))
# Failed sign-ins per (account, network). Not per account alone: that let anyone who knew an email
# keep its owner out with five requests, the lost-phone page included. What stops a guess spread
# over many networks is the account lock (10 consecutive failures, 15 minutes), which a phone the
# account already knows is not subject to.
LOGIN_PER_ACCOUNT_NETWORK: Final = RateLimit("login_account_net", 5, timedelta(minutes=15))
REFRESH_PER_SESSION: Final = RateLimit("refresh_session", 60, timedelta(hours=1))
REAUTH_PER_SESSION: Final = RateLimit("reauth_session", 5, timedelta(minutes=15))

# --- Phase 2 limits (API_SPEC §16) ---------------------------------------------------------
FORGOT_PER_EMAIL_NETWORK: Final = RateLimit("forgot_email_net", 3, timedelta(hours=1))
FORGOT_PER_EMAIL: Final = RateLimit("forgot_email", 12, timedelta(hours=1))
FORGOT_PER_IP: Final = RateLimit("forgot_ip", 10, timedelta(hours=1))
WEB_RESET_PER_IP: Final = RateLimit("web_reset_ip", 10, timedelta(hours=1))
EMAIL_CHANGE_PER_USER: Final = RateLimit("email_change_user", 5, timedelta(hours=1))

# --- Phase 3 limits (API_SPEC §16) ---------------------------------------------------------
CONTACT_CREATE_PER_USER: Final = RateLimit("contact_create_user", 20, timedelta(days=1))
INVITATION_PER_USER: Final = RateLimit("invitation_user", 10, timedelta(days=1))
INVITATION_RESEND_PER_CONTACT: Final = RateLimit("invitation_resend_contact", 3, timedelta(days=7))
WEB_CONTACT_PER_IP: Final = RateLimit("web_contact_ip", 20, timedelta(hours=1))

# --- Phase 6 limits (API_SPEC §16): the recipient portal -------------------------------------
# Every POST of the release pages, per client address (a visit is about six requests).
WEB_PORTAL_PER_IP: Final = RateLimit("web_portal_ip", 60, timedelta(hours=1))
# Codes sent for one access: the fourth request in an hour is refused.
PORTAL_OTP_SEND_PER_ACCESS: Final = RateLimit("portal_otp_send_access", 3, timedelta(hours=1))
PORTAL_NEW_LINK_PER_ACCESS: Final = RateLimit("portal_new_link_access", 3, timedelta(days=1))
# Every code attempt for one access, however many codes were asked for: 20 guesses a day.
PORTAL_OTP_VERIFY_PER_ACCESS: Final = RateLimit("portal_otp_verify_access", 20, timedelta(days=1))

# --- Phase 7 limits (API_SPEC §16): export, deletion and the lost-phone web pages -------------
EXPORT_PER_USER: Final = RateLimit("export_user", 3, timedelta(hours=1))
DELETE_REQUEST_PER_IP: Final = RateLimit("web_delete_request_ip", 10, timedelta(hours=1))
DELETE_REQUEST_PER_EMAIL_NETWORK: Final = RateLimit(
    "web_delete_request_email_net", 3, timedelta(hours=1)
)
DELETE_REQUEST_PER_EMAIL: Final = RateLimit("web_delete_request_email", 12, timedelta(hours=1))
WEB_DELETE_CONFIRM_PER_IP: Final = RateLimit("web_delete_confirm_ip", 10, timedelta(hours=1))
WEB_LOGIN_PER_IP: Final = RateLimit("web_login_ip", 10, timedelta(minutes=15))
WEB_LOGIN_PER_ACCOUNT: Final = RateLimit("web_login_account", 5, timedelta(minutes=15))

# Provider webhooks: a provider batches and retries, so this is generous; it only has to stop
# a flood of unauthenticated requests from costing more than a signature check each.
WEBHOOK_PER_IP: Final = RateLimit("webhook_ip", 600, timedelta(minutes=1))

# Check-ins (API_SPEC §16): generous on purpose. A user who cannot check in can be escalated, so
# the limit only has to stop a runaway client; retries of one tap replay without counting.
CHECKIN_PER_USER: Final = RateLimit("checkin_user", 30, timedelta(hours=1))
# I'M SAFE has a budget of its own. Shared with I'M OK, thirty refused I'M OK attempts (fresh keys
# during an open incident answer ``409 safe_required``) used up the hour for the one action that
# takes an alarm back (Phase 9). It needs the password, so only the owner spends it.
SAFE_PER_USER: Final = RateLimit("safe_user", 30, timedelta(hours=1))

# The uptime monitor probes every minute (ESCALATION_ENGINE §7.2). The two budgets are separate on
# purpose: only a request with the wrong token spends the first, so that someone who shares the
# monitor's address (a co-tenant, an IPv6 /64, a mis-set proxy count) cannot use up the monitor's
# own budget and starve it into a Hold that stops every escalation (Phase 9, F3).
PROBE_PER_IP: Final = RateLimit("probe_ip", 60, timedelta(minutes=1))
PROBE_FAILURES_PER_IP: Final = RateLimit("probe_fail_ip", 10, timedelta(minutes=1))

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
