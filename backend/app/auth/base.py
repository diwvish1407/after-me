"""Shared plumbing for the auth services: repositories, clock, rate limits, audit events and
the commit-then-send rule (emails go out only after the transaction has committed)."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.api.deps import RequestContext
from app.audit.writer import AuditEvent, MetadataValue
from app.auth.repository import (
    AuthTokenRepository,
    DeviceRepository,
    RefreshTokenRepository,
    SessionRepository,
    UserRepository,
)
from app.core.net import rate_limit_subject
from app.notifications.email import EmailMessage
from app.security.rate_limit import RateLimit
from app.users.repository import ProfileRepository


class AuthServiceBase:
    def __init__(
        self, *, session: AsyncSession, services: AppServices, ctx: RequestContext
    ) -> None:
        self.session = session
        self.services = services
        self.ctx = ctx
        self.settings = services.settings
        self.users = UserRepository(session)
        self.profiles = ProfileRepository(session)
        self.devices = DeviceRepository(session)
        self.sessions = SessionRepository(session)
        self.refresh_tokens = RefreshTokenRepository(session)
        self.codes = AuthTokenRepository(session)

    # ------------------------------------------------------------------ helpers

    async def _now(self) -> datetime:
        return await self.services.clock.now(self.session)

    async def _limit(self, rule: RateLimit, subject: str, now: datetime) -> None:
        result = await self.services.limiter.enforce([(rule, subject)], now=now)
        self.ctx.note_rate_limit(result)

    def _budget_subject(self, email_norm: str) -> str:
        """An address and the network the caller is on: what a *hard* per-address budget is
        keyed on, so that a stranger cannot spend the owner's (Phase 9, F1)."""
        return f"{email_norm}|{rate_limit_subject(self.ctx.client_ip)}"

    async def _limit_email(
        self, per_network: RateLimit, ceiling: RateLimit, email_norm: str, now: datetime
    ) -> None:
        """The per-address budgets of the public routes that send mail: one per (address,
        network), and a higher one across networks that only stops a flood."""
        result = await self.services.limiter.enforce(
            [(per_network, self._budget_subject(email_norm)), (ceiling, email_norm)], now=now
        )
        self.ctx.note_rate_limit(result)

    def _event(
        self,
        action: str,
        now: datetime,
        user_id: uuid.UUID | None,
        *,
        resource_id: uuid.UUID | None = None,
        resource_type: str | None = None,
        user_visible: bool | None = None,
        unauthenticated: bool = False,
        **metadata: MetadataValue | uuid.UUID,
    ) -> AuditEvent:
        """Build an audit event. The subject is the affected account; the actor is that user only
        once the caller has authenticated as them. Events from callers who have not proven
        possession of the credential (failed logins, lockouts, signup attempts) are recorded
        with ``unauthenticated=True`` so they read as system-observed, never as the owner's own
        activity (SECURITY §9; DATABASE §3.9)."""
        acting_user = None if unauthenticated else user_id
        return AuditEvent(
            action=action,
            occurred_at=now,
            subject_user_id=user_id,
            actor_type="user" if acting_user is not None else "system",
            actor_id=acting_user,
            resource_type=resource_type,
            resource_id=resource_id,
            request_id=self.ctx.request_id,
            ip_hash=self.ctx.ip_hash,
            metadata=dict(metadata),
            user_visible=user_visible,
        )

    async def _commit_and_send(self, outbox: list[EmailMessage]) -> None:
        await self.session.commit()
        await self.services.mailer.deliver(outbox)

    async def _display_name(self, user_id: uuid.UUID) -> str:
        profile = await self.profiles.get(owner_id=user_id)
        return profile.display_name if profile is not None else "there"
