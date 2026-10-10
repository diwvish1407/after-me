"""Opening incidents (ESCALATION_ENGINE §6.3).

One unit of work per user, in its own transaction. The unit locks the user (``SKIP LOCKED``),
re-checks that the deadline really passed, refuses to open over inconsistent data (FS-25) and,
only then, writes the incident, its whole timeline and the schedule change in one commit.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta
from enum import StrEnum

from sqlalchemy import exists, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.audit import writer as audit
from app.audit.models import AuditLog
from app.audit.writer import AuditEvent, AuditWriter
from app.core.config import Settings
from app.core.logging import get_logger
from app.engine.releases import ReleaseSource
from app.engine.store import EngineStore
from app.engine.timeline import anchor_for, materialise
from app.incidents.models import EscalationIncident, IncidentAction
from app.incidents.snapshot import SnapshotStage, build_snapshot, parse_snapshot

_log = get_logger("afterme.engine")
_VIOLATION_AUDIT_INTERVAL = timedelta(days=1)


class OpenResult(StrEnum):
    OPENED = "opened"
    LOCKED = "locked"
    NOT_DUE = "not_due"
    HOLD = "hold"
    INCONSISTENT = "inconsistent"
    INELIGIBLE = "ineligible"


async def open_incident(
    session: AsyncSession,
    *,
    user_id: uuid.UUID,
    now: datetime,
    settings: Settings,
    audit_writer: AuditWriter,
    releases: ReleaseSource,
) -> OpenResult:
    """Everything happens inside the caller's transaction; the caller commits."""
    config = await EngineStore.lock_user(session, user_id)
    if config is None:
        return OpenResult.LOCKED
    # Re-check inside the lock: the schedule may have moved since the candidate query.
    if config.status != "active" or config.next_due_at is None or config.next_due_at > now:
        return OpenResult.NOT_DUE
    # INV-10: while the system is in Hold no incident is opened; deadlines simply wait.
    if await EngineStore.open_hold(session) is not None:
        return OpenResult.HOLD

    missed_due_at = config.next_due_at
    # FS-25: a check-in that the schedule did not absorb means the data is inconsistent. Do not
    # open, and raise a critical alert; the row is left for investigation.
    if config.baseline_at is None or await EngineStore.has_unabsorbed_checkin(
        session, user_id, config.baseline_at
    ):
        await _report_violation(session, user_id, now, audit_writer, reason="unabsorbed_checkin")
        return OpenResult.INCONSISTENT

    user = await EngineStore.user(session, user_id)
    if user is None or user.status != "active":
        return OpenResult.INELIGIBLE
    plan = await EngineStore.plan(session, user_id)
    if plan is None:
        await _report_violation(session, user_id, now, audit_writer, reason="no_plan")
        return OpenResult.INCONSISTENT

    stages = await EngineStore.stages(session, plan.id)
    planned = await releases.planned(
        session, user_id=user_id, step_ids=[step.id for step, _ in stages]
    )
    snapshot = build_snapshot(
        plan_id=plan.id,
        plan_version=plan.version,
        grace_minutes=plan.grace_minutes,
        stages=[
            SnapshotStage(
                stage_id=step.id,
                position=step.position,
                offset_minutes=step.offset_minutes,
                notify_contact_ids=tuple(contact_ids),
                releases=tuple(planned.get(step.id, [])),
            )
            for step, contact_ids in stages
        ],
    )

    anchor = anchor_for(missed_due_at, now)  # INV-8: full grace from when this really opens
    incident = EscalationIncident(
        id=uuid.uuid4(),
        user_id=user_id,
        plan_id=plan.id,
        plan_version=plan.version,
        plan_snapshot=snapshot,
        missed_due_at=missed_due_at,
        opened_at=now,
        anchor_at=anchor,
        grace_ends_at=anchor + timedelta(minutes=plan.grace_minutes),
        status="grace",
        created_at=now,
        updated_at=now,
    )
    await EngineStore.insert_incident(session, incident)

    parsed = parse_snapshot(snapshot)
    timeline = materialise(
        incident_id=incident.id,
        snapshot=parsed,
        anchor_at=anchor,
        final_warning_lead=timedelta(minutes=settings.final_warning_lead_minutes),
    )
    await EngineStore.insert_actions(
        session,
        [
            IncidentAction(
                incident_id=incident.id,
                user_id=user_id,
                kind=a.kind,
                variant=a.variant,
                step_id=a.step_id,
                scheduled_for=a.scheduled_for,
                original_scheduled_for=a.scheduled_for,
                dedupe_key=a.dedupe_key,
                created_at=now,
                updated_at=now,
            )
            for a in timeline
        ],
    )
    config.status = "incident_open"
    config.updated_at = now
    await audit_writer.record(
        session,
        AuditEvent(
            action=audit.INCIDENT_OPENED,
            occurred_at=now,
            subject_user_id=user_id,
            actor_type="system",
            resource_type="incident",
            resource_id=incident.id,
            metadata={
                "stages": len(stages),
                "late_seconds": int((anchor - missed_due_at).total_seconds()),
            },
        ),
    )
    _log.info("incident.opened", user_id=str(user_id), incident_id=str(incident.id))
    return OpenResult.OPENED


async def _report_violation(
    session: AsyncSession,
    user_id: uuid.UUID,
    now: datetime,
    audit_writer: AuditWriter,
    *,
    reason: str,
) -> None:
    """A critical alert (page) for an impossible state. Logged every tick; written to the audit
    trail at most once a day per user so the trail does not fill with repeats."""
    _log.critical("engine.consistency_violation", user_id=str(user_id), reason=reason)
    recent = await session.execute(
        select(
            exists().where(
                AuditLog.subject_user_id == user_id,
                AuditLog.action == audit.CONSISTENCY_VIOLATION,
                AuditLog.occurred_at > now - _VIOLATION_AUDIT_INTERVAL,
            )
        )
    )
    if not recent.scalar_one():
        await audit_writer.record(
            session,
            AuditEvent(
                action=audit.CONSISTENCY_VIOLATION,
                occurred_at=now,
                subject_user_id=user_id,
                actor_type="system",
                metadata={"reason": reason},
            ),
        )
