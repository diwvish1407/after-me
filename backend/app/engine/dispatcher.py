"""The outbox dispatcher (ESCALATION_ENGINE §8).

Every message was written to ``notifications`` by the code that decided it. This loop sends
them, and **re-checks state first**: a message is only as valid as the situation it was queued
for. Contact-facing escalation messages are re-checked inside the per-user lock (§8.2), so a
check-in that committed first cancels them, and one that arrives later finds
``contacts_messaged_at`` set and is told to use I'M SAFE instead (INV-2).

    tx A (per-user lock, SKIP LOCKED): re-check, mark ``sending``, set ``contacts_messaged_at``
    provider call (outside any transaction, idempotency key = notification id)
    tx B: mark ``sent`` or schedule a retry; write the attempt to ``notification_logs``
"""

from __future__ import annotations

import secrets
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any, Final

from sqlalchemy import exists, func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.audit import writer as audit
from app.audit.writer import AuditEvent
from app.auth.models import Device
from app.checkins.models import CheckinConfiguration
from app.contacts.models import TrustedContact
from app.contacts.tokens import new_optout_token, optout_link, suppression_hash_candidates
from app.core.logging import get_logger
from app.engine.gate import ContactFacts, contact_problem
from app.engine.store import EngineStore
from app.incidents.models import OPEN_STATUSES, EscalationIncident, IncidentAction
from app.incidents.snapshot import SnapshotError, parse_snapshot
from app.notifications import outbox
from app.notifications.email import EmailMessage, ProviderResult
from app.notifications.mailer import EmailTemplate
from app.notifications.models import Notification, NotificationLog
from app.notifications.push import PushMessage, PushProvider
from app.notifications.render import (
    clock_time,
    date_text,
    day_time,
    duration_text,
    join_names,
    push_message,
)
from app.ops.models import SystemHold
from app.releases.models import PortalAccess, PortalToken, ReleaseEvent
from app.security.hashing import sha256
from app.users.models import UserProfile

_log = get_logger("afterme.dispatch")

BATCH: Final = 100
STUCK_AFTER: Final = timedelta(minutes=5)
GIVE_UP_AFTER: Final = timedelta(hours=24)
BACKOFF_MINUTES: Final = (1, 2, 4, 8, 16, 32, 60)  # then hourly (§8.3)
# What the engine itself writes in the escalation category. Anything else found there did not
# come from the engine and is never sent (Phase 6 adds the release message here).
ESCALATION_TEMPLATES: Final = frozenset(
    {outbox.CONTACT_ALERT, outbox.CONTACT_ALERT_WITH_RELEASE, outbox.CONTACT_RELEASE}
)
LINK_LIFETIME: Final = timedelta(days=30)
LINK_PREFIX: Final = "rt_"
# A reminder for an incident is only true while it is open.
INCIDENT_BOUND_USER_TEMPLATES: Final = frozenset(
    {
        outbox.USER_MISSED,
        outbox.USER_MIDPOINT,
        outbox.USER_LAST_CHANCE,
        outbox.USER_STAGE_DEFERRED,
        outbox.USER_FINAL_WARNING,
    }
)


def retry_delay(attempts_so_far: int) -> timedelta:
    index = min(attempts_so_far - 1, len(BACKOFF_MINUTES) - 1)
    return timedelta(minutes=BACKOFF_MINUTES[max(index, 0)])


@dataclass
class DispatchReport:
    sent: int = 0
    retried: int = 0
    failed: int = 0
    cancelled: int = 0
    left_queued: int = 0
    recovered: int = 0
    errors: int = 0
    reasons: dict[str, int] = field(default_factory=dict)

    def why(self, reason: str) -> None:
        self.reasons[reason] = self.reasons.get(reason, 0) + 1


@dataclass(frozen=True)
class _Outgoing:
    notification_id: uuid.UUID
    channel: str
    email: EmailMessage | None
    push: PushMessage | None
    contact_facing: bool
    user_id: uuid.UUID
    incident_id: uuid.UUID | None
    template_key: str


class Dispatcher:
    def __init__(self, services: AppServices, *, push: PushProvider) -> None:
        self.services = services
        self.settings = services.settings
        self.db = services.db
        self.clock = services.clock
        self.push = push
        self.email = services.mailer.provider

    # ------------------------------------------------------------------ the loop

    async def dispatch(self, *, contact_facing: bool = True) -> DispatchReport:
        """One pass. ``contact_facing=False`` (the engine could not tell whether a Hold is in
        force) leaves every escalation message queued; user messages and all-clears go on."""
        report = DispatchReport()
        async with self.db.sessionmaker() as session, session.begin():
            now = await self.clock.now(session)
            report.recovered = await self._recover_stuck(session, now)
            # During a Hold the escalation rows are not even picked up: they would fill every
            # batch (oldest first) and starve the user messages and all-clears behind them.
            escalation = contact_facing and await EngineStore.open_hold(session) is None
            candidates = await self._candidates(session, now, escalation=escalation)
        for notification_id in candidates:
            try:
                await self._deliver(notification_id, report)
            except Exception as exc:  # one message must never stop the others
                report.errors += 1
                _log.error("dispatch.unit_failed", error_class=type(exc).__name__)
        return report

    async def _recover_stuck(self, session: AsyncSession, now: datetime) -> int:
        """A worker that died between tx A and tx B left a row in ``sending``. It is put back
        in the queue: delivery is at-least-once at the provider boundary (§7.4, FS-07), and the
        provider's idempotency key (the notification id) suppresses the duplicate where it can."""
        result = await session.execute(
            update(Notification)
            .where(Notification.status == "sending", Notification.updated_at < now - STUCK_AFTER)
            .values(status="queued", next_attempt_at=now, updated_at=now)
            .returning(Notification.id)
        )
        return len(result.all())

    async def _candidates(
        self, session: AsyncSession, now: datetime, *, escalation: bool = True
    ) -> list[uuid.UUID]:
        stmt = (
            select(Notification.id)
            .where(
                Notification.status == "queued",
                Notification.send_after <= now,
                or_(Notification.next_attempt_at.is_(None), Notification.next_attempt_at <= now),
            )
            .order_by(Notification.send_after, Notification.id)
            .limit(BATCH)
        )
        if not escalation:
            # The summary "Mom has been notified" is only true together with the alert it
            # reports, so it waits with it.
            stmt = stmt.where(
                Notification.category != outbox.CATEGORY_ESCALATION,
                Notification.template_key != outbox.USER_STAGE_EXECUTED,
            )
        return [r[0] for r in (await session.execute(stmt)).all()]

    # ------------------------------------------------------------------ one message

    async def _deliver(self, notification_id: uuid.UUID, report: DispatchReport) -> None:
        outgoing = await self._claim(notification_id, report)  # tx A
        if outgoing is None:
            return
        started = time.monotonic()
        result: ProviderResult | None = None
        error_class: str | None = None
        try:  # outside any transaction
            if outgoing.email is not None:
                result = await self.email.send(
                    outgoing.email, idempotency_key=str(outgoing.notification_id)
                )
            elif outgoing.push is not None:
                result = await self.push.send(
                    outgoing.push, idempotency_key=str(outgoing.notification_id)
                )
        except Exception as exc:
            error_class = type(exc).__name__
        latency_ms = int((time.monotonic() - started) * 1000)
        await self._settle(outgoing, result, error_class, latency_ms, report)  # tx B

    async def _claim(self, notification_id: uuid.UUID, report: DispatchReport) -> _Outgoing | None:
        async with self.db.sessionmaker() as session, session.begin():
            now = await self.clock.now(session)
            row = (
                await session.execute(
                    select(Notification)
                    .where(Notification.id == notification_id)
                    .with_for_update(skip_locked=True)
                    .execution_options(populate_existing=True)
                )
            ).scalar_one_or_none()
            if (
                row is None
                or row.status != "queued"
                or row.send_after > now
                or (row.next_attempt_at is not None and row.next_attempt_at > now)
            ):
                return None

            if row.category == outbox.CATEGORY_ESCALATION:
                verdict = await self._recheck_escalation(session, row, now)
            elif row.category == outbox.CATEGORY_USER:
                verdict = await self._recheck_user(session, row, now)
            else:
                verdict = await self._recheck_contact_other(session, row)

            if verdict == "wait":  # Hold, the lock is busy, or a Hold window is unprocessed
                report.left_queued += 1
                return None
            if verdict is not None:
                self._cancel(row, verdict, now)
                report.cancelled += 1
                report.why(verdict)
                return None

            outgoing = await self._build(session, row, now)
            if outgoing is None:
                self._cancel(row, "no_recipient", now)
                report.cancelled += 1
                report.why("no_recipient")
                return None
            if row.category == outbox.CATEGORY_ESCALATION:
                # Marked "messaged" only now that a message exists, inside the lock: from here
                # on a check-in must use I'M SAFE. (A row that could not be built above must
                # not leave the incident claiming that contacts were told.)
                await self._mark_messaged(session, row, now)
            row.status = "sending"
            row.updated_at = now
            return outgoing

    @staticmethod
    async def _mark_messaged(session: AsyncSession, row: Notification, now: datetime) -> None:
        incident = await _incident(session, row.incident_id) if row.incident_id else None
        if incident is not None and incident.contacts_messaged_at is None:
            incident.contacts_messaged_at = now
            incident.updated_at = now

    # ------------------------------------------------------------------ re-checks

    @staticmethod
    def _cancel(row: Notification, reason: str, now: datetime) -> None:
        row.status = "cancelled"
        row.cancelled_reason = reason
        row.updated_at = now

    async def _recheck_user(
        self, session: AsyncSession, row: Notification, now: datetime
    ) -> str | None:
        user = await EngineStore.user(session, row.user_id)
        if user is None or user.status != "active":
            return "account_inactive"
        if row.template_key == outbox.USER_PRE_REMINDER:
            config = await _config(session, row.user_id)
            due = row.params.get("due_at")
            if (
                config is None
                or config.status != "active"
                or (config.next_due_at is None or config.next_due_at.isoformat() != due)
            ):
                return "superseded"
        if row.template_key == outbox.USER_STAGE_EXECUTED and (
            await EngineStore.open_hold(session) is not None
        ):
            return "wait"  # the stage it reports may still be rolled back when the Hold ends
        if row.template_key == outbox.USER_STAGE_EXECUTED and row.incident_id is not None:
            incident = await _incident(session, row.incident_id)
            if (
                incident is not None
                and incident.status not in OPEN_STATUSES
                and incident.contacts_messaged_at is None
            ):
                # I'M OK, I'M SAFE or an operator closed it inside the settle delay: nobody was
                # told after all, and "Mom has been notified" would be false.
                return "incident_closed_before_contact"
        if row.template_key in INCIDENT_BOUND_USER_TEMPLATES and row.incident_id is not None:
            incident = await _incident(session, row.incident_id)
            if incident is None or incident.status not in OPEN_STATUSES:
                return "incident_closed"
        return None

    async def _recheck_contact_other(self, session: AsyncSession, row: Notification) -> str | None:
        """All-clears and similar: no Hold, no settle delay, no open incident required. They are
        still not sent to someone who has since asked not to be contacted."""
        is_link = row.template_key in outbox.RELEASE_TEMPLATES
        if is_link and await EngineStore.open_hold(session) is not None:
            return "wait"  # content-bearing links wait out a Hold like every escalation message
        problem = await self._contact_problem(session, row, require_verified=is_link)
        if problem is None and is_link:
            user = await EngineStore.user(session, row.user_id)
            if user is None or user.status != "active":
                return "account_inactive"
            problem = await self._release_problem(session, row, await self.clock.now(session))
        return problem

    async def _recheck_escalation(  # noqa: PLR0911 - an ordered list of re-checks
        self, session: AsyncSession, row: Notification, now: datetime
    ) -> str | None:
        """§8.2 tx A. Returns ``None`` (send), ``"wait"`` (leave queued) or a cancel reason."""
        if row.incident_id is None or row.action_id is None:  # the CHECK forbids it; be safe
            return "malformed"
        config = await EngineStore.lock_user(session, row.user_id)  # SKIP LOCKED
        if config is None:
            return "wait"
        if await EngineStore.open_hold(session) is not None:
            return "wait"  # INV-10: nothing contact-facing leaves during Hold
        incident = (
            await session.execute(
                select(EscalationIncident)
                .where(EscalationIncident.id == row.incident_id)
                .with_for_update()
                .execution_options(populate_existing=True)
            )
        ).scalar_one_or_none()
        if (
            incident is None
            or incident.status not in OPEN_STATUSES
            or incident.user_id != row.user_id
        ):
            return "incident_closed"  # INV-2: a committed check-in cancels it here
        action = (
            await session.execute(select(IncidentAction).where(IncidentAction.id == row.action_id))
        ).scalar_one_or_none()
        if (
            action is None
            or action.kind != "execute_stage"
            or action.status != "executed"
            or action.incident_id != incident.id
        ):
            return "action_not_executed"
        derived = self._derive(row, incident, action, now)
        if derived is not None:
            return derived
        if await EngineStore.checkin_after(session, row.user_id, incident.missed_due_at):
            return "checkin_after_missed_due"  # G3, as the engine would have held it
        if action.executed_at is not None and await _hold_window_unprocessed(
            session, action.executed_at
        ):
            return "wait"  # created inside a Hold window that has not been rolled back yet
        user = await EngineStore.user(session, row.user_id)
        if user is None or user.status != "active":
            return "account_inactive"
        problem = await self._contact_problem(session, row, require_verified=True)
        if problem is not None:
            return problem
        gone = await self._release_problem(session, row, now)
        if (
            gone is not None
            and row.template_key == outbox.CONTACT_ALERT_WITH_RELEASE
            and self._notified_by_stage(incident, action, row)
        ):
            # The person asked for this contact to be alerted, and still does: only the release
            # is gone (switched off, withdrawn). They get the alert without a link, not silence.
            row.template_key = outbox.CONTACT_ALERT
            row.params = {
                k: v for k, v in row.params.items() if k not in ("release_count", "after_minutes")
            }
            return None
        return gone

    @staticmethod
    def _notified_by_stage(
        incident: EscalationIncident, action: IncidentAction, row: Notification
    ) -> bool:
        if action.step_id is None:
            return False
        try:
            stage = parse_snapshot(incident.plan_snapshot).stage(action.step_id)
        except SnapshotError:
            return False
        return stage is not None and row.contact_id in stage.notify_contact_ids

    def _derive(
        self,
        row: Notification,
        incident: EscalationIncident,
        action: IncidentAction,
        now: datetime,
    ) -> str | None:
        """The row is not trusted: that this contact is to be told, by this stage, after the
        settle delay, is derived again from the incident's own snapshot and action. A row that
        the engine did not write (the API role may insert notifications) fails here."""
        if row.template_key not in ESCALATION_TEMPLATES:
            return "unexpected_template"
        if not row.dedupe_key.startswith(f"notif:{action.id}:"):
            return "dedupe_key_mismatch"
        try:
            snapshot = parse_snapshot(incident.plan_snapshot)
        except SnapshotError:
            return "snapshot_unrecognised"
        stage = snapshot.stage(action.step_id) if action.step_id else None
        if stage is None:
            return "stage_not_in_snapshot"
        allowed = {*stage.notify_contact_ids, *(r.contact_id for r in stage.releases)}
        if row.contact_id not in allowed:
            return "contact_not_in_stage"
        settle = timedelta(seconds=self.settings.settle_delay_seconds)
        if action.executed_at is None or now < action.executed_at + settle:
            return "wait"
        return None

    async def _release_problem(
        self, session: AsyncSession, row: Notification, now: datetime
    ) -> str | None:
        """A message that carries a link must still have something behind it: portal access that
        is not revoked and at least one release that is not revoked."""
        if row.template_key not in outbox.RELEASE_TEMPLATES:
            return None
        access = await self._access_for(session, row)
        if access is None or access.revoked_at is not None:
            return "release_revoked"
        incident = await _incident(session, access.incident_id)
        if incident is None or incident.status not in OPEN_STATUSES:
            return "release_revoked"
        open_release = (
            await session.execute(
                select(ReleaseEvent.id)
                .where(
                    ReleaseEvent.incident_id == access.incident_id,
                    ReleaseEvent.contact_id == access.contact_id,
                    ReleaseEvent.revoked_at.is_(None),
                )
                .limit(1)
            )
        ).first()
        return None if open_release is not None else "release_revoked"

    @staticmethod
    async def _access_for(session: AsyncSession, row: Notification) -> PortalAccess | None:
        """The portal access a message is about: by incident and contact for an escalation
        message, by ``access_id`` for a fresh-link request."""
        access_id = row.params.get("access_id")
        stmt = select(PortalAccess)
        if access_id is not None:
            try:
                wanted = uuid.UUID(str(access_id))
            except ValueError:
                return None
            # The row's own owner and contact must be the access's: a row (the API role may
            # insert them) can never make the worker mint a link for someone else's access.
            stmt = stmt.where(
                PortalAccess.id == wanted,
                PortalAccess.user_id == row.user_id,
                PortalAccess.contact_id == row.contact_id,
            )
        elif row.incident_id is not None and row.contact_id is not None:
            stmt = stmt.where(
                PortalAccess.incident_id == row.incident_id,
                PortalAccess.contact_id == row.contact_id,
            )
        else:
            return None
        return (await session.execute(stmt)).scalar_one_or_none()

    async def _contact_problem(
        self, session: AsyncSession, row: Notification, *, require_verified: bool
    ) -> str | None:
        if row.contact_id is None:
            return "no_recipient"
        contact = (
            await session.execute(select(TrustedContact).where(TrustedContact.id == row.contact_id))
        ).scalar_one_or_none()
        if contact is None:
            return "contact_not_found"
        suppressed = False
        if contact.email_normalized:
            suppressed = await EngineStore.is_suppressed(
                session, suppression_hash_candidates(self.services.pepper, contact.email_normalized)
            )
        status = contact.verification_status
        if not require_verified and status in ("verified", "pending", "declined", "bounced"):
            status = "verified"  # all-clears also go to contacts that have not answered
        problem = contact_problem(
            ContactFacts(
                exists=True,
                belongs_to_user=contact.user_id == row.user_id,
                deleted=contact.deleted_at is not None,
                is_active=contact.is_active or not require_verified,
                verification_status=status,
                suppressed=suppressed,
            )
        )
        return None if problem is None else f"contact_{problem}"

    # ------------------------------------------------------------------ building the message

    @staticmethod
    def _outgoing(
        row: Notification, *, email: EmailMessage | None = None, push: PushMessage | None = None
    ) -> _Outgoing:
        return _Outgoing(
            notification_id=row.id,
            channel=row.channel,
            email=email,
            push=push,
            contact_facing=row.audience == "contact",
            user_id=row.user_id,
            incident_id=row.incident_id,
            template_key=row.template_key,
        )

    async def _build(
        self, session: AsyncSession, row: Notification, now: datetime
    ) -> _Outgoing | None:
        user = await EngineStore.user(session, row.user_id)
        if user is None:
            return None
        profile = await _profile(session, row.user_id)
        user_name = profile.display_name if profile else "there"
        timezone = profile.timezone if profile else "UTC"

        if row.channel == "push":
            token = await _push_token(session, row.device_id)
            if token is None:
                return None
            incident_id = str(row.incident_id) if row.incident_id else None
            pushed = push_message(row.template_key, token=token, incident_id=incident_id)
            return self._outgoing(row, push=pushed) if pushed is not None else None

        if row.audience == "user":
            user_context = await self._user_context(session, row, user_name, timezone)
            rendered = self.services.mailer.render(
                EmailTemplate(row.template_key), to=user.email, **user_context
            )
            return self._outgoing(row, email=rendered)

        contact = (
            await session.execute(select(TrustedContact).where(TrustedContact.id == row.contact_id))
        ).scalar_one_or_none()
        if contact is None or not contact.email or not contact.email_normalized:
            return None
        link = optout_link(
            self.settings.public_base_url,
            new_optout_token(self.services.pepper, contact.id, contact.email_normalized),
        )
        contact_context: dict[str, Any] = {
            "contact_name": contact.display_name,
            "user_name": user_name,
            "user_email": user.email,
            "optout_link": link,
        }
        if row.template_key in (outbox.CONTACT_ALERT, outbox.CONTACT_ALERT_WITH_RELEASE):
            missed = datetime.fromisoformat(row.params["missed_due_at"])
            last = row.params.get("last_checkin_at")
            contact_context["due_at"] = day_time(missed, timezone)
            contact_context["last_checkin"] = (
                day_time(datetime.fromisoformat(last), timezone) if last else ""
            )
        elif row.template_key != outbox.CONTACT_RELEASE:
            at = row.params.get("checked_in_at")
            contact_context["checked_in_at"] = (
                day_time(datetime.fromisoformat(at), timezone) if at else "just now"
            )
        if row.template_key in outbox.RELEASE_TEMPLATES:
            release_link = await self._mint_link(session, row, now)
            if release_link is None:
                return None
            contact_context["release_link"] = release_link
            contact_context["expires_on"] = date_text(now + LINK_LIFETIME, timezone)
            contact_context["after_text"] = duration_text(
                int(row.params.get("after_minutes", 1440))
            )
        rendered = self.services.mailer.render(
            EmailTemplate(row.template_key), to=contact.email, **contact_context
        )
        return self._outgoing(row, email=rendered)

    async def _mint_link(
        self, session: AsyncSession, row: Notification, now: datetime
    ) -> str | None:
        """A fresh link token for the portal access this message is about. Only its SHA-256 is
        stored, so the raw token exists only in the email being sent (SECURITY §6.3). A retry
        of the same message mints another; every token of an access is revoked together."""
        access = await self._access_for(session, row)
        if access is None or access.revoked_at is not None:
            return None
        raw = secrets.token_urlsafe(32)
        session.add(
            PortalToken(
                access_id=access.id,
                token_hash=sha256(raw),
                notification_id=row.id,
                expires_at=now + LINK_LIFETIME,
            )
        )
        await session.flush()
        return f"{self.settings.public_base_url}/c/release#{LINK_PREFIX}{raw}"

    async def _user_context(
        self, session: AsyncSession, row: Notification, user_name: str, timezone: str
    ) -> dict[str, Any]:
        params = row.params
        context: dict[str, Any] = {"user_name": user_name}
        key = row.template_key
        if key == outbox.USER_PRE_REMINDER:
            context["due_at"] = clock_time(datetime.fromisoformat(params["due_at"]), timezone)
        elif key in (
            outbox.USER_MISSED,
            outbox.USER_MIDPOINT,
            outbox.USER_LAST_CHANCE,
            outbox.USER_STAGE_DEFERRED,
        ):
            ids = [uuid.UUID(c) for c in params.get("first_stage_contact_ids", [])]
            names = await _names(session, row.user_id, ids)
            context["who"] = join_names(names) or "Your contacts"
            if params.get("first_stage_at"):
                context["first_stage_at"] = clock_time(
                    datetime.fromisoformat(params["first_stage_at"]), timezone
                )
            else:
                context["first_stage_at"] = "the end of the grace period"
            if key == outbox.USER_MISSED:
                context["due_time"] = clock_time(
                    datetime.fromisoformat(params["missed_due_at"]), timezone
                )
        elif key == outbox.USER_STAGE_EXECUTED:
            ids = [uuid.UUID(c) for c in params.get("notified_contact_ids", [])]
            names = await _names(session, row.user_id, ids)
            if names:
                verb = "has" if len(names) == 1 else "have"
                context["notified_phrase"] = f"{join_names(names)} {verb} been notified"
            else:
                context["notified_phrase"] = "Nobody could be notified"
            shared = int(params.get("release_count", 0))
            if shared:
                noun = "instruction was" if shared == 1 else "instructions were"
                context["notified_phrase"] += f". {shared} {noun} shared with them"
        elif key == outbox.USER_FINAL_WARNING:
            ids = [uuid.UUID(c) for c in params.get("contact_ids", [])]
            context["names"] = (
                join_names(await _names(session, row.user_id, ids)) or "your contacts"
            )
            context["release_count"] = params.get("release_count", 0)
        elif key == outbox.USER_ALL_CLEAR:
            ids = [uuid.UUID(c) for c in params.get("contact_ids", [])]
            names = await _names(session, row.user_id, ids)
            context["names"] = join_names(names) or "Your contacts"
            context["count"] = max(len(names), 1)
            due = params.get("next_due_at")
            context["next_due_at"] = (
                clock_time(datetime.fromisoformat(due), timezone) if due else "soon"
            )
        return context

    # ------------------------------------------------------------------ tx B

    async def _settle(
        self,
        out: _Outgoing,
        result: ProviderResult | None,
        error_class: str | None,
        latency_ms: int,
        report: DispatchReport,
    ) -> None:
        async with self.db.sessionmaker() as session, session.begin():
            now = await self.clock.now(session)
            row = (
                await session.execute(
                    select(Notification)
                    .where(Notification.id == out.notification_id)
                    .with_for_update()
                    .execution_options(populate_existing=True)
                )
            ).scalar_one()
            row.attempt_count += 1
            row.updated_at = now
            provider = (
                result.provider
                if result
                else (self.email.name if out.email is not None else self.push.name)
            )
            session.add(
                NotificationLog(
                    notification_id=row.id,
                    attempted_at=now,
                    provider=provider,
                    outcome="accepted" if result else "error",
                    provider_message_id=result.message_id if result else None,
                    error_code=error_class,
                    latency_ms=min(latency_ms, 32_000),
                )
            )
            if result is not None:
                row.status = "sent"
                row.sent_at = now
                row.provider = provider
                row.provider_message_id = result.message_id
                report.sent += 1
                if out.contact_facing:
                    await self._audit(session, audit.NOTIFICATION_SENT, out, now, {})
                return
            # Counted from the first attempt, not from creation: a message that waited out a
            # Hold must not fail for good on its very first transient error.
            first_attempt = (
                await session.execute(
                    select(func.min(NotificationLog.attempted_at)).where(
                        NotificationLog.notification_id == row.id
                    )
                )
            ).scalar_one_or_none() or now
            if now - first_attempt > GIVE_UP_AFTER:
                row.status = "failed"
                report.failed += 1
                _log.error(
                    "dispatch.failed",
                    notification_id=str(row.id),
                    category=row.category,
                    template=row.template_key,
                    error_class=error_class,
                )
                if out.contact_facing:
                    await self._audit(
                        session,
                        audit.NOTIFICATION_FAILED,
                        out,
                        now,
                        {"error_class": error_class or ""},
                    )
                return
            row.status = "queued"
            row.next_attempt_at = now + retry_delay(row.attempt_count)
            report.retried += 1

    async def _audit(
        self,
        session: AsyncSession,
        action: str,
        out: _Outgoing,
        now: datetime,
        metadata: dict[str, Any],
    ) -> None:
        await self.services.audit.record(
            session,
            AuditEvent(
                action=action,
                occurred_at=now,
                subject_user_id=out.user_id,
                actor_type="system",
                resource_type="notification",
                resource_id=out.notification_id,
                metadata={"template": out.template_key, **metadata},
            ),
        )


# --- small queries ----------------------------------------------------------------------------


async def _config(session: AsyncSession, user_id: uuid.UUID) -> Any:
    return (
        await session.execute(
            select(CheckinConfiguration).where(CheckinConfiguration.user_id == user_id)
        )
    ).scalar_one_or_none()


async def _incident(session: AsyncSession, incident_id: uuid.UUID) -> EscalationIncident | None:
    return (
        await session.execute(
            select(EscalationIncident).where(EscalationIncident.id == incident_id)
        )
    ).scalar_one_or_none()


async def _profile(session: AsyncSession, user_id: uuid.UUID) -> Any:
    return (
        await session.execute(select(UserProfile).where(UserProfile.user_id == user_id))
    ).scalar_one_or_none()


async def _push_token(session: AsyncSession, device_id: uuid.UUID | None) -> str | None:
    if device_id is None:
        return None
    return (
        await session.execute(
            select(Device.push_token).where(Device.id == device_id, Device.revoked_at.is_(None))
        )
    ).scalar_one_or_none()


async def _names(session: AsyncSession, user_id: uuid.UUID, ids: list[uuid.UUID]) -> list[str]:
    if not ids:
        return []
    rows = (
        await session.execute(
            select(TrustedContact.id, TrustedContact.display_name).where(
                TrustedContact.user_id == user_id, TrustedContact.id.in_(ids)
            )
        )
    ).all()
    by_id = {r[0]: r[1] for r in rows}
    return [by_id[i] for i in ids if i in by_id]


async def _hold_window_unprocessed(session: AsyncSession, instant: datetime) -> bool:
    stmt = select(
        exists().where(
            SystemHold.started_at <= instant,
            or_(SystemHold.ended_at.is_(None), SystemHold.ended_at >= instant),
            SystemHold.exit_processed_at.is_(None),
        )
    )
    return bool((await session.execute(stmt)).scalar_one())
