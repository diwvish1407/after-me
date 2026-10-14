"""System Hold: the circuit breaker (ESCALATION_ENGINE §7).

If users *cannot* check in (API or ingress down, a broken release), deadlines pass through no
fault of theirs. Hold stops the engine from alerting contacts for everyone at once.

* **Ingestion**: an external monitor probes the public ingress every minute
  (``POST /internal/probe``). If probes go stale for ``INGESTION_STALE`` the Hold starts,
  *backdated* to the last good probe; it ends automatically after probes have been fresh for
  ``HOLD_EXIT_FRESH``. Gaps that happened while the worker itself was down are found afterwards
  by scanning the probe history and recorded as closed windows.
* **Anomaly**: far more incidents than normal in an hour: manual exit only.
* **Operator**: ``afterme-admin hold enter|exit``.

While a Hold is active nothing contact-facing happens. When it ends, in one transaction per
affected user: undelivered stage effects inside the window are rolled back, pending stages are
shifted by ``(window length + recovery buffer)``, and the user is told to check in.
"""

from __future__ import annotations

import math
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from itertools import pairwise

from sqlalchemy import func, or_, select, text, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.audit import writer as audit
from app.audit.writer import AuditEvent
from app.checkins.models import CheckinConfiguration
from app.core.logging import get_logger
from app.core.models import SystemFlag
from app.engine.store import EngineStore
from app.incidents.models import (
    OPEN_STATUSES,
    EscalationIncident,
    IncidentAction,
)
from app.notifications import outbox
from app.notifications.models import Notification
from app.notifications.outbox import Draft
from app.ops.models import IngestionProbe, SystemHold
from app.releases.repository import ReleaseRepository

_log = get_logger("afterme.hold")

WATERMARK_KEY = "probe_watermark"
# One advisory lock key for every Hold decision, so that two workers cannot both decide to
# enter (or record the same window of) a Hold: the check and the insert are one critical section.
HOLD_LOCK_KEY = 0x41667465724D65  # "AfterMe"
ANOMALY_WINDOW = timedelta(hours=1)
# How "far more incidents than normal" is judged (ESCALATION_ENGINE §7.2). Many people share a
# due time, so the same hour on earlier days is the baseline, not the average hour; and what is
# normal grows with the number of people, so the fractions below are of the active users.
ANOMALY_BASELINE_DAYS = 14
ANOMALY_MIN_HISTORY = timedelta(days=7)
ANOMALY_MULTIPLIER = 4
ANOMALY_LEARNING_FRACTION = 0.5  # no history yet: half of everyone in an hour
ANOMALY_MIN_FRACTION = 0.10  # with history: never below a tenth of everyone
ANOMALY_CAP_FRACTION = 0.9  # ... and above nine tenths is abnormal whatever the baseline


@dataclass
class HoldReport:
    entered: list[str] = field(default_factory=list)
    exited: int = 0
    windows_recorded: int = 0
    users_processed: int = 0
    rolled_back_stages: int = 0
    shifted_actions: int = 0
    cancelled_messages: int = 0


class HoldMonitor:
    def __init__(self, services: AppServices) -> None:
        self.services = services
        self.settings = services.settings
        self.db = services.db
        self.clock = services.clock

    # ------------------------------------------------------------------ the tick step

    async def evaluate(self, now: datetime) -> HoldReport:
        report = HoldReport()
        if self.settings.ingestion_monitoring_enabled:
            async with self.db.sessionmaker() as session, session.begin():
                await self._serialise(session)
                report.windows_recorded = await self._scan_probe_history(session, now)
                started = await self._ingestion_trigger(session, now)
                if started:
                    report.entered.append("ingestion")
            async with self.db.sessionmaker() as session, session.begin():
                await self._serialise(session)
                await self._auto_exit(session, now)
        async with self.db.sessionmaker() as session, session.begin():
            await self._serialise(session)
            if await self._anomaly_trigger(session, now):
                report.entered.append("anomaly")
        await self._process_exits(now, report)
        return report

    @staticmethod
    async def _serialise(session: AsyncSession) -> None:
        """Held until the transaction ends. Short: every step under it is a handful of reads."""
        await session.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": HOLD_LOCK_KEY})

    # ------------------------------------------------------------------ ingestion

    async def _latest_probe(self, session: AsyncSession) -> datetime | None:
        return (await session.execute(select(func.max(IngestionProbe.received_at)))).scalar_one()

    async def _ingestion_trigger(self, session: AsyncSession, now: datetime) -> bool:
        """Start a Hold when the latest probe is older than ``INGESTION_STALE``."""
        stale = timedelta(seconds=self.settings.ingestion_stale_seconds)
        last = await self._latest_probe(session)
        if last is not None and now - last <= stale:
            return False
        if await self._open_hold_of(session, "ingestion") is not None:
            return False
        # Backdated to the last good probe: the settle delay (5 min) is longer than detection
        # (3 min), so a stage that ran in the gap is still undelivered and can be rolled back.
        started_at = last if last is not None else now
        await self._enter(session, "ingestion", started_at, now, "system", None)
        return True

    async def _scan_probe_history(self, session: AsyncSession, now: datetime) -> int:
        """Gaps in the probe history since the watermark that the worker did not see live (it was
        down): recorded as closed Hold windows so their effects are rolled back and shifted."""
        stale = timedelta(seconds=self.settings.ingestion_stale_seconds)
        row = (
            await session.execute(select(SystemFlag).where(SystemFlag.key == WATERMARK_KEY))
        ).scalar_one_or_none()
        watermark: datetime | None = None
        if row is not None:
            watermark = datetime.fromisoformat(row.value["at"])
        stmt = select(IngestionProbe.received_at).order_by(IngestionProbe.received_at)
        if watermark is not None:
            stmt = stmt.where(IngestionProbe.received_at > watermark)
        times = [r[0] for r in (await session.execute(stmt)).all()]
        if not times:
            return 0
        recorded = 0
        previous = watermark
        for current in times:
            if (
                previous is not None
                and current - previous > stale
                and not await self._overlaps_existing(session, previous, current)
            ):
                await self._record_window(session, previous, current, now)
                recorded += 1
            previous = current
        await self._store_watermark(session, times[-1], now)
        return recorded

    @staticmethod
    async def _store_watermark(session: AsyncSession, at: datetime, now: datetime) -> None:
        await session.execute(
            insert(SystemFlag)
            .values(
                key=WATERMARK_KEY,
                value={"at": at.isoformat()},
                updated_at=now,
                updated_by="engine",
            )
            .on_conflict_do_update(
                index_elements=[SystemFlag.key],
                set_={"value": {"at": at.isoformat()}, "updated_at": now},
            )
        )

    @staticmethod
    async def _overlaps_existing(session: AsyncSession, start: datetime, end: datetime) -> bool:
        stmt = select(
            select(SystemHold.id)
            .where(
                SystemHold.started_at <= end,
                func.coalesce(SystemHold.ended_at, end) >= start,
            )
            .exists()
        )
        return bool((await session.execute(stmt)).scalar_one())

    async def _record_window(
        self, session: AsyncSession, start: datetime, end: datetime, now: datetime
    ) -> None:
        session.add(
            SystemHold(
                reason="ingestion",
                started_at=start,
                detected_at=now,
                ended_at=end,
                created_by="system",
                notes="gap in probe history found after the fact",
            )
        )
        await session.flush()
        _log.critical("system.hold_window_recorded", started_at=start.isoformat())

    async def _auto_exit(self, session: AsyncSession, now: datetime) -> None:
        """End an ingestion Hold once probes have been fresh, without a gap, for
        ``HOLD_EXIT_FRESH``."""
        hold = await self._open_hold_of(session, "ingestion")
        if hold is None:
            return
        stale = timedelta(seconds=self.settings.ingestion_stale_seconds)
        window = timedelta(seconds=self.settings.hold_exit_fresh_seconds)
        times = [
            r[0]
            for r in (
                await session.execute(
                    select(IngestionProbe.received_at)
                    .where(IngestionProbe.received_at >= now - window)
                    .order_by(IngestionProbe.received_at)
                )
            ).all()
        ]
        if not times:
            return
        # "Fresh for the whole window" means the stretch of healthy probing *starts* no later
        # than the window does: the last probe before the window must be within one staleness
        # period of it (Phase 10 game day OPS-01: measured from the window's edge alone, the
        # first fresh probe could arrive up to INGESTION_STALE into the window, and the Hold
        # ended 7 minutes after recovery instead of the documented 10).
        start = now - window
        before: datetime | None = (
            await session.execute(
                select(func.max(IngestionProbe.received_at)).where(
                    IngestionProbe.received_at < start
                )
            )
        ).scalar_one()
        if before is None or start - before > stale:
            return
        edges = [before, *times, now]
        if any(b - a > stale for a, b in pairwise(edges)):
            return
        await self._end(session, hold, now, "system")

    # ------------------------------------------------------------------ anomaly

    async def _anomaly_trigger(self, session: AsyncSession, now: datetime) -> bool:
        if await self._open_hold_of(session, "anomaly") is not None:
            return False
        # Only incidents opened since the last anomaly Hold ended count: an operator who exits
        # within the hour must not walk straight back in over the same burst (and stack shifts).
        since = now - ANOMALY_WINDOW
        last_end = (
            await session.execute(
                select(func.max(SystemHold.ended_at)).where(SystemHold.reason == "anomaly")
            )
        ).scalar_one()
        if last_end is not None:
            since = max(since, last_end)
        recent = int(
            (
                await session.execute(
                    select(func.count()).where(
                        EscalationIncident.opened_at > since,
                        EscalationIncident.opened_at <= now,
                    )
                )
            ).scalar_one()
        )
        if recent <= self.settings.anomaly_floor_per_hour:
            return False  # cannot exceed the floor: skip the rest
        if recent <= await self._anomaly_threshold(session, now):
            return False
        await self._enter(session, "anomaly", since, now, "system", f"{recent} in an hour")
        return True

    async def _anomaly_threshold(self, session: AsyncSession, now: datetime) -> int:
        """How many incidents opened in an hour are still normal.

        * Without a week of history: the floor, or half of all active users, whichever is more.
        * With it: four times the most that opened in this same hour on any of the last 14
          days, held between a tenth and nine tenths of all active users and never below the
          floor. (A due time shared by many people makes one hour of every day busy; that
          must not be an anomaly, and a bad release that stops check-ins still is, because it
          takes nearly everyone who is due.)
        """
        active = await self._active_users(session)
        floor = self.settings.anomaly_floor_per_hour
        if not await self._has_history(session, now):
            return max(floor, math.ceil(ANOMALY_LEARNING_FRACTION * active))
        learned = min(
            ANOMALY_MULTIPLIER * await self._same_hour_baseline(session, now),
            math.ceil(ANOMALY_CAP_FRACTION * active),
        )
        return max(floor, math.ceil(ANOMALY_MIN_FRACTION * active), learned)

    @staticmethod
    async def _active_users(session: AsyncSession) -> int:
        """People whose safety net is on: the population that can open an incident."""
        stmt = select(func.count()).where(
            CheckinConfiguration.status.in_(("active", "incident_open"))
        )
        return int((await session.execute(stmt)).scalar_one())

    @staticmethod
    async def _has_history(session: AsyncSession, now: datetime) -> bool:
        oldest: datetime | None = (
            await session.execute(select(func.min(EscalationIncident.opened_at)))
        ).scalar_one()
        return oldest is not None and now - oldest >= ANOMALY_MIN_HISTORY

    @staticmethod
    async def _same_hour_baseline(session: AsyncSession, now: datetime) -> int:
        """The largest number of incidents opened in the hour ending at this time of day, over
        the last ``ANOMALY_BASELINE_DAYS`` days (the current hour is not part of it)."""
        row = (
            await session.execute(
                text(
                    "SELECT coalesce(max(n), 0) FROM ("
                    "  SELECT d, count(i.id) AS n "
                    "  FROM generate_series(1, :days) AS d "
                    "  LEFT JOIN escalation_incidents i "
                    "    ON i.opened_at > :now - d * interval '1 day' - interval '1 hour' "
                    "   AND i.opened_at <= :now - d * interval '1 day' "
                    "  GROUP BY d) q"
                ),
                {"days": ANOMALY_BASELINE_DAYS, "now": now},
            )
        ).scalar_one()
        return int(row)

    # ------------------------------------------------------------------ enter and exit

    @staticmethod
    async def _open_hold_of(session: AsyncSession, reason: str) -> SystemHold | None:
        stmt = (
            select(SystemHold)
            .where(SystemHold.reason == reason, SystemHold.ended_at.is_(None))
            .limit(1)
        )
        return (await session.execute(stmt)).scalar_one_or_none()

    async def _enter(
        self,
        session: AsyncSession,
        reason: str,
        started_at: datetime,
        now: datetime,
        created_by: str,
        notes: str | None,
    ) -> SystemHold:
        hold = SystemHold(
            reason=reason,
            started_at=started_at,
            detected_at=now,
            created_by=created_by,
            notes=notes,
        )
        session.add(hold)
        await session.flush()
        _log.critical("system.hold_entered", reason=reason, hold_id=str(hold.id))
        await self.services.audit.record(
            session,
            AuditEvent(
                action=audit.HOLD_ENTERED,
                occurred_at=now,
                subject_user_id=None,
                actor_type="system" if created_by == "system" else "operator",
                resource_type="system_hold",
                resource_id=hold.id,
                metadata={"reason": reason},
            ),
        )
        return hold

    async def _end(self, session: AsyncSession, hold: SystemHold, now: datetime, by: str) -> None:
        hold.ended_at = now
        _log.warning("system.hold_ended", hold_id=str(hold.id), reason=hold.reason, by=by)

    # ------------------------------------------------------------------ exit processing (§7.3)

    async def _process_exits(self, now: datetime, report: HoldReport) -> None:
        async with self.db.sessionmaker() as session:
            holds = list(
                (
                    await session.execute(
                        select(SystemHold)
                        .where(
                            SystemHold.ended_at.is_not(None),
                            SystemHold.exit_processed_at.is_(None),
                        )
                        .order_by(SystemHold.started_at)
                    )
                ).scalars()
            )
        for hold in holds:
            await self._process_exit(hold, now, report)

    async def _process_exit(self, hold: SystemHold, now: datetime, report: HoldReport) -> None:
        assert hold.ended_at is not None  # noqa: S101 - selected on ended_at IS NOT NULL
        window_start, window_end = hold.started_at, hold.ended_at
        # A stage that ran up to SETTLE before the outage began is still undelivered when the
        # outage is detected (that is what the settle delay is for), and the person may have
        # tried to check in during the outage: it is taken back with the rest.
        settle = timedelta(seconds=self.settings.settle_delay_seconds)
        shift = (window_end - window_start) + timedelta(
            minutes=self.settings.hold_recovery_buffer_minutes
        )
        async with self.db.sessionmaker() as session:
            users = list(
                (
                    await session.execute(
                        select(EscalationIncident.user_id)
                        .where(
                            EscalationIncident.status.in_(OPEN_STATUSES),
                            # An incident opened after the window ended was never affected
                            # by it (its grace started afterwards): a window found late, from
                            # the probe history, must not shift it.
                            EscalationIncident.opened_at <= window_end,
                        )
                        .distinct()
                        .order_by(EscalationIncident.user_id)
                    )
                ).scalars()
            )
        pending_users = 0
        for user_id in users:
            try:
                async with self.db.sessionmaker() as session, session.begin():
                    done = await self._exit_for_user(
                        session,
                        hold,
                        user_id,
                        window_start - settle,
                        window_end,
                        shift,
                        now,
                        report,
                    )
            except Exception as exc:
                done = False
                _log.error("hold.exit_failed", user_id=str(user_id), error_class=type(exc).__name__)
            if not done:
                pending_users += 1
        if pending_users:
            return  # some users were busy: the exit is retried on the next tick
        async with self.db.sessionmaker() as session, session.begin():
            await session.execute(
                update(SystemHold).where(SystemHold.id == hold.id).values(exit_processed_at=now)
            )
            await self.services.audit.record(
                session,
                AuditEvent(
                    action=audit.HOLD_EXITED,
                    occurred_at=now,
                    subject_user_id=None,
                    actor_type="system",
                    resource_type="system_hold",
                    resource_id=hold.id,
                    metadata={
                        "reason": hold.reason,
                        "users": report.users_processed,
                        "rolled_back": report.rolled_back_stages,
                        "shifted": report.shifted_actions,
                    },
                ),
            )
        report.exited += 1

    async def _exit_for_user(
        self,
        session: AsyncSession,
        hold: SystemHold,
        user_id: uuid.UUID,
        window_start: datetime,
        window_end: datetime,
        shift: timedelta,
        now: datetime,
        report: HoldReport,
    ) -> bool:
        """One user, one transaction. Returns ``False`` when the user's lock was busy."""
        config = await EngineStore.lock_user(session, user_id)
        if config is None:
            return False
        incidents = list(
            (
                await session.execute(
                    select(EscalationIncident)
                    .where(
                        EscalationIncident.user_id == user_id,
                        EscalationIncident.status.in_(OPEN_STATUSES),
                        EscalationIncident.opened_at <= window_end,
                    )
                    .with_for_update()
                    .execution_options(populate_existing=True)
                )
            ).scalars()
        )
        if not incidents:
            return True
        # The user notice doubles as the "already processed for this hold" marker: it is
        # written in this same transaction, and its dedupe key is unique per hold and user.
        notice = [
            Draft(
                user_id=user_id,
                audience="user",
                category=outbox.CATEGORY_USER,
                channel=channel,
                template_key=outbox.USER_HOLD_NOTICE,
                send_after=now,
                dedupe_key=f"holdnotice:{hold.id}:{user_id}:{channel}",
                params={"hold_id": str(hold.id)},
            )
            for channel in outbox.USER_CHANNELS[outbox.USER_HOLD_NOTICE]
            if channel == "email"
        ]
        if await outbox.enqueue(session, notice, now=now) == 0:
            return True  # a previous attempt already did this user

        for incident in incidents:
            actions = list(
                (
                    await session.execute(
                        select(IncidentAction)
                        .where(IncidentAction.incident_id == incident.id)
                        .order_by(IncidentAction.scheduled_for, IncidentAction.id)
                        .with_for_update()
                        .execution_options(populate_existing=True)
                    )
                ).scalars()
            )
            for action in actions:
                if (
                    action.kind == "execute_stage"
                    and action.status == "executed"
                    and action.executed_at is not None
                    and window_start <= action.executed_at <= window_end
                    and await self._undelivered(session, action)
                ):
                    # Nothing left the system: take the stage back, as if it never ran.
                    cancelled = await self._cancel_messages(session, action, now)
                    report.cancelled_messages += cancelled
                    await ReleaseRepository(session).rollback_action(
                        owner_id=user_id, action_id=action.id, now=now
                    )
                    action.status = "pending"
                    action.executed_at = None
                    action.outcome = None
                    action.updated_at = now
                    report.rolled_back_stages += 1
            await self._restore_status(session, incident, actions, now)
            for action in actions:
                if action.status == "pending" and action.kind in (
                    "execute_stage",
                    "user_final_warning",
                ):
                    action.scheduled_for = action.scheduled_for + shift
                    action.updated_at = now
                    report.shifted_actions += 1
        report.users_processed += 1
        return True

    @staticmethod
    async def _undelivered(session: AsyncSession, action: IncidentAction) -> bool:
        """No message of this action was ever handed to a provider (``sending``/``sent``)."""
        stmt = select(
            select(Notification.id)
            .where(
                Notification.action_id == action.id,
                Notification.category == outbox.CATEGORY_ESCALATION,
                Notification.status.in_(("sending", "sent")),
            )
            .exists()
        )
        return not bool((await session.execute(stmt)).scalar_one())

    @staticmethod
    async def _cancel_messages(session: AsyncSession, action: IncidentAction, now: datetime) -> int:
        result = await session.execute(
            update(Notification)
            .where(
                Notification.action_id == action.id,
                Notification.status == "queued",
                or_(
                    Notification.category == outbox.CATEGORY_ESCALATION,
                    Notification.template_key == outbox.USER_STAGE_EXECUTED,
                ),
            )
            .values(status="cancelled", cancelled_reason="hold_rollback", updated_at=now)
            .returning(Notification.id)
        )
        return len(result.all())

    @staticmethod
    async def _restore_status(
        session: AsyncSession,
        incident: EscalationIncident,
        actions: list[IncidentAction],
        now: datetime,
    ) -> None:
        stages = [a for a in actions if a.kind == "execute_stage"]
        executed = [a for a in stages if a.status == "executed"]
        pending = [a for a in stages if a.status == "pending"]
        if not stages:
            return
        if not executed:
            status = "grace"
        elif pending:
            status = "escalating"
        else:
            status = "escalated"
        if incident.status != status:
            incident.status = status
            incident.updated_at = now
