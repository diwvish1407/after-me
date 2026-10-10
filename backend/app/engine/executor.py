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
from app.incidents.snapshot import (
    PlanSnapshot,
    SnapshotError,
    SnapshotRelease,
    SnapshotStage,
    parse_snapshot,
)
from app.notifications import outbox
from app.notifications.outbox import Draft
from app.releases.repository import ReleaseRepository
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
    deferred: int = 0
    left_pending: int = 0
    skipped_locked: bool = False
    messages_queued: int = 0
    gates: dict[str, int] = field(default_factory=dict)

    def note(self, gate: str) -> None:
        self.gates[gate] = self.gates.get(gate, 0) + 1


def _contact_template(releases: int, already_alerted: bool) -> str:
    """What a contact is sent for a stage: an alert, an alert that carries a release (their first
    message in this incident), or only the release notice (they were alerted earlier)."""
    if not releases:
        return outbox.CONTACT_ALERT
    return outbox.CONTACT_RELEASE if already_alerted else outbox.CONTACT_ALERT_WITH_RELEASE


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
        self._late_tolerance = timedelta(seconds=settings.late_tolerance_seconds)
        self._late_shift = timedelta(minutes=settings.late_shift_minutes)
        self._warning_lead = timedelta(minutes=settings.final_warning_lead_minutes)

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

        hold_active = force_hold or await EngineStore.open_hold(session) is not None
        if not hold_active:
            # Before looking at what is due: a stage found too late is put back first, so it is
            # not among the candidates (and the person is warned again, §6.7).
            await self._defer_late_stages(session, user_id=user_id, now=now, report=report)
        candidates = await EngineStore.due_actions(session, user_id, now)
        if not candidates:
            return report
        incidents = await EngineStore.lock_incidents(
            session, sorted({a.incident_id for a in candidates})
        )
        actions = await EngineStore.lock_actions(session, [a.id for a in candidates])
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

    # ------------------------------------------------------------------ late stages (§6.7)

    async def _defer_late_stages(
        self, session: AsyncSession, *, user_id: uuid.UUID, now: datetime, report: UnitReport
    ) -> None:
        """A contact-facing stage that is more than ``LATE_TOLERANCE`` overdue was not found by
        a worker that was running (it was down, or the clock jumped), and the person did not get
        the reminders that come before it. It is not run. The stage, and every stage after it,
        is put back by the same amount (so their spacing is kept) to at least ``LATE_SHIFT``
        from now, final warnings that are still ahead move with their stages, and the person is
        told again, with the real time. This can only delay an alert, never advance one."""
        cutoff = now - self._late_tolerance
        late = await EngineStore.late_stage_actions(session, user_id, cutoff)
        if not late:
            return
        incidents = await EngineStore.lock_incidents(session, sorted({a.incident_id for a in late}))
        for incident_id in sorted(incidents):
            incident = incidents[incident_id]
            snapshot, recognised = self._parse(incident)
            if snapshot is None or not recognised:  # the gate holds it (G6); nothing to shift
                continue
            pending = await EngineStore.pending_contact_actions(session, incident_id)
            overdue = [a for a in pending if a.kind == "execute_stage" and a.scheduled_for < cutoff]
            deferrable = await self._deferrable(session, incident_id, snapshot, pending, overdue)
            if not deferrable:
                continue
            first = deferrable[0]
            delta, moved = self._put_back(pending, snapshot, first, now)
            first_stage = snapshot.stage(first.step_id) if first.step_id else None
            drafts = await self._user_drafts(
                session,
                incident=incident,
                action=first,
                template=outbox.USER_STAGE_DEFERRED,
                now=now,
                params={
                    "incident_id": str(incident.id),
                    "missed_due_at": incident.missed_due_at.isoformat(),
                    "first_stage_at": first.scheduled_for.isoformat(),
                    "first_stage_contact_ids": (
                        [str(c) for c in first_stage.notify_contact_ids] if first_stage else []
                    ),
                },
                key="late",
            )
            report.messages_queued += await outbox.enqueue(session, drafts, now=now)
            report.deferred += 1
            late_by = int((now - (first.scheduled_for - delta)).total_seconds())
            _log.warning(
                "engine.stage_deferred",
                user_id=str(user_id),
                incident_id=str(incident.id),
                late_seconds=late_by,
            )
            await self._record(
                session,
                audit.STAGE_DEFERRED,
                incident,
                first,
                now,
                {
                    "late_seconds": late_by,
                    "shift_minutes": int(delta.total_seconds() // 60),
                    "stages": moved,
                },
            )

    @staticmethod
    async def _deferrable(
        session: AsyncSession,
        incident_id: uuid.UUID,
        snapshot: PlanSnapshot,
        pending: list[IncidentAction],
        overdue: list[IncidentAction],
    ) -> list[IncidentAction]:
        """The overdue stages that are late because of an outage. A releasing stage whose final
        warning is neither done nor still ahead is not: something removed the warning, and
        pushing it back again and again would hide that. It is left for gate G9, which holds
        it and alerts."""
        warned = {a.step_id for a in pending if a.kind == "user_final_warning"}
        result: list[IncidentAction] = []
        for action in overdue:
            stage = snapshot.stage(action.step_id) if action.step_id else None
            needs_warning = stage is not None and bool(stage.releases)
            if needs_warning and action.step_id is not None and action.step_id not in warned:
                done = await EngineStore.final_warning_executed(
                    session, incident_id, action.step_id
                )
                if not done:
                    continue
            result.append(action)
        return result

    def _put_back(
        self,
        pending: list[IncidentAction],
        snapshot: PlanSnapshot,
        first: IncidentAction,
        now: datetime,
    ) -> tuple[timedelta, int]:
        """Move ``first`` and everything after it by one amount. Returns it and the number of
        stages moved."""
        stages = [a for a in pending if a.kind == "execute_stage"]
        # Far enough that every stage that moves is at least LATE_SHIFT from now, and that a
        # releasing stage is still a full warning lead away (INV-9).
        delta = now + self._late_shift - first.scheduled_for
        for action in stages:
            if action.scheduled_for < first.scheduled_for:
                continue
            stage = snapshot.stage(action.step_id) if action.step_id else None
            if stage is not None and stage.releases:
                delta = max(delta, now + self._warning_lead - action.scheduled_for)
        moved_steps: set[uuid.UUID | None] = set()
        for action in stages:
            if action.scheduled_for >= first.scheduled_for:
                moved_steps.add(action.step_id)
                action.scheduled_for = action.scheduled_for + delta
                action.updated_at = now
        for action in pending:
            if (
                action.kind == "user_final_warning"
                and action.step_id in moved_steps
                and action.scheduled_for > now  # one that is already due runs now, as it should
            ):
                action.scheduled_for = action.scheduled_for + delta
                action.updated_at = now
        return delta, len(moved_steps)

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
        key: str = "notif",
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
                            dedupe_key=f"{key}:{action.id}:{stamp}:push:{device_id}",
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
                        dedupe_key=f"{key}:{action.id}:{stamp}:{channel}",
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
        # When the stage will really run: a Hold or a late worker may have moved it.
        stage_at = (
            await EngineStore.stage_action_time(session, incident.id, stage.stage_id)
            if action.step_id
            else None
        ) or incident.anchor_at + timedelta(minutes=stage.offset_minutes)
        drafts = await self._user_drafts(
            session,
            incident=incident,
            action=action,
            template=outbox.USER_FINAL_WARNING,
            now=now,
            params={
                "incident_id": str(incident.id),
                "stage_position": stage.position,
                "stage_at": stage_at.isoformat(),
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
        valid_releases: list[SnapshotRelease] = []
        valid_release_contacts: set[uuid.UUID] = set()
        for release in stage.releases:
            why = await self._releases.still_valid(
                session, user_id=incident.user_id, release=release, step_id=stage.stage_id
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
                valid_releases.append(release)
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

        # The releases themselves: one row per instruction and contact, hidden until the settle
        # delay has passed (``visible_after``), and one portal access per contact that has any.
        per_contact = await self._create_releases(
            session, incident, action, stage.stage_id, valid_releases, set(messaged), now
        )
        # What is *in force* decides who is told what: a release that was revoked for a real
        # reason (the owner switched the instruction off in the settle window, say) does not
        # exist, and a contact who was only to receive it (not in the notify list) is not
        # alerted at all (INV-7: narrowing only).
        notify_ids = set(stage.notify_contact_ids)
        for contact_id in [c for c in messaged if c not in notify_ids and c not in per_contact]:
            messaged.remove(contact_id)
            for target in targets:
                if target["contact_id"] == str(contact_id):
                    target.update(result="skipped", reason="release_revoked")
        for target in targets:
            count = per_contact.get(uuid.UUID(target["contact_id"]), 0)
            if count and target["result"] == "messaged":
                target["releases"] = count
        alerted = await EngineStore.alerted_contacts(session, incident.id) if per_contact else set()

        last_checkin = await EngineStore.last_checkin_at(session, incident.user_id)
        drafts = [
            Draft(
                user_id=incident.user_id,
                audience="contact",
                category=outbox.CATEGORY_ESCALATION,
                channel="email",
                template_key=_contact_template(
                    per_contact.get(contact_id, 0), contact_id in alerted
                ),
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
                    **(
                        {
                            "release_count": per_contact[contact_id],
                            "after_minutes": stage.offset_minutes,
                        }
                        if per_contact.get(contact_id)
                        else {}
                    ),
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
                "release_count": sum(per_contact.values()),
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
        if per_contact:
            await self._record(
                session,
                audit.RELEASE_CREATED,
                incident,
                action,
                now,
                {"stage": stage.position, "releases": sum(per_contact.values())},
            )

    async def _create_releases(
        self,
        session: AsyncSession,
        incident: EscalationIncident,
        action: IncidentAction,
        step_id: uuid.UUID,
        valid_releases: list[SnapshotRelease],
        messaged: set[uuid.UUID],
        now: datetime,
    ) -> dict[uuid.UUID, int]:
        """Contact -> number of releases recorded. Only releases that passed G8 whose contact
        passed G7; a release that was revoked for any reason but a Hold rollback stays revoked."""
        repository = ReleaseRepository(session)
        for release in valid_releases:
            if release.contact_id not in messaged:
                continue
            await repository.create(
                owner_id=incident.user_id,
                incident_id=incident.id,
                action_id=action.id,
                instruction_id=release.instruction_id,
                contact_id=release.contact_id,
                step_id=step_id,
                released_at=now,
                visible_after=now + self._settle,
            )
        live = await repository.live_counts_for_action(
            owner_id=incident.user_id, action_id=action.id
        )
        per_contact = {c: n for c, n in live.items() if c in messaged}
        for contact_id in per_contact:
            await repository.ensure_access(
                owner_id=incident.user_id, incident_id=incident.id, contact_id=contact_id
            )
        return per_contact

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
