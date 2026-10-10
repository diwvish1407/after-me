"""Executing due actions behind the safety gate (ESCALATION_ENGINE §6.4, §6.5).

One unit of work per user, in one transaction: lock the user (``SKIP LOCKED``), then the
incidents, then the due actions oldest first, and for each action collect the facts, ask the
gate, and only then act. An exception anywhere rolls the whole unit back; the failed attempt is
counted in a separate transaction, and after ``ACTION_MAX_ATTEMPTS`` the action is ``held`` and
is never executed automatically again (FS-23).
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.audit import writer as audit
from app.audit.writer import AuditEvent, AuditWriter
from app.contacts.tokens import suppression_hash_candidates
from app.core.config import Settings
from app.core.logging import get_logger
from app.engine.gate import ContactFacts, Decision, GateFacts, GateResult, contact_problem, decide
from app.engine.releases import ReleaseSource
from app.engine.store import EngineStore
from app.incidents.models import OPEN_STATUSES, EscalationIncident, IncidentAction
from app.incidents.snapshot import PlanSnapshot, SnapshotError, SnapshotStage, parse_snapshot
from app.notifications import outbox
from app.notifications.outbox import Draft
from app.security.hashing import Pepper

_log = get_logger("afterme.engine")

_REMINDER_TEMPLATES = {
    "missed": outbox.USER_MISSED,
    "midpoint": outbox.USER_MIDPOINT,
    "last_chance": outbox.USER_LAST_CHANCE,
}
FINAL_WARNING_WAIT = timedelta(minutes=30)  # G9: waited longer than this -> held and alert


@dataclass
class UnitReport:
    executed: int = 0
    cancelled: int = 0
    held: int = 0
    left_pending: int = 0
    skipped_locked: bool = False
    messages_queued: int = 0
    gates: dict[str, int] = field(default_factory=dict)

    def note(self, gate: str) -> None:
        self.gates[gate] = self.gates.get(gate, 0) + 1


class ActionExecutor:
    def __init__(
        self,
        *,
        settings: Settings,
        audit_writer: AuditWriter,
        pepper: Pepper,
        releases: ReleaseSource,
    ) -> None:
        self._settings = settings
        self._audit = audit_writer
        self._pepper = pepper
        self._releases = releases
        self._settle = timedelta(seconds=settings.settle_delay_seconds)

    # ------------------------------------------------------------------ the unit of work

    async def run_user(
        self,
        session: AsyncSession,
        *,
        user_id: uuid.UUID,
        now: datetime,
        current: list[uuid.UUID],
        force_hold: bool = False,
    ) -> UnitReport:
        """``current`` receives the ID of the action being processed, so that the caller can
        count a failed attempt against it after the transaction rolled back. ``force_hold``
        treats the system as being in a Hold: the engine could not evaluate Hold this tick, and
        an unknown state must not let anything contact-facing through."""
        report = UnitReport()
        config = await EngineStore.lock_user(session, user_id)
        if config is None:
            report.skipped_locked = True
            return report

        candidates = await EngineStore.due_actions(session, user_id, now)
        if not candidates:
            return report
        incidents = await EngineStore.lock_incidents(
            session, sorted({a.incident_id for a in candidates})
        )
        actions = await EngineStore.lock_actions(session, [a.id for a in candidates])
        hold_active = force_hold or await EngineStore.open_hold(session) is not None
        user = await EngineStore.user(session, user_id)
        user_active = user is not None and user.status == "active"

        for action in actions:
            current.clear()
            current.append(action.id)
            incident = incidents.get(action.incident_id)
            if incident is None:  # pragma: no cover - the FK guarantees it
                action.status = "held"
                report.held += 1
                continue
            facts = await self._facts(
                session,
                user_id=user_id,
                action=action,
                incident=incident,
                now=now,
                hold_active=hold_active,
                user_active=user_active,
            )
            result = decide(facts)
            report.note(result.gate)
            await self._apply(
                session,
                action=action,
                incident=incident,
                config_user=user_id,
                result=result,
                now=now,
                report=report,
            )
        current.clear()
        return report

    # ------------------------------------------------------------------ the facts

    async def _facts(
        self,
        session: AsyncSession,
        *,
        user_id: uuid.UUID,
        action: IncidentAction,
        incident: EscalationIncident,
        now: datetime,
        hold_active: bool,
        user_active: bool,
    ) -> GateFacts:
        snapshot, recognised = self._parse(incident)
        stage = snapshot.stage(action.step_id) if snapshot is not None and action.step_id else None
        checkin_after = await EngineStore.checkin_after(session, user_id, incident.missed_due_at)
        needs_warning = bool(stage and stage.releases) and action.kind == "execute_stage"
        warning_done = False
        if needs_warning and action.step_id is not None:
            warning_done = await EngineStore.final_warning_executed(
                session, incident.id, action.step_id
            )
        release_ok = True
        if stage is not None and stage.releases and action.kind == "execute_stage":
            release_ok = (
                stage.offset_minutes >= self._settings.min_release_offset_minutes
                and incident.grace_ends_at
                >= incident.anchor_at + timedelta(minutes=snapshot.grace_minutes)  # type: ignore[union-attr]
            )
        return GateFacts(
            kind=action.kind,
            now=now,
            scheduled_for=action.scheduled_for,
            grace_ends_at=incident.grace_ends_at,
            hold_active=hold_active,
            incident_open=incident.status in OPEN_STATUSES,
            user_active=user_active,
            snapshot_recognised=recognised,
            ownership_consistent=incident.user_id == action.user_id == user_id,
            checkin_after_missed_due=checkin_after,
            release_offset_ok=release_ok,
            needs_final_warning=needs_warning,
            final_warning_executed=warning_done,
            final_warning_wait_exceeded=(now - action.scheduled_for) > FINAL_WARNING_WAIT,
        )

    @staticmethod
    def _parse(incident: EscalationIncident) -> tuple[PlanSnapshot | None, bool]:
        try:
            return parse_snapshot(incident.plan_snapshot), True
        except SnapshotError:
            return None, False

    # ------------------------------------------------------------------ the decision

    async def _apply(
        self,
        session: AsyncSession,
        *,
        action: IncidentAction,
        incident: EscalationIncident,
        config_user: uuid.UUID,
        result: GateResult,
        now: datetime,
        report: UnitReport,
    ) -> None:
        if result.decision is Decision.LEAVE_PENDING:
            report.left_pending += 1
            return
        if result.decision is Decision.CANCEL:
            action.status = "cancelled"
            action.updated_at = now
            action.outcome = {"cancelled_by_gate": result.gate}
            report.cancelled += 1
            return
        if result.decision is Decision.HOLD_AND_ALERT:
            action.status = "held"
            action.updated_at = now
            action.outcome = {"held_by_gate": result.gate}
            report.held += 1
            _log.critical(
                "engine.action_held",
                user_id=str(config_user),
                incident_id=str(incident.id),
                action_id=str(action.id),
                kind=action.kind,
                gate=result.gate,
            )
            await self._audit.record(
                session,
                AuditEvent(
                    action=audit.ACTION_HELD,
                    occurred_at=now,
                    subject_user_id=config_user,
                    actor_type="system",
                    resource_type="incident_action",
                    resource_id=action.id,
                    metadata={"gate": result.gate, "kind": action.kind},
                ),
            )
            return
        await self._run(session, action=action, incident=incident, now=now, report=report)

    # ------------------------------------------------------------------ the effects

    async def _run(
        self,
        session: AsyncSession,
        *,
        action: IncidentAction,
        incident: EscalationIncident,
        now: datetime,
        report: UnitReport,
    ) -> None:
        snapshot = parse_snapshot(incident.plan_snapshot)  # recognised: the gate checked it
        if action.kind == "user_reminder":
            await self._reminder(session, action, incident, snapshot, now, report)
        elif action.kind == "user_final_warning":
            await self._final_warning(session, action, incident, snapshot, now, report)
        else:
            await self._stage(session, action, incident, snapshot, now, report)

    async def _user_drafts(
        self,
        session: AsyncSession,
        *,
        incident: EscalationIncident,
        action: IncidentAction,
        template: str,
        now: datetime,
        params: dict[str, Any],
        send_after: datetime | None = None,
    ) -> list[Draft]:
        # The dedupe keys carry the instant the action was scheduled for. A Hold exit shifts a
        # rolled-back stage, so its second execution gets keys the first (cancelled) one does
        # not occupy; retries of the same execution still collapse onto one row (INV-5).
        stamp = int(action.scheduled_for.timestamp())
        due = send_after or now
        drafts: list[Draft] = []
        for channel in outbox.USER_CHANNELS[template]:
            if channel == "push":
                for device_id in await EngineStore.push_devices(session, incident.user_id):
                    drafts.append(
                        Draft(
                            user_id=incident.user_id,
                            audience="user",
                            category=outbox.CATEGORY_USER,
                            channel="push",
                            template_key=template,
                            send_after=due,
                            dedupe_key=f"notif:{action.id}:{stamp}:push:{device_id}",
                            device_id=device_id,
                            incident_id=incident.id,
                            action_id=action.id,
                            params=params,
                        )
                    )
            else:
                drafts.append(
                    Draft(
                        user_id=incident.user_id,
                        audience="user",
                        category=outbox.CATEGORY_USER,
                        channel=channel,
                        template_key=template,
                        send_after=due,
                        dedupe_key=f"notif:{action.id}:{stamp}:{channel}",
                        incident_id=incident.id,
                        action_id=action.id,
                        params=params,
                    )
                )
        return drafts

    @staticmethod
    def _first_stage(incident: EscalationIncident, snapshot: PlanSnapshot) -> dict[str, Any]:
        first: SnapshotStage | None = snapshot.stages[0] if snapshot.stages else None
        if first is None:
            return {}
        return {
            "first_stage_at": (
                incident.anchor_at + timedelta(minutes=first.offset_minutes)
            ).isoformat(),
            "first_stage_contact_ids": [str(c) for c in first.notify_contact_ids],
        }

    async def _reminder(
        self,
        session: AsyncSession,
        action: IncidentAction,
        incident: EscalationIncident,
        snapshot: PlanSnapshot,
        now: datetime,
        report: UnitReport,
    ) -> None:
        # A reminder is only true while nobody has been told and the first stage is still ahead
        # ("Mom will be notified at 11:00 PM"): after the end of grace, or once a stage ran, it
        # would be false and alarming. A worker that was down finds such reminders late.
        if incident.status != "grace" or now >= incident.grace_ends_at:
            action.status = "cancelled"
            action.updated_at = now
            action.outcome = {"reason": "superseded"}
            report.cancelled += 1
            return
        template = _REMINDER_TEMPLATES[action.variant or "missed"]
        drafts = await self._user_drafts(
            session,
            incident=incident,
            action=action,
            template=template,
            now=now,
            params={
                "incident_id": str(incident.id),
                "missed_due_at": incident.missed_due_at.isoformat(),
                **self._first_stage(incident, snapshot),
            },
        )
        report.messages_queued += await outbox.enqueue(session, drafts, now=now)
        self._finish(action, now, {"queued": len(drafts)})
        report.executed += 1
        await self._record(
            session, audit.REMINDER_SENT, incident, action, now, {"variant": action.variant or ""}
        )

    async def _final_warning(
        self,
        session: AsyncSession,
        action: IncidentAction,
        incident: EscalationIncident,
        snapshot: PlanSnapshot,
        now: datetime,
        report: UnitReport,
    ) -> None:
        stage = snapshot.stage(action.step_id) if action.step_id else None
        if incident.status not in OPEN_STATUSES or stage is None:  # pragma: no cover - gated
            action.status = "cancelled"
            action.updated_at = now
            report.cancelled += 1
            return
        drafts = await self._user_drafts(
            session,
            incident=incident,
            action=action,
            template=outbox.USER_FINAL_WARNING,
            now=now,
            params={
                "incident_id": str(incident.id),
                "stage_position": stage.position,
                "stage_at": (
                    incident.anchor_at + timedelta(minutes=stage.offset_minutes)
                ).isoformat(),
                "release_count": len(stage.releases),
                "contact_ids": sorted({str(r.contact_id) for r in stage.releases}),
            },
        )
        report.messages_queued += await outbox.enqueue(session, drafts, now=now)
        self._finish(action, now, {"queued": len(drafts)})
        report.executed += 1
        await self._record(
            session, audit.FINAL_WARNING_SENT, incident, action, now, {"stage": stage.position}
        )

    async def _stage(
        self,
        session: AsyncSession,
        action: IncidentAction,
        incident: EscalationIncident,
        snapshot: PlanSnapshot,
        now: datetime,
        report: UnitReport,
    ) -> None:
        stage = snapshot.stage(action.step_id) if action.step_id else None
        if stage is None:
            # FS-21: a stage that the snapshot no longer lists. Nothing to do, and recorded.
            self._finish(action, now, {"targets": [], "reason": "stage_not_in_snapshot"})
            report.executed += 1
            return

        # G8 per release, then G7 per target: they narrow, never widen (INV-7). A release that
        # is no longer valid is skipped and recorded; its contact is still told if the stage
        # lists them to be notified, and not otherwise.
        releases: list[dict[str, Any]] = []
        valid_release_contacts: set[uuid.UUID] = set()
        for release in stage.releases:
            why = await self._releases.still_valid(
                session, user_id=incident.user_id, release=release
            )
            releases.append(
                {
                    "instruction_id": str(release.instruction_id),
                    "contact_id": str(release.contact_id),
                    "result": "valid" if why is None else "skipped",
                    **({} if why is None else {"reason": why}),
                }
            )
            if why is None:
                valid_release_contacts.add(release.contact_id)
        contact_ids = sorted({*stage.notify_contact_ids, *valid_release_contacts})
        contacts = await EngineStore.contacts(session, incident.user_id, contact_ids)
        targets: list[dict[str, Any]] = []
        messaged: list[uuid.UUID] = []
        for contact_id in contact_ids:
            reason = await self._contact_problem(session, incident.user_id, contacts, contact_id)
            if reason is None:
                messaged.append(contact_id)
                targets.append({"contact_id": str(contact_id), "result": "messaged"})
            else:
                targets.append(
                    {"contact_id": str(contact_id), "result": "skipped", "reason": reason}
                )

        last_checkin = await EngineStore.last_checkin_at(session, incident.user_id)
        drafts = [
            Draft(
                user_id=incident.user_id,
                audience="contact",
                category=outbox.CATEGORY_ESCALATION,
                channel="email",
                template_key=outbox.CONTACT_ALERT,
                send_after=now + self._settle,  # §6.6: nobody sees it before the settle delay
                dedupe_key=(
                    f"notif:{action.id}:{int(action.scheduled_for.timestamp())}"
                    f":contact:{contact_id}:email"
                ),
                contact_id=contact_id,
                incident_id=incident.id,
                action_id=action.id,
                params={
                    "stage_position": stage.position,
                    "missed_due_at": incident.missed_due_at.isoformat(),
                    "last_checkin_at": last_checkin.isoformat() if last_checkin else None,
                },
            )
            for contact_id in messaged
        ]
        report.messages_queued += await outbox.enqueue(session, drafts, now=now)

        summary = await self._user_drafts(
            session,
            incident=incident,
            action=action,
            template=outbox.USER_STAGE_EXECUTED,
            now=now,
            # Told only once it is true: behind the same settle delay as the contact messages,
            # so a check-in in that window, or a Hold rollback, leaves nothing false to retract.
            send_after=now + self._settle,
            params={
                "incident_id": str(incident.id),
                "stage_position": stage.position,
                "notified_contact_ids": [str(c) for c in messaged],
                "skipped_count": len(targets) - len(messaged),
            },
        )
        report.messages_queued += await outbox.enqueue(session, summary, now=now)

        self._finish(
            action, now, {"targets": targets, **({"releases": releases} if releases else {})}
        )
        # Status: grace -> escalating; -> escalated when no stage remains pending.
        remaining = await EngineStore.pending_stage_count(session, incident.id)
        if incident.status in ("grace", "escalating"):
            incident.status = "escalated" if remaining == 0 else "escalating"
            incident.updated_at = now
        report.executed += 1
        await self._record(
            session,
            audit.STAGE_EXECUTED,
            incident,
            action,
            now,
            {
                "stage": stage.position,
                "notified": len(messaged),
                "skipped": len(targets) - len(messaged),
            },
        )

    async def _contact_problem(
        self,
        session: AsyncSession,
        user_id: uuid.UUID,
        contacts: dict[uuid.UUID, Any],
        contact_id: uuid.UUID,
    ) -> str | None:
        contact = contacts.get(contact_id)
        if contact is None:
            return contact_problem(
                ContactFacts(False, False, False, False, "pending", suppressed=False)
            )
        suppressed = False
        if contact.email_normalized:
            hashes = suppression_hash_candidates(self._pepper, contact.email_normalized)
            suppressed = await EngineStore.is_suppressed(session, hashes)
        return contact_problem(
            ContactFacts(
                exists=True,
                belongs_to_user=contact.user_id == user_id,
                deleted=contact.deleted_at is not None,
                is_active=contact.is_active,
                verification_status=contact.verification_status,
                suppressed=suppressed,
            )
        )

    # ------------------------------------------------------------------ bookkeeping

    @staticmethod
    def _finish(action: IncidentAction, now: datetime, outcome: dict[str, Any]) -> None:
        action.status = "executed"
        action.executed_at = now
        action.updated_at = now
        action.outcome = outcome

    async def _record(
        self,
        session: AsyncSession,
        action_name: str,
        incident: EscalationIncident,
        action: IncidentAction,
        now: datetime,
        metadata: dict[str, Any],
    ) -> None:
        await self._audit.record(
            session,
            AuditEvent(
                action=action_name,
                occurred_at=now,
                subject_user_id=incident.user_id,
                actor_type="system",
                resource_type="incident",
                resource_id=incident.id,
                metadata=metadata,
            ),
        )
