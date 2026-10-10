"""The escalation engine's tick (ESCALATION_ENGINE §6.1).

``Engine.tick`` runs the steps in order: heartbeat, Hold evaluation, open due incidents,
execute due actions, enqueue pre-deadline reminders. The outbox dispatcher is a separate loop
with the same rules (:mod:`app.engine.dispatcher`).

Each unit of work (one user) runs in its own short transaction. An exception rolls that unit
back, is logged by class only, is counted, and the unit is retried on the next tick; every
other user is unaffected.
"""

from __future__ import annotations

import socket
import uuid
from dataclasses import dataclass, field
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.exc import DBAPIError, InterfaceError, OperationalError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.audit import writer as audit
from app.audit.writer import AuditEvent
from app.checkins.models import CheckinConfiguration
from app.core.logging import get_logger
from app.engine.executor import ActionExecutor, UnitReport
from app.engine.hold import HoldMonitor, HoldReport
from app.engine.opener import OpenResult, open_incident
from app.engine.releases import NoReleases, ReleaseSource
from app.engine.store import DueDeadline, EngineStore
from app.notifications import outbox
from app.notifications.outbox import Draft

_log = get_logger("afterme.engine")

BATCH = 200
MAX_PAGES = 10  # per step and tick: 2000 users; a full last page marks a backlog
SERVICE_NAME = "engine"
HOLD_SERVICE_NAME = "hold_monitor"  # beats only when Hold evaluation succeeded
ENGINE_VERSION = "5.0"


@dataclass
class TickReport:
    opened: int = 0
    open_skipped: dict[str, int] = field(default_factory=dict)
    executed: int = 0
    cancelled: int = 0
    held: int = 0
    left_pending: int = 0
    locked_out: int = 0
    messages_queued: int = 0
    pre_reminders: int = 0
    errors: int = 0
    gates: dict[str, int] = field(default_factory=dict)
    hold: HoldReport = field(default_factory=HoldReport)
    # Hold evaluation failed: whether a Hold is in force is unknown, so nothing contact-facing
    # may leave this cycle (INV-4, INV-10). The worker passes this on to the dispatcher.
    hold_unknown: bool = False
    # A step used all its pages and the last one was full: more is waiting, do not sleep.
    backlog: bool = False

    def absorb(self, unit: UnitReport) -> None:
        self.executed += unit.executed
        self.cancelled += unit.cancelled
        self.held += unit.held
        self.left_pending += unit.left_pending
        self.messages_queued += unit.messages_queued
        self.locked_out += 1 if unit.skipped_locked else 0
        for gate, count in unit.gates.items():
            self.gates[gate] = self.gates.get(gate, 0) + count


def _is_transient(exc: BaseException) -> bool:
    """Connection loss, lock timeouts and the like: not the action's fault."""
    if isinstance(exc, DBAPIError):
        return exc.connection_invalidated or isinstance(exc, OperationalError | InterfaceError)
    return isinstance(exc, OSError | TimeoutError)


class Engine:
    def __init__(
        self,
        services: AppServices,
        *,
        releases: ReleaseSource | None = None,
        instance_id: str | None = None,
    ) -> None:
        self.services = services
        self.settings = services.settings
        self.db = services.db
        self.clock = services.clock
        self.instance_id = instance_id or f"{socket.gethostname()}:{uuid.uuid4().hex[:8]}"
        self.releases: ReleaseSource = releases or NoReleases()
        self.hold = HoldMonitor(services)
        self.executor = ActionExecutor(
            settings=self.settings,
            audit_writer=services.audit,
            pepper=services.pepper,
            releases=self.releases,
        )

    # ------------------------------------------------------------------ the tick

    async def tick(self) -> TickReport:
        report = TickReport()
        async with self.db.sessionmaker() as session, session.begin():
            now = await self.clock.now(session)
            await EngineStore.heartbeat(
                session,
                service=SERVICE_NAME,
                instance_id=self.instance_id,
                version=ENGINE_VERSION,
                now=now,
            )
        try:  # a failure here must not stop reminders; Hold is re-evaluated next tick
            report.hold = await self.hold.evaluate(now)
            async with self.db.sessionmaker() as session, session.begin():
                await EngineStore.heartbeat(
                    session,
                    service=HOLD_SERVICE_NAME,
                    instance_id=self.instance_id,
                    version=ENGINE_VERSION,
                    now=await self.clock.now(session),
                )
        except Exception as exc:
            # Fail safe: an unknown Hold state is treated as a Hold. Incidents are not opened,
            # contact-facing stages stay pending, and the dispatcher is told not to send them.
            # User reminders (never contact-facing) continue.
            report.errors += 1
            report.hold_unknown = True
            _log.error("engine.hold_failed", error_class=type(exc).__name__)
        if not report.hold_unknown:
            await self.open_due_incidents(now, report)
        await self.execute_due_actions(now, report)
        await self.enqueue_pre_deadline_reminders(now, report)
        if report.errors or report.held:
            _log.warning("engine.tick_attention", errors=report.errors, held=report.held)
        return report

    # ------------------------------------------------------------------ opening

    async def open_due_incidents(self, now: datetime, report: TickReport) -> None:
        seen: set[uuid.UUID] = set()
        for page in range(MAX_PAGES):
            async with self.db.sessionmaker() as session:
                due = await EngineStore.due_deadlines(session, now, BATCH, exclude=seen)
            if not due:
                return
            await self._open_page(due, seen, report)
            if len(due) < BATCH:
                return
            if page == MAX_PAGES - 1:
                report.backlog = True

    async def _open_page(
        self, due: list[DueDeadline], seen: set[uuid.UUID], report: TickReport
    ) -> None:
        # Users that were looked at stay out of the later pages of this tick, so rows that
        # cannot be opened (no plan, inconsistent) never starve the users behind them.
        for deadline in due:
            seen.add(deadline.user_id)
            try:
                async with self.db.sessionmaker() as session, session.begin():
                    unit_now = await self.clock.now(session)
                    result = await open_incident(
                        session,
                        user_id=deadline.user_id,
                        now=unit_now,
                        settings=self.settings,
                        audit_writer=self.services.audit,
                        releases=self.releases,
                    )
            except Exception as exc:  # one user's failure must not stop the others
                report.errors += 1
                _log.error(
                    "engine.open_failed",
                    user_id=str(deadline.user_id),
                    error_class=type(exc).__name__,
                )
                continue
            if result is OpenResult.OPENED:
                report.opened += 1
            else:
                report.open_skipped[result.value] = report.open_skipped.get(result.value, 0) + 1

    # ------------------------------------------------------------------ executing

    async def execute_due_actions(self, now: datetime, report: TickReport) -> None:
        seen: set[uuid.UUID] = set()
        for page in range(MAX_PAGES):
            async with self.db.sessionmaker() as session:
                users = await EngineStore.users_with_due_actions(session, now, BATCH, exclude=seen)
            if not users:
                return
            seen.update(users)
            await self._execute_page(users, report)
            if len(users) < BATCH:
                return
            if page == MAX_PAGES - 1:
                report.backlog = True

    async def _execute_page(self, users: list[uuid.UUID], report: TickReport) -> None:
        for user_id in users:
            current: list[uuid.UUID] = []
            try:
                async with self.db.sessionmaker() as session, session.begin():
                    unit_now = await self.clock.now(session)
                    unit = await self.executor.run_user(
                        session,
                        user_id=user_id,
                        now=unit_now,
                        current=current,
                        force_hold=report.hold_unknown,
                    )
                report.absorb(unit)
            except Exception as exc:
                report.errors += 1
                _log.error(
                    "engine.unit_failed",
                    user_id=str(user_id),
                    action_id=str(current[0]) if current else None,
                    error_class=type(exc).__name__,
                )
                # An infrastructure error (connection, lock timeout) says nothing about the
                # action: it is retried next tick without counting towards ``held``, which is
                # for actions that fail for their own reasons and never clear (FS-23).
                if current and not _is_transient(exc):
                    await self._count_failed_attempt(user_id, current[0], type(exc).__name__)

    async def _count_failed_attempt(
        self, user_id: uuid.UUID, action_id: uuid.UUID, error_class: str
    ) -> None:
        """After the unit rolled back: count the attempt in its own transaction. After
        ``ACTION_MAX_ATTEMPTS`` the action is ``held`` for good (FS-23)."""
        try:
            async with self.db.sessionmaker() as session, session.begin():
                now = await self.clock.now(session)
                status = await EngineStore.record_failed_attempt(
                    session,
                    action_id,
                    error_class=error_class,
                    max_attempts=self.settings.action_max_attempts,
                    now=now,
                )
                if status == "held":
                    _log.critical(
                        "engine.action_held",
                        user_id=str(user_id),
                        action_id=str(action_id),
                        gate="attempts",
                    )
                    await self.services.audit.record(
                        session,
                        AuditEvent(
                            action=audit.ACTION_HELD,
                            occurred_at=now,
                            subject_user_id=user_id,
                            actor_type="system",
                            resource_type="incident_action",
                            resource_id=action_id,
                            metadata={"gate": "attempts", "error_class": error_class},
                        ),
                    )
        except Exception as exc:  # pragma: no cover - bookkeeping must never crash the loop
            _log.error("engine.attempt_count_failed", error_class=type(exc).__name__)

    # ------------------------------------------------------------------ pre-deadline reminders

    async def enqueue_pre_deadline_reminders(self, now: datetime, report: TickReport) -> None:
        seen: set[uuid.UUID] = set()
        for page in range(MAX_PAGES):
            async with self.db.sessionmaker() as session:
                candidates = await EngineStore.reminder_candidates(
                    session, now, BATCH, exclude=seen
                )
            if not candidates:
                return
            seen.update(c[0] for c in candidates)
            await self._remind_page(candidates, report)
            if len(candidates) < BATCH:
                return
            if page == MAX_PAGES - 1:
                report.backlog = True

    async def _remind_page(
        self, candidates: list[tuple[uuid.UUID, datetime, int]], report: TickReport
    ) -> None:
        for user_id, due_at, _lead in candidates:
            try:
                async with self.db.sessionmaker() as session, session.begin():
                    unit_now = await self.clock.now(session)
                    queued = await self._pre_reminder(session, user_id, due_at, unit_now)
                report.pre_reminders += queued
            except Exception as exc:
                report.errors += 1
                _log.error(
                    "engine.reminder_failed",
                    user_id=str(user_id),
                    error_class=type(exc).__name__,
                )

    async def _pre_reminder(
        self, session: AsyncSession, user_id: uuid.UUID, due_at: datetime, now: datetime
    ) -> int:
        config = (
            await session.execute(
                select(CheckinConfiguration).where(CheckinConfiguration.user_id == user_id)
            )
        ).scalar_one_or_none()
        # Re-read: the person may have checked in, or changed the schedule, since the candidate
        # query. A reminder is only for the deadline it was queued for.
        if config is None or config.status != "active" or config.next_due_at != due_at:
            return 0
        user = await EngineStore.user(session, user_id)
        if user is None or user.status != "active":
            return 0
        stamp = due_at.isoformat()
        drafts: list[Draft] = []
        for device_id in await EngineStore.push_devices(session, user_id):
            drafts.append(
                Draft(
                    user_id=user_id,
                    audience="user",
                    category=outbox.CATEGORY_USER,
                    channel="push",
                    template_key=outbox.USER_PRE_REMINDER,
                    send_after=now,
                    dedupe_key=f"prereminder:{user_id}:{stamp}:push:{device_id}",
                    device_id=device_id,
                    params={"due_at": stamp},
                )
            )
        drafts.append(
            Draft(
                user_id=user_id,
                audience="user",
                category=outbox.CATEGORY_USER,
                channel="email",
                template_key=outbox.USER_PRE_REMINDER,
                send_after=now,
                dedupe_key=f"prereminder:{user_id}:{stamp}:email",
                params={"due_at": stamp},
            )
        )
        return await outbox.enqueue(session, drafts, now=now)
