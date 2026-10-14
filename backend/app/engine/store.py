"""System-level queries of the escalation worker.

Unlike the owner-scoped repositories behind the API, these look across users (which accounts
have a deadline that passed, which actions are due). They live in ``app.engine``, which the API
never imports (a test enforces it), and they run as the ``afterme_worker`` database role.
Every query that then *changes* one user's state takes that user's lock first (§6.2).
"""

from __future__ import annotations

import uuid
from collections.abc import Collection
from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import BigInteger, Text, and_, cast, exists, func, or_, select, text, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.models import Device, User
from app.checkins.models import CheckinConfiguration, CheckinEvent
from app.contacts.models import EmailSuppression, TrustedContact
from app.incidents.models import OPEN_STATUSES, EscalationIncident, IncidentAction
from app.notifications.models import Notification
from app.ops.models import ServiceHeartbeat, SystemHold
from app.plans.models import EscalationPlan, EscalationStep, EscalationStepContact


@dataclass(frozen=True)
class DueDeadline:
    user_id: uuid.UUID
    next_due_at: datetime


# The largest ``reminder_lead_minutes`` the CHECK on ``checkin_configurations`` allows. A
# deadline further away than this cannot be inside any person's reminder window, so the
# candidate scan stops there instead of reading every deadline of the next days.
MAX_REMINDER_LEAD_MINUTES = 240


def pre_reminder_stamp(due_at: datetime) -> str:
    """What identifies one deadline in a pre-deadline reminder's dedupe key: whole seconds since
    the epoch. SQL builds the same text (``reminder_candidates``), so the candidate scan can tell
    which deadlines were already reminded without a column of its own."""
    return str(int(due_at.timestamp()))


class EngineStore:
    # ------------------------------------------------------------------ locking

    @staticmethod
    async def lock_user(session: AsyncSession, user_id: uuid.UUID) -> CheckinConfiguration | None:
        """THE per-user lock (§6.2) with ``SKIP LOCKED``: ``None`` when another replica or a
        request holds it, in which case the unit is simply retried on the next tick."""
        stmt = (
            select(CheckinConfiguration)
            .where(CheckinConfiguration.user_id == user_id)
            .with_for_update(skip_locked=True)
            .execution_options(populate_existing=True)
        )
        return (await session.execute(stmt)).scalar_one_or_none()

    # ------------------------------------------------------------------ opening

    @staticmethod
    async def due_deadlines(
        session: AsyncSession,
        now: datetime,
        limit: int,
        *,
        exclude: Collection[uuid.UUID] = (),
    ) -> list[DueDeadline]:
        stmt = (
            select(CheckinConfiguration.user_id, CheckinConfiguration.next_due_at)
            .where(
                CheckinConfiguration.status == "active",
                CheckinConfiguration.next_due_at <= now,
            )
            .order_by(CheckinConfiguration.next_due_at, CheckinConfiguration.user_id)
            .limit(limit)
        )
        if exclude:
            stmt = stmt.where(CheckinConfiguration.user_id.not_in(exclude))
        rows = (await session.execute(stmt)).all()
        return [DueDeadline(r[0], r[1]) for r in rows if r[1] is not None]

    @staticmethod
    async def has_unabsorbed_checkin(
        session: AsyncSession, user_id: uuid.UUID, baseline_at: datetime
    ) -> bool:
        """A check-in the schedule did not absorb (FS-25): ``received_at > baseline_at``."""
        stmt = select(
            exists().where(CheckinEvent.user_id == user_id, CheckinEvent.received_at > baseline_at)
        )
        return bool((await session.execute(stmt)).scalar_one())

    @staticmethod
    async def checkin_after(session: AsyncSession, user_id: uuid.UUID, instant: datetime) -> bool:
        """G3: any check-in event received after ``instant``."""
        stmt = select(
            exists().where(CheckinEvent.user_id == user_id, CheckinEvent.received_at > instant)
        )
        return bool((await session.execute(stmt)).scalar_one())

    @staticmethod
    async def last_checkin_at(session: AsyncSession, user_id: uuid.UUID) -> datetime | None:
        stmt = select(func.max(CheckinEvent.received_at)).where(CheckinEvent.user_id == user_id)
        return (await session.execute(stmt)).scalar_one_or_none()

    @staticmethod
    async def user(session: AsyncSession, user_id: uuid.UUID) -> User | None:
        return (await session.execute(select(User).where(User.id == user_id))).scalar_one_or_none()

    @staticmethod
    async def plan(session: AsyncSession, user_id: uuid.UUID) -> EscalationPlan | None:
        return (
            await session.execute(select(EscalationPlan).where(EscalationPlan.user_id == user_id))
        ).scalar_one_or_none()

    @staticmethod
    async def stages(
        session: AsyncSession, plan_id: uuid.UUID
    ) -> list[tuple[EscalationStep, list[uuid.UUID]]]:
        steps = list(
            (
                await session.execute(
                    select(EscalationStep)
                    .where(EscalationStep.plan_id == plan_id)
                    .order_by(EscalationStep.position)
                )
            ).scalars()
        )
        rows = (
            await session.execute(
                select(EscalationStepContact.step_id, EscalationStepContact.contact_id)
                .join(EscalationStep, EscalationStep.id == EscalationStepContact.step_id)
                .where(EscalationStep.plan_id == plan_id)
                .order_by(EscalationStepContact.step_id, EscalationStepContact.contact_id)
            )
        ).all()
        contacts: dict[uuid.UUID, list[uuid.UUID]] = {}
        for step_id, contact_id in rows:
            contacts.setdefault(step_id, []).append(contact_id)
        return [(s, contacts.get(s.id, [])) for s in steps]

    @staticmethod
    async def insert_incident(
        session: AsyncSession, incident: EscalationIncident
    ) -> EscalationIncident:
        session.add(incident)
        await session.flush()
        return incident

    @staticmethod
    async def insert_actions(session: AsyncSession, actions: list[IncidentAction]) -> None:
        session.add_all(actions)
        await session.flush()

    # ------------------------------------------------------------------ executing

    @staticmethod
    async def users_with_due_actions(
        session: AsyncSession,
        now: datetime,
        limit: int,
        *,
        exclude: Collection[uuid.UUID] = (),
    ) -> list[uuid.UUID]:
        stmt = (
            select(IncidentAction.user_id)
            .where(IncidentAction.status == "pending", IncidentAction.scheduled_for <= now)
            .group_by(IncidentAction.user_id)
            .order_by(func.min(IncidentAction.scheduled_for), IncidentAction.user_id)
            .limit(limit)
        )
        if exclude:
            stmt = stmt.where(IncidentAction.user_id.not_in(exclude))
        return [r[0] for r in (await session.execute(stmt)).all()]

    @staticmethod
    async def due_actions(
        session: AsyncSession, user_id: uuid.UUID, now: datetime
    ) -> list[IncidentAction]:
        stmt = (
            select(IncidentAction)
            .where(
                IncidentAction.user_id == user_id,
                IncidentAction.status == "pending",
                IncidentAction.scheduled_for <= now,
            )
            .order_by(IncidentAction.scheduled_for, IncidentAction.id)
        )
        return list((await session.execute(stmt)).scalars())

    @staticmethod
    async def lock_incidents(
        session: AsyncSession, incident_ids: list[uuid.UUID]
    ) -> dict[uuid.UUID, EscalationIncident]:
        """Lock order step 2: incidents, in ID order, after the user row."""
        if not incident_ids:
            return {}
        stmt = (
            select(EscalationIncident)
            .where(EscalationIncident.id.in_(incident_ids))
            .order_by(EscalationIncident.id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
        return {i.id: i for i in (await session.execute(stmt)).scalars()}

    @staticmethod
    async def lock_actions(
        session: AsyncSession, action_ids: list[uuid.UUID]
    ) -> list[IncidentAction]:
        """Lock order step 3: actions, oldest first. Only rows still ``pending`` come back."""
        if not action_ids:
            return []
        stmt = (
            select(IncidentAction)
            .where(IncidentAction.id.in_(action_ids), IncidentAction.status == "pending")
            .order_by(IncidentAction.scheduled_for, IncidentAction.id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
        return list((await session.execute(stmt)).scalars())

    @staticmethod
    async def late_stage_actions(
        session: AsyncSession, user_id: uuid.UUID, cutoff: datetime
    ) -> list[IncidentAction]:
        """Contact-facing stages of open incidents that were due before ``cutoff``."""
        stmt = (
            select(IncidentAction)
            .join(EscalationIncident, EscalationIncident.id == IncidentAction.incident_id)
            .where(
                IncidentAction.user_id == user_id,
                IncidentAction.kind == "execute_stage",
                IncidentAction.status == "pending",
                IncidentAction.scheduled_for < cutoff,
                EscalationIncident.status.in_(OPEN_STATUSES),
            )
            .order_by(IncidentAction.scheduled_for, IncidentAction.id)
        )
        return list((await session.execute(stmt)).scalars())

    @staticmethod
    async def pending_contact_actions(
        session: AsyncSession, incident_id: uuid.UUID
    ) -> list[IncidentAction]:
        """Lock order step 3, for the stages and final warnings still ahead of an incident."""
        stmt = (
            select(IncidentAction)
            .where(
                IncidentAction.incident_id == incident_id,
                IncidentAction.status == "pending",
                IncidentAction.kind.in_(("execute_stage", "user_final_warning")),
            )
            .order_by(IncidentAction.scheduled_for, IncidentAction.id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
        return list((await session.execute(stmt)).scalars())

    @staticmethod
    async def stage_action_time(
        session: AsyncSession, incident_id: uuid.UUID, step_id: uuid.UUID
    ) -> datetime | None:
        """When the stage will actually run (its action may have been shifted)."""
        stmt = select(IncidentAction.scheduled_for).where(
            IncidentAction.incident_id == incident_id,
            IncidentAction.kind == "execute_stage",
            IncidentAction.step_id == step_id,
        )
        return (await session.execute(stmt)).scalars().first()

    @staticmethod
    async def alerted_contacts(session: AsyncSession, incident_id: uuid.UUID) -> set[uuid.UUID]:
        """Contacts that already have a (not cancelled) escalation message in this incident: a
        later stage's release then goes out as a release notice, not a second alert."""
        stmt = select(Notification.contact_id).where(
            Notification.incident_id == incident_id,
            Notification.category == "contact_escalation",
            Notification.status != "cancelled",
            Notification.contact_id.is_not(None),
        )
        return {row[0] for row in (await session.execute(stmt)).all() if row[0] is not None}

    @staticmethod
    async def pending_stage_count(session: AsyncSession, incident_id: uuid.UUID) -> int:
        stmt = (
            select(func.count())
            .select_from(IncidentAction)
            .where(
                IncidentAction.incident_id == incident_id,
                IncidentAction.kind == "execute_stage",
                IncidentAction.status == "pending",
            )
        )
        return int((await session.execute(stmt)).scalar_one())

    @staticmethod
    async def final_warning_executed(
        session: AsyncSession, incident_id: uuid.UUID, step_id: uuid.UUID
    ) -> bool:
        stmt = select(
            exists().where(
                IncidentAction.incident_id == incident_id,
                IncidentAction.kind == "user_final_warning",
                IncidentAction.step_id == step_id,
                IncidentAction.status == "executed",
            )
        )
        return bool((await session.execute(stmt)).scalar_one())

    @staticmethod
    async def contacts(
        session: AsyncSession, user_id: uuid.UUID, contact_ids: list[uuid.UUID]
    ) -> dict[uuid.UUID, TrustedContact]:
        if not contact_ids:
            return {}
        stmt = select(TrustedContact).where(TrustedContact.id.in_(contact_ids))
        return {c.id: c for c in (await session.execute(stmt)).scalars()}

    @staticmethod
    async def is_suppressed(session: AsyncSession, hashes: list[bytes]) -> bool:
        if not hashes:
            return False
        stmt = select(exists().where(EmailSuppression.email_hash.in_(hashes)))
        return bool((await session.execute(stmt)).scalar_one())

    @staticmethod
    async def push_devices(session: AsyncSession, user_id: uuid.UUID) -> list[uuid.UUID]:
        stmt = (
            select(Device.id)
            .where(
                Device.user_id == user_id,
                Device.revoked_at.is_(None),
                Device.push_token.is_not(None),
            )
            .order_by(Device.id)
        )
        return [r[0] for r in (await session.execute(stmt)).all()]

    # ------------------------------------------------------------------ failures

    @staticmethod
    async def record_failed_attempt(
        session: AsyncSession,
        action_id: uuid.UUID,
        *,
        error_class: str,
        max_attempts: int,
        now: datetime,
    ) -> str:
        """Runs in its own transaction after the unit of work rolled back. Returns the action's
        new status: ``pending`` (retried next tick) or ``held`` after ``max_attempts``."""
        stmt = (
            update(IncidentAction)
            .where(IncidentAction.id == action_id, IncidentAction.status == "pending")
            .values(
                attempt_count=IncidentAction.attempt_count + 1,
                last_error_class=error_class,
                updated_at=now,
            )
            .returning(IncidentAction.attempt_count)
        )
        attempts = (await session.execute(stmt)).scalar_one_or_none()
        if attempts is None:
            return "gone"
        if attempts >= max_attempts:
            await session.execute(
                update(IncidentAction)
                .where(IncidentAction.id == action_id)
                .values(status="held", updated_at=now)
            )
            return "held"
        return "pending"

    # ------------------------------------------------------------------ pre-deadline reminders

    @staticmethod
    async def reminder_candidates(
        session: AsyncSession,
        now: datetime,
        limit: int,
        *,
        exclude: Collection[uuid.UUID] = (),
    ) -> list[tuple[uuid.UUID, datetime, int]]:
        lead = CheckinConfiguration.reminder_lead_minutes * text("interval '1 minute'")
        # A person is done for this deadline when its e-mail reminder exists (in any state, a
        # cancelled one too: the dedupe key would refuse a second) AND a push reminder exists
        # for every device that has a push token now. Without the first, every person inside a
        # window was read, locked and re-checked on every tick until the deadline, and a full
        # last page kept the worker from ever sleeping. Without the second, a phone whose
        # token arrived after the e-mail reminder (permission granted late, a reinstall, a new
        # phone) never got its push (review E-2). The device test is the same as
        # ``push_devices`` (not revoked, has a token), so a person that is a candidate always
        # gets at least one new row and is never rescanned forever. Cost: one index probe for
        # the e-mail, then the person's devices (ix_devices_user) and one probe per device.
        key_prefix = func.concat(
            "prereminder:",
            cast(CheckinConfiguration.user_id, Text),
            ":",
            cast(cast(func.extract("epoch", CheckinConfiguration.next_due_at), BigInteger), Text),
        )
        email_key = func.concat(key_prefix, ":email")
        push_key = func.concat(key_prefix, ":push:", cast(Device.id, Text))
        device_without_push = exists().where(
            Device.user_id == CheckinConfiguration.user_id,
            Device.revoked_at.is_(None),
            Device.push_token.is_not(None),
            # correlated to BOTH outer rows (the device and the person two levels up), never a
            # second scan of checkin_configurations
            ~exists()
            .where(Notification.dedupe_key == push_key)
            .correlate(CheckinConfiguration, Device),
        )
        # ``_pre_reminder`` queues nothing for an account that is not active (suspended, being
        # deleted): such a person would otherwise be a candidate on every tick of the window.
        active_account = exists().where(
            User.id == CheckinConfiguration.user_id, User.status == "active"
        )
        stmt = (
            select(
                CheckinConfiguration.user_id,
                CheckinConfiguration.next_due_at,
                CheckinConfiguration.reminder_lead_minutes,
            )
            .where(
                CheckinConfiguration.status == "active",
                CheckinConfiguration.reminder_lead_minutes > 0,
                CheckinConfiguration.next_due_at > now,
                CheckinConfiguration.next_due_at
                <= now + timedelta(minutes=MAX_REMINDER_LEAD_MINUTES),
                and_(CheckinConfiguration.next_due_at - lead <= now),
                active_account,
                or_(~exists().where(Notification.dedupe_key == email_key), device_without_push),
            )
            .order_by(CheckinConfiguration.next_due_at, CheckinConfiguration.user_id)
            .limit(limit)
        )
        if exclude:
            stmt = stmt.where(CheckinConfiguration.user_id.not_in(exclude))
        rows = (await session.execute(stmt)).all()
        return [(r[0], r[1], r[2]) for r in rows if r[1] is not None]

    # ------------------------------------------------------------------ Hold and liveness

    @staticmethod
    async def open_hold(session: AsyncSession) -> SystemHold | None:
        """The Hold that blocks contact-facing work, or ``None``.

        A Hold blocks until its **exit has been processed** (rollback and shift applied), not
        merely until ``ended_at`` is set: between the two a stage could otherwise run in the
        instant the Hold lifted, before the deadlines were shifted (§7.3)."""
        stmt = (
            select(SystemHold)
            .where(or_(SystemHold.ended_at.is_(None), SystemHold.exit_processed_at.is_(None)))
            .order_by(SystemHold.started_at)
            .limit(1)
        )
        return (await session.execute(stmt)).scalar_one_or_none()

    @staticmethod
    async def heartbeat(
        session: AsyncSession,
        *,
        service: str,
        instance_id: str,
        version: str,
        now: datetime,
    ) -> None:
        stmt = insert(ServiceHeartbeat).values(
            service=service,
            instance_id=instance_id,
            last_beat_at=now,
            started_at=now,
            version=version,
        )
        await session.execute(
            stmt.on_conflict_do_update(
                index_elements=[ServiceHeartbeat.service, ServiceHeartbeat.instance_id],
                set_={"last_beat_at": now, "version": version},
            )
        )

    @staticmethod
    async def open_incident_ids(session: AsyncSession, user_id: uuid.UUID) -> list[uuid.UUID]:
        stmt = select(EscalationIncident.id).where(
            EscalationIncident.user_id == user_id,
            EscalationIncident.status.in_(OPEN_STATUSES),
        )
        return [r[0] for r in (await session.execute(stmt)).all()]


def minutes(value: int) -> timedelta:
    return timedelta(minutes=value)
