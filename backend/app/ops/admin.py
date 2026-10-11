"""Operator operations and engine status (API_SPEC §14: "not exposed over HTTP").

Run through ``python -m cli.admin``. Every command is audited with an operator actor. These use
the worker role: an operator can stop things and observe, never escalate.
"""

from __future__ import annotations

import uuid
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.audit import writer as audit
from app.audit.models import AuditLog
from app.audit.writer import AuditEvent
from app.core.config import DEV_ONLY_EMAIL_PROVIDERS
from app.core.logging import get_logger
from app.engine.runtime import HOLD_SERVICE_NAME, SERVICE_NAME
from app.engine.store import EngineStore
from app.incidents.closing import void_open_incident
from app.incidents.models import OPEN_STATUSES, EscalationIncident, IncidentAction
from app.notifications.models import Notification, NotificationLog
from app.ops.models import ServiceHeartbeat, SystemHold

_log = get_logger("afterme.admin")
MANUAL_REASONS = ("operator", "anomaly")
HEARTBEAT_STALE_SECONDS = 120


@dataclass(frozen=True)
class EngineStatus:
    now: str
    hold_active: bool
    hold_reasons: list[str]
    hold_exit_pending: int
    worker_heartbeat_age_seconds: float | None
    held_actions: int
    failed_messages_7d: int
    hold_evaluation_age_seconds: float | None
    oldest_due_action_age_seconds: float | None
    oldest_queued_message_age_seconds: float | None
    consistency_violations_24h: int
    incidents_open: int
    incidents_opened_last_hour: int
    # Delivery health over the last 15 minutes / 24 hours (Phase 8). None of these pages on its
    # own: a provider with trouble is what the fallback is for; ``warnings`` says what to look at.
    provider_attempts_15m: int
    provider_errors_15m: int
    fallback_sends_15m: int
    bounces_24h: int
    complaints_24h: int
    pages: list[str]
    warnings: list[str]

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


async def engine_status(services: AppServices) -> EngineStatus:
    """The observability table of ESCALATION_ENGINE §12 as one snapshot, with the alerts that
    would page an operator."""
    settings = services.settings
    async with services.db.sessionmaker() as session, session.begin():
        now = await services.clock.now(session)
        holds = list(
            (
                await session.execute(
                    select(SystemHold).where(
                        (SystemHold.ended_at.is_(None)) | (SystemHold.exit_processed_at.is_(None))
                    )
                )
            ).scalars()
        )
        last_beat = (
            await session.execute(
                select(func.max(ServiceHeartbeat.last_beat_at)).where(
                    ServiceHeartbeat.service == SERVICE_NAME
                )
            )
        ).scalar_one()
        hold_beat = (
            await session.execute(
                select(func.max(ServiceHeartbeat.last_beat_at)).where(
                    ServiceHeartbeat.service == HOLD_SERVICE_NAME
                )
            )
        ).scalar_one()
        # Only actions of incidents that are still open: a held action of a closed incident is
        # history, and must not keep paging for ever.
        held = int(
            (
                await session.execute(
                    select(func.count())
                    .select_from(IncidentAction)
                    .join(EscalationIncident, EscalationIncident.id == IncidentAction.incident_id)
                    .where(
                        IncidentAction.status == "held",
                        EscalationIncident.status.in_(("grace", "escalating", "escalated")),
                    )
                )
            ).scalar_one()
        )
        # A message that was given up on (24 h of retries) leaves nothing else behind: the
        # queued-message page clears when the row turns ``failed``. Count them for a week.
        failed = int(
            (
                await session.execute(
                    select(func.count()).where(
                        Notification.status == "failed",
                        Notification.updated_at > now - timedelta(days=7),
                    )
                )
            ).scalar_one()
        )
        oldest_action = (
            await session.execute(
                select(func.min(IncidentAction.scheduled_for)).where(
                    IncidentAction.status == "pending", IncidentAction.scheduled_for <= now
                )
            )
        ).scalar_one()
        oldest_message = (
            await session.execute(
                select(func.min(Notification.send_after)).where(
                    Notification.status == "queued", Notification.send_after <= now
                )
            )
        ).scalar_one()
        violations = int(
            (
                await session.execute(
                    select(func.count()).where(
                        AuditLog.action == audit.CONSISTENCY_VIOLATION,
                        AuditLog.occurred_at > now - timedelta(days=1),
                    )
                )
            ).scalar_one()
        )
        open_incidents = int(
            (
                await session.execute(
                    select(func.count()).where(
                        EscalationIncident.status.in_(("grace", "escalating", "escalated"))
                    )
                )
            ).scalar_one()
        )
        last_hour = int(
            (
                await session.execute(
                    select(func.count()).where(
                        EscalationIncident.opened_at > now - timedelta(hours=1)
                    )
                )
            ).scalar_one()
        )

    def age(then: datetime | None) -> float | None:
        return None if then is None else max((now - then).total_seconds(), 0.0)

    async with services.db.sessionmaker() as session, session.begin():
        recent = NotificationLog.attempted_at > now - timedelta(minutes=15)
        attempts = int(
            (
                await session.execute(
                    select(func.count()).where(
                        recent, NotificationLog.outcome.in_(("accepted", "error", "rejected"))
                    )
                )
            ).scalar_one()
        )
        errors = int(
            (
                await session.execute(
                    select(func.count()).where(
                        recent,
                        NotificationLog.outcome == "error",
                        # our own attempts only: a webhook's soft bounce is the recipient's
                        # mailbox, not the provider failing
                        NotificationLog.provider_event_id.is_(None),
                    )
                )
            ).scalar_one()
        )
        fallback = 0
        if settings.email_fallback_provider is not None:
            fallback = int(
                (
                    await session.execute(
                        select(func.count()).where(
                            recent,
                            NotificationLog.outcome == "accepted",
                            NotificationLog.provider == settings.email_fallback_provider,
                        )
                    )
                ).scalar_one()
            )
        day = NotificationLog.attempted_at > now - timedelta(days=1)
        bounces = int(
            (
                await session.execute(
                    select(func.count()).where(
                        day, NotificationLog.outcome.in_(("bounced", "rejected"))
                    )
                )
            ).scalar_one()
        )
        complaints = int(
            (
                await session.execute(
                    select(func.count()).where(day, NotificationLog.outcome == "complained")
                )
            ).scalar_one()
        )

    heartbeat_age = age(last_beat)
    hold_age = age(hold_beat)
    action_age, message_age = age(oldest_action), age(oldest_message)
    pages: list[str] = []
    worker_alive = heartbeat_age is not None and heartbeat_age <= HEARTBEAT_STALE_SECONDS
    if not worker_alive:
        pages.append("worker heartbeat older than 2 minutes")
    elif hold_age is None or hold_age > HEARTBEAT_STALE_SECONDS:
        # The engine ticks but cannot evaluate Hold: it is treating the state as unknown and
        # sends nothing contact-facing. That is safe, and needs a person.
        pages.append("hold evaluation failing")
    if holds:
        pages.append("hold active")
    if held:
        pages.append("held actions")
    if failed:
        pages.append("messages given up on")
    if violations:
        pages.append("consistency violations")
    if action_age is not None and action_age > 300:  # noqa: PLR2004
        pages.append("due action not executed for 5 minutes")
    if message_age is not None and message_age > 300:  # noqa: PLR2004
        pages.append("queued message past send_after for 5 minutes")
    warnings: list[str] = []
    if attempts >= 5 and errors / attempts > 0.05:  # noqa: PLR2004
        warnings.append("provider error rate above 5% in the last 15 minutes")
    if fallback:
        warnings.append("the fallback email provider is carrying messages")
    if complaints:
        warnings.append("spam complaints in the last 24 hours")
    if (
        settings.email_provider not in DEV_ONLY_EMAIL_PROVIDERS
        and settings.email_fallback_provider is None
    ):
        warnings.append("no fallback email provider is configured")
    return EngineStatus(
        now=now.isoformat(),
        hold_active=any(h.ended_at is None for h in holds),
        hold_reasons=sorted({h.reason for h in holds if h.ended_at is None}),
        hold_exit_pending=sum(1 for h in holds if h.ended_at is not None),
        worker_heartbeat_age_seconds=heartbeat_age,
        held_actions=held,
        failed_messages_7d=failed,
        hold_evaluation_age_seconds=hold_age,
        oldest_due_action_age_seconds=action_age,
        oldest_queued_message_age_seconds=message_age,
        consistency_violations_24h=violations,
        incidents_open=open_incidents,
        incidents_opened_last_hour=last_hour,
        provider_attempts_15m=attempts,
        provider_errors_15m=errors,
        fallback_sends_15m=fallback,
        bounces_24h=bounces,
        complaints_24h=complaints,
        pages=pages,
        warnings=warnings,
    )


async def _audit(
    session: AsyncSession,
    services: AppServices,
    action: str,
    now: datetime,
    operator: str,
    *,
    subject: uuid.UUID | None = None,
    resource_id: uuid.UUID | None = None,
    metadata: dict[str, Any] | None = None,
) -> None:
    await services.audit.record(
        session,
        AuditEvent(
            action=action,
            occurred_at=now,
            subject_user_id=subject,
            actor_type="operator",
            resource_type="system_hold" if "hold" in action else "incident",
            resource_id=resource_id,
            metadata={"operator": operator[:40], **(metadata or {})},
        ),
    )


def _safe_operator(name: str) -> str:
    cleaned = "".join(c for c in name if c.isalnum() or c in "._-")[:40]
    return cleaned or "unknown"


async def hold_enter(services: AppServices, *, operator: str, reason: str) -> uuid.UUID:
    operator = _safe_operator(operator)
    async with services.db.sessionmaker() as session, session.begin():
        now = await services.clock.now(session)
        existing = (
            await session.execute(
                select(SystemHold.id)
                .where(SystemHold.reason == "operator", SystemHold.ended_at.is_(None))
                .limit(1)
            )
        ).scalar_one_or_none()
        if existing is not None:  # entering twice must not stack two windows (and two shifts)
            return existing
        hold = SystemHold(
            reason="operator",
            started_at=now,
            detected_at=now,
            created_by=f"operator:{operator}",
            notes=reason[:500],
        )
        session.add(hold)
        await session.flush()
        await _audit(
            session, services, audit.OPERATOR_HOLD_ENTER, now, operator, resource_id=hold.id
        )
        _log.critical("system.hold_entered", reason="operator", hold_id=str(hold.id))
        return hold.id


async def hold_exit(
    services: AppServices, *, operator: str, include_ingestion: bool = False
) -> int:
    """End the manual Holds (operator, anomaly). The engine then rolls back, shifts and warns."""
    operator = _safe_operator(operator)
    reasons = (*MANUAL_REASONS, "ingestion") if include_ingestion else MANUAL_REASONS
    async with services.db.sessionmaker() as session, session.begin():
        now = await services.clock.now(session)
        holds = list(
            (
                await session.execute(
                    select(SystemHold)
                    .where(SystemHold.ended_at.is_(None), SystemHold.reason.in_(reasons))
                    .with_for_update()
                )
            ).scalars()
        )
        for hold in holds:
            hold.ended_at = now
            await _audit(
                session, services, audit.OPERATOR_HOLD_EXIT, now, operator, resource_id=hold.id
            )
        return len(holds)


async def void_incident(services: AppServices, *, operator: str, incident_id: uuid.UUID) -> bool:
    """Close an incident as ``voided`` after a confirmed fault (§7.2 FS-13): all-clear to the
    contacts already messaged, nothing further sent. Takes the user's lock first."""
    operator = _safe_operator(operator)
    async with services.db.sessionmaker() as session, session.begin():
        now = await services.clock.now(session)
        owner = (
            await session.execute(
                select(EscalationIncident.user_id).where(EscalationIncident.id == incident_id)
            )
        ).scalar_one_or_none()
        if owner is None:
            return False
        if await EngineStore.lock_user(session, owner) is None:
            msg = "the user is busy; try again"
            raise RuntimeError(msg)
        # The command names an incident, and ``void_open_incident`` closes the person's open
        # one: they must be the same. An id of a closed incident must never void a newer
        # incident that nobody looked at.
        status = (
            await session.execute(
                select(EscalationIncident.status).where(EscalationIncident.id == incident_id)
            )
        ).scalar_one_or_none()
        if status not in OPEN_STATUSES:
            return False
        outcome = await void_open_incident(
            session,
            audit_writer=services.audit,
            owner_id=owner,
            closed_by="operator_void",
            now=now,
        )
        if outcome is None:
            return False
        await _audit(
            session,
            services,
            audit.OPERATOR_VOID_INCIDENT,
            now,
            operator,
            subject=owner,
            resource_id=incident_id,
        )
        return True


async def retry_action(services: AppServices, *, operator: str, action_id: uuid.UUID) -> str:
    """Put a ``held`` action back to ``pending`` after an operator looked at why it was held.

    Returns ``"retried"``, ``"not_held"`` or ``"busy"``. Nothing is bypassed: the action goes
    through the whole gate again when it is next due, and a stage that is overdue by more than
    the limit the gate allows is held again, not run."""
    operator = _safe_operator(operator)
    async with services.db.sessionmaker() as session, session.begin():
        now = await services.clock.now(session)
        row = (
            await session.execute(
                select(IncidentAction.user_id, IncidentAction.status).where(
                    IncidentAction.id == action_id
                )
            )
        ).first()
        if row is None or row[1] != "held":
            return "not_held"
        if await EngineStore.lock_user(session, row[0]) is None:
            return "busy"
        action = (
            await session.execute(
                select(IncidentAction)
                .where(IncidentAction.id == action_id)
                .with_for_update()
                .execution_options(populate_existing=True)
            )
        ).scalar_one()
        if action.status != "held":
            return "not_held"
        action.status = "pending"
        action.attempt_count = 0
        action.last_error_class = None
        action.outcome = None
        action.updated_at = now
        await _audit(
            session,
            services,
            audit.OPERATOR_RETRY_ACTION,
            now,
            operator,
            subject=row[0],
            resource_id=action_id,
        )
        return "retried"
