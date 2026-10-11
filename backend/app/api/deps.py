"""Shared FastAPI dependencies: DB session, request context, rate limits, authentication, reauth.

FastAPI caches a dependency per request, so the endpoint, the services and every dependency
share one :class:`AsyncSession` (one transaction) per request.
"""

from __future__ import annotations

import re
import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Annotated, Final

from fastapi import Depends, Header, Request
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.types import Scope

from app.api.container import AppServices
from app.auth.repository import SessionRepository
from app.core.clock import Clock
from app.core.errors import ReauthRequired, SessionRevoked, Unauthenticated, ValidationFailed
from app.core.logging import bind_request_context
from app.core.middleware import add_response_headers, get_request_id
from app.core.net import client_ip, rate_limit_subject
from app.security.rate_limit import DEFAULT_PER_USER, RateLimit, RateLimitResult

REAUTH_WINDOW: Final = timedelta(minutes=5)
# Export and account deletion: the password must have been entered for *this*, moments ago. A
# confirmation made a few minutes earlier for something else does not count.
FRESH_REAUTH_WINDOW: Final = timedelta(seconds=60)
LAST_USED_RESOLUTION: Final = timedelta(minutes=5)
USER_AGENT_MAX: Final = 200
_RATE_LIMIT_RESULT_KEY: Final = "afterme.rate_limit_result"


def get_services(request: Request) -> AppServices:
    services: AppServices = request.app.state.services
    return services


ServicesDep = Annotated[AppServices, Depends(get_services)]


async def get_db_session(services: ServicesDep) -> AsyncIterator[AsyncSession]:
    """One session per request. Services COMMIT explicitly; teardown only rolls back/closes."""
    session = services.db.sessionmaker()
    try:
        yield session
    finally:
        try:
            if session.in_transaction():
                await session.rollback()
        finally:
            await session.close()


DbSession = Annotated[AsyncSession, Depends(get_db_session)]


def get_clock(services: ServicesDep) -> Clock:
    """The authoritative clock (DbClock in production; tests inject a FrozenClock)."""
    return services.clock


ClockDep = Annotated[Clock, Depends(get_clock)]


@dataclass(frozen=True)
class RequestContext:
    request_id: str | None
    client_ip: str
    ip_hash: bytes
    user_agent: str | None
    scope: Scope = field(repr=False, compare=False)

    def note_rate_limit(self, result: RateLimitResult | None) -> None:
        """Expose the most restrictive limit seen in this request as RateLimit-* headers."""
        if result is None:
            return
        previous: RateLimitResult | None = self.scope.get(_RATE_LIMIT_RESULT_KEY)
        if previous is not None and previous.remaining <= result.remaining:
            return
        self.scope[_RATE_LIMIT_RESULT_KEY] = result
        add_response_headers(self.scope, result.headers())


def get_request_context(request: Request, services: ServicesDep) -> RequestContext:
    ip = client_ip(request.scope, services.settings.trusted_proxy_hops)
    user_agent = request.headers.get("user-agent")
    return RequestContext(
        request_id=get_request_id(request.scope),
        client_ip=ip,
        ip_hash=services.pepper.ip_hash(ip),
        user_agent=user_agent[:USER_AGENT_MAX] if user_agent else None,
        scope=request.scope,
    )


ContextDep = Annotated[RequestContext, Depends(get_request_context)]


def ip_rate_limit(*rules: RateLimit) -> Callable[..., Awaitable[None]]:
    """Dependency factory: count this request against per-IP ``rules``."""

    async def dependency(
        session: DbSession, services: ServicesDep, clock: ClockDep, ctx: ContextDep
    ) -> None:
        now = await clock.now(session)
        result = await services.limiter.enforce(
            [(r, rate_limit_subject(ctx.client_ip)) for r in rules], now=now
        )
        ctx.note_rate_limit(result)

    return dependency


@dataclass(frozen=True)
class CurrentUser:
    user_id: uuid.UUID
    session_id: uuid.UUID
    device_id: uuid.UUID | None
    email: str
    tier: str
    status: str
    reauthenticated_at: datetime | None


def _bearer_token(request: Request) -> str:
    header = request.headers.get("authorization")
    if not header:
        raise Unauthenticated
    scheme, _, token = header.partition(" ")
    token = token.strip()
    if scheme.lower() != "bearer" or not token or len(token) > 4096:  # noqa: PLR2004
        raise Unauthenticated
    return token


async def get_current_user(
    request: Request, session: DbSession, services: ServicesDep, clock: ClockDep, ctx: ContextDep
) -> CurrentUser:
    """Bearer JWT → active session (sid + sub) → active, verified user.

    Errors: 401 ``unauthenticated`` (missing/invalid token), ``token_expired``,
    ``session_revoked`` (session ended, expired, or the account is no longer usable).
    """
    token = _bearer_token(request)
    now = await clock.now(session)
    claims = services.tokens.decode(token, now=now)

    row = await SessionRepository(session).get_with_user(
        owner_id=claims.user_id, session_id=claims.session_id
    )
    if row is None:
        raise SessionRevoked
    auth_session, user = row
    if (
        auth_session.revoked_at is not None
        or auth_session.idle_expires_at <= now
        or auth_session.absolute_expires_at <= now
        or user.status != "active"
        or user.email_verified_at is None
    ):
        raise SessionRevoked

    bind_request_context(user_id=str(user.id))

    if now - auth_session.last_used_at >= LAST_USED_RESOLUTION:
        # Bookkeeping on a separate connection; this request has not locked the row.
        async with services.db.independent_session() as bookkeeping:
            await SessionRepository(bookkeeping).touch(
                owner_id=user.id, session_id=auth_session.id, now=now
            )

    result = await services.limiter.enforce([(DEFAULT_PER_USER, str(user.id))], now=now)
    ctx.note_rate_limit(result)

    return CurrentUser(
        user_id=user.id,
        session_id=auth_session.id,
        device_id=auth_session.device_id,
        email=user.email,
        tier=user.tier,
        status=user.status,
        reauthenticated_at=auth_session.reauthenticated_at,
    )


CurrentUserDep = Annotated[CurrentUser, Depends(get_current_user)]


def has_fresh_reauth(current: CurrentUser, now: datetime) -> bool:
    """Whether the session re-entered the password within the last 5 minutes."""
    return (
        current.reauthenticated_at is not None and now - current.reauthenticated_at <= REAUTH_WINDOW
    )


async def require_reauth(
    current: CurrentUserDep, session: DbSession, clock: ClockDep
) -> CurrentUser:
    """Step-up: the session re-entered the password within the last 5 minutes (FR-AUTH-08)."""
    if not has_fresh_reauth(current, await clock.now(session)):
        raise ReauthRequired
    return current


ReauthUserDep = Annotated[CurrentUser, Depends(require_reauth)]


async def require_fresh_reauth(
    current: CurrentUserDep, session: DbSession, clock: ClockDep
) -> CurrentUser:
    """Step-up for the two actions that cannot be taken back or that read everything: the
    password was entered within the last minute."""
    now = await clock.now(session)
    if current.reauthenticated_at is None or now - current.reauthenticated_at > FRESH_REAUTH_WINDOW:
        raise ReauthRequired
    return current


FreshReauthUserDep = Annotated[CurrentUser, Depends(require_fresh_reauth)]


_IDEMPOTENCY_KEY_RE: Final = re.compile(r"[A-Za-z0-9_.:-]{16,64}")


def idempotency_key(
    value: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
) -> str:
    """The required ``Idempotency-Key`` header (API_SPEC §1): 16 to 64 URL-safe characters."""
    if value is None or _IDEMPOTENCY_KEY_RE.fullmatch(value) is None:
        raise ValidationFailed(
            [
                {
                    "field": "Idempotency-Key",
                    "code": "required" if value is None else "invalid",
                    "message": "Send a unique Idempotency-Key header (16 to 64 characters).",
                }
            ]
        )
    return value


IdempotencyKeyDep = Annotated[str, Depends(idempotency_key)]
