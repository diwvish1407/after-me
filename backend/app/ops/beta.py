"""The closed-beta review report (TEST_PLAN §12: "zero wrongful contact messages during beta,
every escalated incident reviewed").

Run through ``python -m cli.admin beta-report``. It answers two questions without anyone opening
the database by hand: how is the beta going (counts for a period), and, for every incident in
which a contact was messaged, what exactly happened and does a person need to look at it.

* **Read-only.** One ``REPEATABLE READ, READ ONLY`` transaction as the worker role: the numbers
  agree with each other, and the database itself refuses a write. Like ``status``, a report is
  not audited (only commands that change something are).
* **Privacy.** Only UUIDs, counts, template keys, statuses, reason codes and times. No names, no
  addresses, no tokens, no instruction titles or bodies: those columns are never selected, and
  every code that does come out of a text column is passed through :func:`_label`. Contacts are
  ``contact-1``, ``contact-2`` in the order they were first messaged in that incident.
* **The tool never decides.** The verdict *hints* are deterministic rules over recorded facts. An
  incident that trips a wrongful-alert-candidate rule is marked ``NEEDS HUMAN REVIEW``; whether
  an alert was wrongful is the operator's call.

Everything is split into query functions that return plain dicts, and a formatter that only
reads that document, so the JSON and the text can never disagree.
"""

from __future__ import annotations

import re
import uuid
from collections import defaultdict
from collections.abc import AsyncIterator, Callable, Iterable, Mapping, Sequence
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from typing import Any, Final

from alembic.script import ScriptDirectory
from sqlalchemy import ColumnElement, and_, distinct, exists, func, or_, select, text, true
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import InstrumentedAttribute

from app.api.container import AppServices
from app.audit import writer as audit
from app.audit.models import AuditLog
from app.auth.models import User
from app.checkins.models import (
    CHECKIN_EVENT_KINDS,
    CHECKIN_SOURCES,
    CheckinConfiguration,
    CheckinEvent,
)
from app.contacts.models import TrustedContact
from app.core.config import BACKEND_DIR
from app.incidents.models import (
    CLOSED_BY,
    INCIDENT_STATUSES,
    OPEN_STATUSES,
    EscalationIncident,
    IncidentAction,
)
from app.incidents.snapshot import SnapshotError, parse_snapshot
from app.maintenance.retention import RULES as RETENTION_RULES
from app.models import ALL_TABLES
from app.notifications import outbox
from app.notifications.models import (
    LOG_OUTCOMES,
    NOTIFICATION_STATUSES,
    Notification,
    NotificationLog,
)
from app.ops.models import HOLD_REASONS, SystemHold
from app.releases.models import REVOKE_REASONS, ReleaseEvent

SCHEMA_VERSION: Final = 1
HOLD_EXIT_WINDOW: Final = timedelta(hours=24)  # "opened_within_24h_of_hold_exit"
LATE_RESOLUTION: Final = timedelta(hours=24)  # "late_resolution_over_24h"
_SECONDS_PER_MINUTE: Final = 60

_SHOWN_TABLES: Final = 8
_LABEL_RE: Final = re.compile(r"[A-Za-z0-9_.:-]{1,64}")


# --- the verdict rules ------------------------------------------------------------------------


@dataclass(frozen=True)
class Rule:
    """One deterministic hint. ``needs_review`` marks a wrongful-alert candidate: the incident
    is then ``NEEDS HUMAN REVIEW``. Rules that are not candidates still show, as context."""

    name: str
    needs_review: bool
    meaning: str


RULES: Final[tuple[Rule, ...]] = (
    Rule(
        "closed_by_checkin_after_contacts_messaged",
        True,
        "the person checked in (I'M OK or I'M SAFE) after contacts were messaged: they were "
        "fine, so the alert may have been unnecessary",
    ),
    Rule(
        "voided_by_operator_after_contacts_messaged",
        True,
        "an operator voided the incident after contacts were messaged (a confirmed fault)",
    ),
    Rule(
        "closed_by_account_deletion_after_contacts_messaged",
        True,
        "the account was deleted after contacts were messaged: someone was signed in and active",
    ),
    Rule(
        "opened_within_24h_of_hold_exit",
        True,
        "the incident opened while a Hold was active (its window is backdated) or within 24 "
        "hours after one ended: check-ins may have been lost during the outage",
    ),
    Rule(
        "hold_overlapped_incident",
        True,
        "a Hold was active between the missed deadline and the first contact message: check-ins "
        "may have been lost, and the timeline was shifted",
    ),
    Rule(
        "complaint_received",
        True,
        "a contact reported one of the messages as unwanted (spam complaint)",
    ),
    Rule(
        "released_and_viewed",
        False,
        "a release was created and a contact opened it: information was shown, and cannot be "
        "taken back",
    ),
    Rule(
        "stage_delayed",
        False,
        "a stage was pushed back (Hold shift or late-worker deferral) or the person was told "
        "it was delayed",
    ),
    Rule(
        "delivery_failed_to_a_contact",
        False,
        "a message to a contact failed, bounced or was refused",
    ),
    Rule(
        "provider_fallback_used",
        False,
        "a contact message went through the fallback email provider",
    ),
    Rule(
        "contact_skipped",
        False,
        "a stage skipped a contact (not verified, opted out, suppressed ...): see the reasons "
        "in the audit trail",
    ),
    Rule(
        "action_held",
        False,
        "a timeline action was held by a safety gate and never ran automatically",
    ),
    Rule(
        "late_resolution_over_24h",
        False,
        "more than 24 hours passed between the first contact message and the resolution",
    ),
    Rule(
        "still_open_over_24h",
        False,
        "the incident is still open more than 24 hours after contacts were first messaged",
    ),
)
_RULE_ORDER: Final = {rule.name: i for i, rule in enumerate(RULES)}
_REVIEW_RULES: Final = frozenset(rule.name for rule in RULES if rule.needs_review)

_CLOSER_TEXT: Final = {
    "user_checkin": "the person checked in (I'M OK)",
    "user_safe": "the person pressed I'M SAFE",
    "operator_void": "an operator voided it",
    "account_deleted": "the account was deleted",
}


# --- the period -------------------------------------------------------------------------------


@dataclass(frozen=True)
class Period:
    """UTC calendar days, both ends inclusive; ``None`` leaves that side open."""

    since: date | None = None
    until: date | None = None

    @property
    def start(self) -> datetime | None:
        return None if self.since is None else datetime.combine(self.since, time.min, tzinfo=UTC)

    @property
    def end(self) -> datetime | None:
        """Exclusive: midnight at the end of ``until``."""
        if self.until is None:
            return None
        try:
            return datetime.combine(self.until + timedelta(days=1), time.min, tzinfo=UTC)
        except OverflowError:  # until = 9999-12-31
            return None

    def as_dict(self) -> dict[str, Any]:
        return {
            "since": self.since.isoformat() if self.since else None,
            "until": self.until.isoformat() if self.until else None,
            "from": _iso(self.start),
            "to_exclusive": _iso(self.end),
            "timezone": "UTC",
        }


def _within(column: InstrumentedAttribute[Any], period: Period) -> list[ColumnElement[bool]]:
    clauses: list[ColumnElement[bool]] = []
    if period.start is not None:
        clauses.append(column >= period.start)
    if period.end is not None:
        clauses.append(column < period.end)
    return clauses


# --- small helpers ----------------------------------------------------------------------------


def _iso(value: datetime | None) -> str | None:
    return None if value is None else value.astimezone(UTC).isoformat()


def _label(value: str | None) -> str:
    """A reason code, template key or provider name as stored. These columns only ever hold
    codes, but a report promised to carry no free text does not take that on trust: anything
    that is not a short code is reported as ``other``."""
    if value is not None and _LABEL_RE.fullmatch(value):
        return value
    return "other"


def _minutes(then: datetime, origin: datetime) -> float:
    return round((then - origin).total_seconds() / _SECONDS_PER_MINUTE, 1)


def _zero(keys: Iterable[str]) -> dict[str, int]:
    return dict.fromkeys(keys, 0)


async def _count(session: AsyncSession, statement: Any) -> int:
    return int((await session.execute(statement)).scalar_one())


@asynccontextmanager
async def read_only_session(services: AppServices) -> AsyncIterator[AsyncSession]:
    """One snapshot, and a transaction the database will not let write."""
    async with services.db.sessionmaker() as session, session.begin():
        # Before any other statement: the isolation level and access mode of this transaction.
        await session.execute(text("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY"))
        yield session


# --- the metrics ------------------------------------------------------------------------------


async def _users(session: AsyncSession, period: Period) -> dict[str, int]:
    created = await _count(
        session,
        select(func.count()).select_from(User).where(*_within(User.created_at, period)),
    )
    active = await _count(
        session,
        select(func.count(distinct(CheckinEvent.user_id)))
        .select_from(CheckinEvent)
        .where(*_within(CheckinEvent.received_at, period)),
    )
    scheduled = await _count(
        session,
        select(func.count())
        .select_from(CheckinConfiguration)
        .where(CheckinConfiguration.status != "inactive"),
    )
    return {"created": created, "active": active, "with_active_schedule_now": scheduled}


async def _checkins(session: AsyncSession, period: Period) -> dict[str, Any]:
    rows = (
        await session.execute(
            select(CheckinEvent.source, CheckinEvent.kind, func.count())
            .where(*_within(CheckinEvent.received_at, period))
            .group_by(CheckinEvent.source, CheckinEvent.kind)
        )
    ).all()
    by_source = _zero(CHECKIN_SOURCES)
    by_kind = _zero(CHECKIN_EVENT_KINDS)
    for source, kind, count in rows:
        by_source[_label(source)] = by_source.get(_label(source), 0) + int(count)
        by_kind[_label(kind)] = by_kind.get(_label(kind), 0) + int(count)
    return {"total": sum(by_source.values()), "by_source": by_source, "by_kind": by_kind}


async def _incidents(session: AsyncSession, period: Period) -> dict[str, Any]:
    rows = (
        await session.execute(
            select(EscalationIncident.status, EscalationIncident.closed_by, func.count())
            .where(*_within(EscalationIncident.opened_at, period))
            .group_by(EscalationIncident.status, EscalationIncident.closed_by)
        )
    ).all()
    by_status = _zero(INCIDENT_STATUSES)
    by_closed_by = _zero(CLOSED_BY)
    for status, closed_by, count in rows:
        by_status[_label(status)] = by_status.get(_label(status), 0) + int(count)
        if closed_by is not None:
            by_closed_by[_label(closed_by)] = by_closed_by.get(_label(closed_by), 0) + int(count)
    messaged = await _count(
        session,
        select(func.count())
        .select_from(EscalationIncident)
        .where(
            EscalationIncident.contacts_messaged_at.is_not(None),
            *_within(EscalationIncident.contacts_messaged_at, period),
        ),
    )
    # A stage ran and nobody was told: a check-in (or a void) beat the settle delay. Not a wrong
    # message, but the closest thing to one, and worth knowing how often it happens.
    stage_ran = exists().where(
        IncidentAction.incident_id == EscalationIncident.id,
        IncidentAction.kind == "execute_stage",
        IncidentAction.status == "executed",
    )
    near_miss = await _count(
        session,
        select(func.count())
        .select_from(EscalationIncident)
        .where(
            EscalationIncident.contacts_messaged_at.is_(None),
            stage_ran,
            *_within(EscalationIncident.opened_at, period),
        ),
    )
    return {
        "opened": sum(by_status.values()),
        "by_status": by_status,
        "by_closed_by": by_closed_by,
        "still_open": sum(by_status.get(s, 0) for s in OPEN_STATUSES),
        # Counted by the day contacts were first messaged, not by the day the incident opened:
        # with a long grace the two are days apart.
        "contacts_messaged": messaged,
        "counted_by": "opened_at",
        "contacts_messaged_counted_by": "contacts_messaged_at",
        "stage_executed_nobody_messaged": near_miss,
    }


async def _messages(session: AsyncSession, period: Period) -> dict[str, Any]:
    rows = (
        await session.execute(
            select(
                Notification.template_key,
                Notification.category,
                Notification.channel,
                Notification.status,
                Notification.cancelled_reason,
                func.count(),
            )
            .where(*_within(Notification.created_at, period))
            .group_by(
                Notification.template_key,
                Notification.category,
                Notification.channel,
                Notification.status,
                Notification.cancelled_reason,
            )
        )
    ).all()
    by_template: dict[str, dict[str, int]] = {}
    by_category: dict[str, dict[str, int]] = {}
    cancelled_reasons: dict[str, int] = {}
    push = {"sent": 0, "invalid_token": 0, "failed": 0}
    total = 0
    for template, category, channel, status, reason, count in rows:
        n = int(count)
        total += n
        state = _label(status)
        by_template.setdefault(_label(template), _zero(NOTIFICATION_STATUSES))[state] += n
        by_category.setdefault(_label(category), _zero(NOTIFICATION_STATUSES))[state] += n
        if state == "cancelled":
            key = _label(reason) if reason is not None else "unspecified"
            cancelled_reasons[key] = cancelled_reasons.get(key, 0) + n
        if channel == "push":
            if state == "sent":
                push["sent"] += n
            elif state == "failed":
                push["failed"] += n
            elif reason == "push_token_invalid":
                push["invalid_token"] += n
    return {
        "total": total,
        "by_template": dict(sorted(by_template.items())),
        "by_category": dict(sorted(by_category.items())),
        "cancelled_reasons": dict(sorted(cancelled_reasons.items())),
        "push": push,
    }


async def _email_delivery(session: AsyncSession, period: Period) -> dict[str, Any]:
    rows = (
        await session.execute(
            select(NotificationLog.outcome, NotificationLog.provider, func.count())
            .select_from(NotificationLog)
            .join(Notification, Notification.id == NotificationLog.notification_id)
            .where(Notification.channel == "email", *_within(NotificationLog.attempted_at, period))
            .group_by(NotificationLog.outcome, NotificationLog.provider)
        )
    ).all()
    outcomes = _zero(LOG_OUTCOMES)
    accepted_by_provider: dict[str, int] = {}
    for outcome, provider, count in rows:
        n = int(count)
        outcomes[_label(outcome)] = outcomes.get(_label(outcome), 0) + n
        if outcome == "accepted":
            key = _label(provider)
            accepted_by_provider[key] = accepted_by_provider.get(key, 0) + n
    return {
        "outcomes": outcomes,
        "accepted_by_provider": dict(sorted(accepted_by_provider.items())),
    }


async def _releases(session: AsyncSession, period: Period) -> dict[str, Any]:
    created = await _count(
        session,
        select(func.count())
        .select_from(ReleaseEvent)
        .where(*_within(ReleaseEvent.released_at, period)),
    )
    viewed = await _count(
        session,
        select(func.count())
        .select_from(ReleaseEvent)
        .where(*_within(ReleaseEvent.first_viewed_at, period)),
    )
    revoked_rows = (
        await session.execute(
            select(ReleaseEvent.revoke_reason, func.count())
            .where(*_within(ReleaseEvent.revoked_at, period), ReleaseEvent.revoked_at.is_not(None))
            .group_by(ReleaseEvent.revoke_reason)
        )
    ).all()
    by_reason = _zero(REVOKE_REASONS)
    for reason, count in revoked_rows:
        by_reason[_label(reason)] = by_reason.get(_label(reason), 0) + int(count)
    return {
        "created": created,
        "viewed": viewed,
        "revoked": sum(by_reason.values()),
        "revoked_by_reason": by_reason,
    }


@dataclass(frozen=True)
class HoldRow:
    id: uuid.UUID
    reason: str
    started_at: datetime
    detected_at: datetime
    ended_at: datetime | None
    exit_processed_at: datetime | None


async def _all_holds(session: AsyncSession) -> list[HoldRow]:
    """Reasons and instants only: the operator's free-text notes and name stay where they are."""
    rows = (
        await session.execute(
            select(
                SystemHold.id,
                SystemHold.reason,
                SystemHold.started_at,
                SystemHold.detected_at,
                SystemHold.ended_at,
                SystemHold.exit_processed_at,
            ).order_by(SystemHold.started_at, SystemHold.id)
        )
    ).all()
    return [HoldRow(r[0], _label(r[1]), r[2], r[3], r[4], r[5]) for r in rows]


def _holds_section(holds: Sequence[HoldRow], period: Period, now: datetime) -> dict[str, Any]:
    start, end = period.start, period.end
    overlapping = [
        h
        for h in holds
        if (end is None or h.started_at < end) and (start is None or (h.ended_at or now) >= start)
    ]
    entered = [h for h in overlapping if (start is None or h.started_at >= start)]
    exited = [
        h
        for h in overlapping
        if h.ended_at is not None
        and (start is None or h.ended_at >= start)
        and (end is None or h.ended_at < end)
    ]
    history: list[dict[str, Any]] = []
    total = 0.0
    for hold in overlapping:
        duration = _minutes(hold.ended_at or now, hold.started_at)
        total += duration
        history.append(
            {
                "hold_id": str(hold.id),
                "reason": hold.reason,
                "started_at": _iso(hold.started_at),
                "detected_at": _iso(hold.detected_at),
                "ended_at": _iso(hold.ended_at),
                "exit_processed_at": _iso(hold.exit_processed_at),
                "duration_minutes": duration,
                "ongoing": hold.ended_at is None,
            }
        )
    by_reason = _zero(HOLD_REASONS)
    for hold in overlapping:
        by_reason[hold.reason] = by_reason.get(hold.reason, 0) + 1
    return {
        "entered": len(entered),
        "exited": len(exited),
        "by_reason": by_reason,
        "total_minutes": round(total, 1),
        "history": history,
    }


async def _delays(
    session: AsyncSession, period: Period, audits: Mapping[str, int]
) -> dict[str, int]:
    notices = await _count(
        session,
        select(func.count())
        .select_from(Notification)
        .where(
            Notification.template_key == outbox.USER_STAGE_DEFERRED,
            *_within(Notification.created_at, period),
        ),
    )
    incidents = await _count(
        session,
        select(func.count(distinct(Notification.incident_id)))
        .select_from(Notification)
        .where(
            Notification.template_key == outbox.USER_STAGE_DEFERRED,
            *_within(Notification.created_at, period),
        ),
    )
    return {
        "incident_delayed_notices": notices,
        "incidents_with_a_delayed_notice": incidents,
        "stage_deferrals": audits.get(audit.STAGE_DEFERRED, 0),
    }


async def _audit_counts(session: AsyncSession, period: Period) -> dict[str, int]:
    wanted = (
        audit.STAGE_DEFERRED,
        audit.ACTION_HELD,
        audit.CONSISTENCY_VIOLATION,
        audit.CONTACT_BOUNCED,
        audit.ACCOUNT_DELETION_REQUESTED,
        audit.ACCOUNT_PURGED,
    )
    rows = (
        await session.execute(
            select(AuditLog.action, func.count())
            .where(AuditLog.action.in_(wanted), *_within(AuditLog.occurred_at, period))
            .group_by(AuditLog.action)
        )
    ).all()
    counts = _zero(wanted)
    for action, count in rows:
        counts[action] = int(count)
    return counts


async def collect_metrics(
    session: AsyncSession, period: Period, holds: Sequence[HoldRow], now: datetime
) -> dict[str, Any]:
    audits = await _audit_counts(session, period)
    bounced_now = await _count(
        session,
        select(func.count())
        .select_from(TrustedContact)
        .where(
            TrustedContact.verification_status == "bounced", TrustedContact.deleted_at.is_(None)
        ),
    )
    pending_deletion = await _count(
        session,
        select(func.count()).select_from(User).where(User.status == "pending_deletion"),
    )
    messages = await _messages(session, period)
    return {
        "users": await _users(session, period),
        "checkins": await _checkins(session, period),
        "incidents": await _incidents(session, period),
        "messages": {k: v for k, v in messages.items() if k != "push"},
        "delivery": {
            "email": await _email_delivery(session, period),
            "push": messages["push"],
        },
        "releases": await _releases(session, period),
        "holds": _holds_section(holds, period, now),
        "delays": await _delays(session, period, audits),
        "contacts": {
            "bounced_now": bounced_now,
            "bounced_in_period": audits.get(audit.CONTACT_BOUNCED, 0),
        },
        "accounts": {
            "pending_deletion_now": pending_deletion,
            "deletion_requested": audits.get(audit.ACCOUNT_DELETION_REQUESTED, 0),
            "deleted": audits.get(audit.ACCOUNT_PURGED, 0),
        },
        "safety": {
            "actions_held": audits.get(audit.ACTION_HELD, 0),
            "consistency_violations": audits.get(audit.CONSISTENCY_VIOLATION, 0),
        },
    }


# --- the escalated incidents ------------------------------------------------------------------


@dataclass(frozen=True)
class IncidentRow:
    id: uuid.UUID
    user_id: uuid.UUID
    status: str
    closed_by: str | None
    missed_due_at: datetime
    opened_at: datetime
    contacts_messaged_at: datetime | None
    closed_at: datetime | None
    positions: Mapping[uuid.UUID, int]  # stage id -> position (from the id-only plan snapshot)
    # why this incident is in the list: "contacts_first_messaged_in_period",
    # "closed_in_period", "still_open"
    listed_because: tuple[str, ...] = ()


@dataclass(frozen=True)
class ActionRow:
    kind: str
    variant: str | None
    step_id: uuid.UUID | None
    scheduled_for: datetime
    original_scheduled_for: datetime
    status: str
    executed_at: datetime | None
    outcome: Mapping[str, Any] | None  # IDs and reason codes only


@dataclass(frozen=True)
class MessageRow:
    id: uuid.UUID
    audience: str
    category: str
    contact_id: uuid.UUID | None
    template_key: str
    channel: str
    status: str
    cancelled_reason: str | None
    attempts: int
    provider: str | None
    created_at: datetime
    sent_at: datetime | None


@dataclass(frozen=True)
class LogRow:
    notification_id: uuid.UUID
    outcome: str
    provider: str
    error_code: str | None
    via_webhook: bool
    attempted_at: datetime


@dataclass(frozen=True)
class ReleaseRow:
    first_viewed_at: datetime | None
    view_count: int
    revoked_at: datetime | None


def _positions(snapshot: object) -> dict[uuid.UUID, int]:
    try:
        parsed = parse_snapshot(snapshot)
    except SnapshotError:
        return {}
    return {stage.stage_id: stage.position for stage in parsed.stages}


def _ids(rows: Iterable[IncidentRow]) -> list[uuid.UUID]:
    return [r.id for r in rows]


def _all(clauses: Sequence[ColumnElement[bool]]) -> ColumnElement[bool]:
    return and_(true(), *clauses)


async def _incident_rows(session: AsyncSession, period: Period) -> list[IncidentRow]:
    """Every incident in which a contact was messaged and that belongs to the period: contacts
    were first messaged in it, or it was closed in it, or it is still open (an unresolved
    alert is never left out of a report because of the dates asked for). Not selected by the
    day it opened: with a grace of up to three days, that is not the day anything reached a
    contact."""
    first = EscalationIncident.contacts_messaged_at
    open_now = EscalationIncident.status.in_(OPEN_STATUSES)
    still_open_clauses: list[ColumnElement[bool]] = [open_now]
    if period.end is not None:
        still_open_clauses.append(first < period.end)
    rows = (
        await session.execute(
            select(
                EscalationIncident.id,
                EscalationIncident.user_id,
                EscalationIncident.status,
                EscalationIncident.closed_by,
                EscalationIncident.missed_due_at,
                EscalationIncident.opened_at,
                EscalationIncident.contacts_messaged_at,
                EscalationIncident.closed_at,
                EscalationIncident.plan_snapshot,
            )
            .where(
                first.is_not(None),
                or_(
                    _all(_within(first, period)),
                    and_(
                        EscalationIncident.closed_at.is_not(None),
                        _all(_within(EscalationIncident.closed_at, period)),
                    ),
                    and_(*still_open_clauses),
                ),
            )
            .order_by(first, EscalationIncident.id)
        )
    ).all()
    found: list[IncidentRow] = []
    for r in rows:
        because: list[str] = []
        if _inside(r[6], period):
            because.append("contacts_first_messaged_in_period")
        if r[7] is not None and _inside(r[7], period):
            because.append("closed_in_period")
        if r[7] is None and r[2] in OPEN_STATUSES:
            because.append("still_open")
        found.append(
            IncidentRow(
                id=r[0],
                user_id=r[1],
                status=_label(r[2]),
                closed_by=None if r[3] is None else _label(r[3]),
                missed_due_at=r[4],
                opened_at=r[5],
                contacts_messaged_at=r[6],
                closed_at=r[7],
                positions=_positions(r[8]),
                listed_because=tuple(because),
            )
        )
    return found


def _inside(instant: datetime, period: Period) -> bool:
    start, end = period.start, period.end
    return (start is None or instant >= start) and (end is None or instant < end)


async def _actions(
    session: AsyncSession, incident_ids: Sequence[uuid.UUID]
) -> dict[uuid.UUID, list[ActionRow]]:
    out: dict[uuid.UUID, list[ActionRow]] = defaultdict(list)
    rows = (
        await session.execute(
            select(
                IncidentAction.incident_id,
                IncidentAction.kind,
                IncidentAction.variant,
                IncidentAction.step_id,
                IncidentAction.scheduled_for,
                IncidentAction.original_scheduled_for,
                IncidentAction.status,
                IncidentAction.executed_at,
                IncidentAction.outcome,
            )
            .where(IncidentAction.incident_id.in_(incident_ids))
            .order_by(IncidentAction.scheduled_for, IncidentAction.kind, IncidentAction.id)
        )
    ).all()
    for r in rows:
        out[r[0]].append(
            ActionRow(
                kind=_label(r[1]),
                variant=None if r[2] is None else _label(r[2]),
                step_id=r[3],
                scheduled_for=r[4],
                original_scheduled_for=r[5],
                status=_label(r[6]),
                executed_at=r[7],
                outcome=r[8] if isinstance(r[8], Mapping) else None,
            )
        )
    return out


async def _messages_of(
    session: AsyncSession, incident_ids: Sequence[uuid.UUID]
) -> dict[uuid.UUID, list[MessageRow]]:
    out: dict[uuid.UUID, list[MessageRow]] = defaultdict(list)
    rows = (
        await session.execute(
            select(
                Notification.incident_id,
                Notification.id,
                Notification.audience,
                Notification.category,
                Notification.contact_id,
                Notification.template_key,
                Notification.channel,
                Notification.status,
                Notification.cancelled_reason,
                Notification.attempt_count,
                Notification.provider,
                Notification.created_at,
                Notification.sent_at,
            )
            .where(Notification.incident_id.in_(incident_ids))
            .order_by(Notification.created_at, Notification.id)
        )
    ).all()
    for r in rows:
        if r[0] is None:  # selected by incident id: cannot happen
            continue
        out[r[0]].append(
            MessageRow(
                id=r[1],
                audience=_label(r[2]),
                category=_label(r[3]),
                contact_id=r[4],
                template_key=_label(r[5]),
                channel=_label(r[6]),
                status=_label(r[7]),
                cancelled_reason=None if r[8] is None else _label(r[8]),
                attempts=int(r[9]),
                provider=None if r[10] is None else _label(r[10]),
                created_at=r[11],
                sent_at=r[12],
            )
        )
    return out


async def _logs_of(
    session: AsyncSession, notification_ids: Sequence[uuid.UUID]
) -> dict[uuid.UUID, list[LogRow]]:
    out: dict[uuid.UUID, list[LogRow]] = defaultdict(list)
    if not notification_ids:
        return out
    rows = (
        await session.execute(
            select(
                NotificationLog.notification_id,
                NotificationLog.outcome,
                NotificationLog.provider,
                NotificationLog.error_code,
                NotificationLog.provider_event_id.is_not(None),
                NotificationLog.attempted_at,
            )
            .where(NotificationLog.notification_id.in_(notification_ids))
            .order_by(NotificationLog.attempted_at, NotificationLog.id)
        )
    ).all()
    for r in rows:
        out[r[0]].append(
            LogRow(
                notification_id=r[0],
                outcome=_label(r[1]),
                provider=_label(r[2]),
                error_code=None if r[3] is None else _label(r[3]),
                via_webhook=bool(r[4]),
                attempted_at=r[5],
            )
        )
    return out


async def _releases_of(
    session: AsyncSession, incident_ids: Sequence[uuid.UUID]
) -> dict[uuid.UUID, list[ReleaseRow]]:
    out: dict[uuid.UUID, list[ReleaseRow]] = defaultdict(list)
    rows = (
        await session.execute(
            select(
                ReleaseEvent.incident_id,
                ReleaseEvent.first_viewed_at,
                ReleaseEvent.view_count,
                ReleaseEvent.revoked_at,
            ).where(ReleaseEvent.incident_id.in_(incident_ids))
        )
    ).all()
    for r in rows:
        out[r[0]].append(ReleaseRow(r[1], int(r[2]), r[3]))
    return out


# What a single message came to, from the provider's reports (strongest first).
_DELIVERY_ORDER: Final = (
    "complained",
    "bounced",
    "delivered",
    "soft_bounce",
    "accepted",
    "rejected",
    "error",
)
# What a contact's messages came to, most notable first.
_OUTCOME_ORDER: Final = (
    "complained",
    "bounced",
    "failed",
    "delivered",
    "sent",
    "cancelled",
    "pending",
)


def _delivery(logs: Sequence[LogRow]) -> str | None:
    seen = {
        "soft_bounce" if log.outcome == "error" and log.via_webhook else log.outcome for log in logs
    }
    return next((label for label in _DELIVERY_ORDER if label in seen), None)


def _message_outcome(message: MessageRow, delivery: str | None) -> str:
    if delivery == "complained":
        return "complained"
    if delivery == "bounced":
        return "bounced"
    if message.status == "failed" or delivery in ("rejected", "soft_bounce"):
        return "failed"
    if delivery == "delivered":
        return "delivered"
    if message.status == "sent":
        return "sent"  # accepted by the provider; no delivery report
    if message.status == "cancelled":
        return "cancelled"
    return "pending"


def _stage_counts(outcome: Mapping[str, Any] | None) -> tuple[int, int]:
    """(messaged, skipped) targets of an executed stage, from its recorded outcome."""
    targets = outcome.get("targets") if outcome is not None else None
    messaged = skipped = 0
    if isinstance(targets, list):
        for target in targets:
            if isinstance(target, Mapping):
                result = target.get("result")
                messaged += result == "messaged"
                skipped += result == "skipped"
    return messaged, skipped


def _was_attempted(message: MessageRow) -> bool:
    """The same definition the engine uses for "this contact may have been told"."""
    return message.status in ("sending", "sent", "failed") or message.attempts > 0


def _timeline(
    incident: IncidentRow,
    actions: Sequence[ActionRow],
    holds: Sequence[HoldRow],
    now: datetime,
) -> list[dict[str, Any]]:
    origin = incident.missed_due_at
    horizon = incident.closed_at or now
    found: list[tuple[datetime, int, str, str]] = [(origin, 0, "missed", "")]
    if incident.opened_at != origin:
        found.append((incident.opened_at, 1, "incident_opened", ""))
    for hold in holds:
        if hold.started_at <= horizon and (hold.ended_at is None or hold.ended_at >= origin):
            found.append((hold.started_at, 2, "hold_started", hold.reason))
            if hold.ended_at is not None and hold.ended_at <= horizon:
                found.append((hold.ended_at, 3, "hold_ended", hold.reason))
    for action in actions:
        if action.executed_at is None:
            continue
        if action.kind == "user_reminder":
            found.append((action.executed_at, 4, "user_reminder", action.variant or ""))
        elif action.kind == "user_final_warning":
            position = incident.positions.get(action.step_id) if action.step_id else None
            found.append((action.executed_at, 5, "final_warning", _stage(position)))
        elif action.kind == "execute_stage":
            position = incident.positions.get(action.step_id) if action.step_id else None
            messaged, skipped = _stage_counts(action.outcome)
            detail = f"{_stage(position)}: {messaged} contact(s) to message, {skipped} skipped"
            found.append((action.executed_at, 6, "stage_executed", detail))
    if incident.contacts_messaged_at is not None:
        found.append((incident.contacts_messaged_at, 7, "contacts_messaged", "first message"))
    if incident.closed_at is not None:
        found.append((incident.closed_at, 8, "closed", incident.closed_by or ""))
    found.sort(key=lambda e: (e[0], e[1]))
    return [
        {"at": _iso(at), "minutes": _minutes(at, origin), "event": event, "detail": detail}
        for at, _, event, detail in found
    ]


def _stage(position: int | None) -> str:
    return f"stage {position}" if position is not None else "stage ?"


def _contacts(
    messages: Sequence[MessageRow],
    logs: Mapping[uuid.UUID, Sequence[LogRow]],
    origin: datetime,
) -> list[dict[str, Any]]:
    by_contact: dict[uuid.UUID, list[MessageRow]] = defaultdict(list)
    for message in messages:
        if message.audience == "contact" and message.contact_id is not None:
            by_contact[message.contact_id].append(message)

    def first_contact(item: tuple[uuid.UUID, list[MessageRow]]) -> tuple[int, datetime, str]:
        contact_id, rows = item
        escalation = [m.created_at for m in rows if m.category == outbox.CATEGORY_ESCALATION]
        # a contact with no escalation message at all (only a follow-up) goes after the rest
        return (
            0 if escalation else 1,
            min(escalation or [m.created_at for m in rows]),
            str(contact_id),
        )

    result: list[dict[str, Any]] = []
    for ordinal, (contact_id, rows) in enumerate(sorted(by_contact.items(), key=first_contact), 1):
        entries: list[dict[str, Any]] = []
        outcomes: list[str] = []
        for message in rows:
            delivery = _delivery(logs.get(message.id, ()))
            outcome = _message_outcome(message, delivery)
            if message.category == outbox.CATEGORY_ESCALATION:
                outcomes.append(outcome)
            codes = [
                log.error_code
                for log in logs.get(message.id, ())
                if log.error_code is not None and log.outcome != "accepted"
            ]
            entries.append(
                {
                    "template": message.template_key,
                    "category": message.category,
                    "channel": message.channel,
                    "status": message.status,
                    "cancelled_reason": message.cancelled_reason,
                    "attempts": message.attempts,
                    "provider": message.provider,
                    "delivery": delivery,
                    "error_code": codes[-1] if codes else None,
                    "sent_minutes": (
                        None if message.sent_at is None else _minutes(message.sent_at, origin)
                    ),
                }
            )
        pool = outcomes or [_message_outcome(m, _delivery(logs.get(m.id, ()))) for m in rows]
        summary = next(o for o in _OUTCOME_ORDER if o in pool)
        result.append(
            {
                "label": f"contact-{ordinal}",
                "contact_id": str(contact_id),
                "outcome": summary,
                "attempted": any(
                    _was_attempted(m) for m in rows if m.category == outbox.CATEGORY_ESCALATION
                ),
                "messages": entries,
            }
        )
    return result


def _hints(
    incident: IncidentRow,
    actions: Sequence[ActionRow],
    messages: Sequence[MessageRow],
    logs: Mapping[uuid.UUID, Sequence[LogRow]],
    releases: Sequence[ReleaseRow],
    holds: Sequence[HoldRow],
    *,
    now: datetime,
    fallback_provider: str | None,
) -> list[str]:
    fired: set[str] = set()
    contact_messages = [m for m in messages if m.audience == "contact"]
    if incident.closed_by in ("user_checkin", "user_safe"):
        fired.add("closed_by_checkin_after_contacts_messaged")
    if incident.closed_by == "operator_void":
        fired.add("voided_by_operator_after_contacts_messaged")
    if incident.closed_by == "account_deleted":
        fired.add("closed_by_account_deletion_after_contacts_messaged")
    fired.update(_hold_hints(incident, holds, now))
    delivery_of = {m.id: _delivery(logs.get(m.id, ())) for m in contact_messages}
    if any(d == "complained" for d in delivery_of.values()):
        fired.add("complaint_received")
    if any(r.first_viewed_at is not None for r in releases):
        fired.add("released_and_viewed")
    if any(a.scheduled_for > a.original_scheduled_for for a in actions) or any(
        m.template_key == outbox.USER_STAGE_DEFERRED for m in messages
    ):
        fired.add("stage_delayed")
    if any(
        m.status == "failed" or delivery_of[m.id] in ("bounced", "rejected", "soft_bounce")
        for m in contact_messages
    ):
        fired.add("delivery_failed_to_a_contact")
    if _fallback_used(contact_messages, logs, fallback_provider):
        fired.add("provider_fallback_used")
    if any(_stage_counts(a.outcome)[1] for a in actions if a.status == "executed"):
        fired.add("contact_skipped")
    if any(a.status == "held" for a in actions):
        fired.add("action_held")
    first = incident.contacts_messaged_at
    if first is not None:
        if incident.closed_at is not None and incident.closed_at - first > LATE_RESOLUTION:
            fired.add("late_resolution_over_24h")
        if incident.closed_at is None and now - first > LATE_RESOLUTION:
            fired.add("still_open_over_24h")
    return sorted(fired, key=_RULE_ORDER.__getitem__)


def _hold_hints(incident: IncidentRow, holds: Sequence[HoldRow], now: datetime) -> set[str]:
    """Opened while a Hold was active (its window starts at the last good probe, before it was
    noticed) or within 24 hours after it ended; or a Hold overlapped the time between the
    missed deadline and the first contact message, which is what a Hold exit shifts."""
    opened = incident.opened_at
    if any(
        h.started_at <= opened and (h.ended_at is None or opened < h.ended_at + HOLD_EXIT_WINDOW)
        for h in holds
    ):
        return {"opened_within_24h_of_hold_exit"}
    upper = incident.contacts_messaged_at or incident.closed_at or now
    if any(
        h.started_at <= upper and (h.ended_at is None or h.ended_at >= incident.missed_due_at)
        for h in holds
    ):
        return {"hold_overlapped_incident"}
    return set()


def _fallback_used(
    messages: Sequence[MessageRow],
    logs: Mapping[uuid.UUID, Sequence[LogRow]],
    fallback_provider: str | None,
) -> bool:
    for message in messages:
        if message.channel != "email":
            continue
        if fallback_provider is not None and message.provider == fallback_provider:
            return True
        # our own attempts only: a webhook event carries the provider that sent the message
        tried = {log.provider for log in logs.get(message.id, ()) if not log.via_webhook}
        if len(tried) > 1:  # one message, two providers: the chain moved on
            return True
    return False


def incident_block(
    incident: IncidentRow,
    actions: Sequence[ActionRow],
    messages: Sequence[MessageRow],
    logs: Mapping[uuid.UUID, Sequence[LogRow]],
    releases: Sequence[ReleaseRow],
    holds: Sequence[HoldRow],
    *,
    now: datetime,
    fallback_provider: str | None = None,
) -> dict[str, Any]:
    """One incident, as the review document describes it. Pure: facts in, a dict out."""
    contacts = _contacts(messages, logs, incident.missed_due_at)
    hints = _hints(
        incident,
        actions,
        messages,
        logs,
        releases,
        holds,
        now=now,
        fallback_provider=fallback_provider,
    )
    reasons = [h for h in hints if h in _REVIEW_RULES]
    resolution = None
    if incident.closed_at is not None and incident.contacts_messaged_at is not None:
        resolution = _minutes(incident.closed_at, incident.contacts_messaged_at)
    user_notices: dict[str, dict[str, int]] = {}
    for message in messages:
        if message.audience == "user":
            notice = user_notices.setdefault(message.template_key, {})
            notice[message.status] = notice.get(message.status, 0) + 1
    action_counts = {"executed": 0, "pending": 0, "cancelled": 0, "held": 0}
    for action in actions:
        action_counts[action.status] = action_counts.get(action.status, 0) + 1
    return {
        "incident_id": str(incident.id),
        "user_id": str(incident.user_id),
        "opened_at": _iso(incident.opened_at),
        "missed_due_at": _iso(incident.missed_due_at),
        "listed_because": list(incident.listed_because),
        "status": incident.status,
        "closed_by": incident.closed_by,
        "closed_at": _iso(incident.closed_at),
        "contacts_messaged_at": _iso(incident.contacts_messaged_at),
        "minutes_from_first_contact_message_to_resolution": resolution,
        "timeline": _timeline(incident, actions, holds, now),
        "actions": action_counts,
        "contacts_messaged": sum(1 for c in contacts if c["attempted"]),
        "contacts": contacts,
        "user_notices": dict(sorted(user_notices.items())),
        "releases": {
            "created": len(releases),
            "viewed": sum(1 for r in releases if r.first_viewed_at is not None),
            "revoked": sum(1 for r in releases if r.revoked_at is not None),
            "views": sum(r.view_count for r in releases),
        },
        "hints": hints,
        "needs_human_review": bool(reasons),
        "review_reasons": reasons,
    }


async def collect_escalated(
    session: AsyncSession,
    period: Period,
    holds: Sequence[HoldRow],
    now: datetime,
    *,
    fallback_provider: str | None,
) -> list[dict[str, Any]]:
    incidents = await _incident_rows(session, period)
    if not incidents:
        return []
    ids = _ids(incidents)
    actions = await _actions(session, ids)
    messages = await _messages_of(session, ids)
    contact_message_ids = [
        m.id for rows in messages.values() for m in rows if m.audience == "contact"
    ]
    logs = await _logs_of(session, contact_message_ids)
    releases = await _releases_of(session, ids)
    return [
        incident_block(
            incident,
            actions.get(incident.id, []),
            messages.get(incident.id, []),
            logs,
            releases.get(incident.id, []),
            holds,
            now=now,
            fallback_provider=fallback_provider,
        )
        for incident in incidents
    ]


# --- the report -------------------------------------------------------------------------------


class SchemaMismatch(Exception):  # noqa: N818 - the operator's "refused", not an error code
    """The database is not the one this code reads: a table is missing, or its migration
    revision is not the code's head. A report over it would look like a quiet beta."""


def code_heads() -> frozenset[str]:
    """The Alembic head(s) of the migration scripts shipped with this code."""
    try:
        return frozenset(ScriptDirectory(str(BACKEND_DIR / "migrations")).get_heads())
    except Exception as exc:  # the scripts are missing or unreadable: say so, do not guess
        msg = f"cannot read the migration scripts of this build ({type(exc).__name__})"
        raise SchemaMismatch(msg) from exc


async def identify(
    session: AsyncSession, *, environment: str, heads: frozenset[str]
) -> dict[str, Any]:
    """What was read: database, role, revision. Raises :class:`SchemaMismatch` when a table the
    report reads is missing or the revision is not the code's head."""
    database, role = (await session.execute(text("SELECT current_database(), current_user"))).one()
    present = {
        str(r[0])
        for r in await session.execute(
            text("SELECT tablename FROM pg_tables WHERE schemaname = current_schema()")
        )
    }
    missing = sorted({*ALL_TABLES, "alembic_version"} - present)
    if missing:
        shown = ", ".join(missing[:_SHOWN_TABLES]) + (
            " ..." if len(missing) > _SHOWN_TABLES else ""
        )
        msg = (
            f"database {database!r} is missing {len(missing)} table(s) ({shown}): this is not "
            "a migrated AfterMe database. Nothing was reported."
        )
        raise SchemaMismatch(msg)
    revisions = sorted(
        str(r[0]) for r in await session.execute(text("SELECT version_num FROM alembic_version"))
    )
    if frozenset(revisions) != heads:
        msg = (
            f"database {database!r} is at migration revision {', '.join(revisions) or '(none)'} "
            f"but this code's head is {', '.join(sorted(heads))}: run `alembic upgrade head`, or "
            "this is the wrong database. Nothing was reported."
        )
        raise SchemaMismatch(msg)
    return {
        "database": str(database),
        "role": str(role),
        "environment": environment,
        "alembic_revision": ", ".join(revisions),
        "schema_at_head": True,
    }


def _notification_retention_days() -> int:
    return next(r.keep.days for r in RETENTION_RULES if r.name == "notifications")


async def _coverage(session: AsyncSession, period: Period, purged: int) -> dict[str, Any]:
    """How much of the evidence still exists, so that a quiet report is not taken for a
    complete one: messages and their delivery log go 90 days after their incident closed, and
    a purged account takes its incidents with it."""
    oldest: datetime | None = (
        await session.execute(select(func.min(Notification.created_at)))
    ).scalar_one()
    start = period.start
    return {
        "oldest_notification_at": _iso(oldest),
        "notification_retention_days": _notification_retention_days(),
        "period_starts_before_oldest_notification": bool(
            oldest is not None and start is not None and start < oldest
        ),
        "accounts_purged_in_period": purged,
    }


async def _still_open_with_contacts_messaged(session: AsyncSession) -> list[str]:
    """Alarms that are active now, whatever the dates asked for."""
    rows = await session.execute(
        select(EscalationIncident.id)
        .where(
            EscalationIncident.status.in_(OPEN_STATUSES),
            EscalationIncident.contacts_messaged_at.is_not(None),
        )
        .order_by(EscalationIncident.contacts_messaged_at, EscalationIncident.id)
    )
    return [str(r[0]) for r in rows]


@dataclass(frozen=True)
class BetaReport:
    generated_at: str
    source: dict[str, Any]
    period: dict[str, Any]
    coverage: dict[str, Any]
    still_open: list[str]
    metrics: dict[str, Any]
    escalated_incidents: list[dict[str, Any]]

    def as_dict(self) -> dict[str, Any]:
        flagged = [i["incident_id"] for i in self.escalated_incidents if i["needs_human_review"]]
        return {
            "schema_version": SCHEMA_VERSION,
            "generated_at": self.generated_at,
            "source": self.source,
            "period": self.period,
            "coverage": self.coverage,
            "review": {
                "escalated_incidents": len(self.escalated_incidents),
                "needs_human_review": len(flagged),
                "incident_ids": flagged,
                "listed_by": "contacts_first_messaged_in_period, closed_in_period or still_open",
                "still_open_with_contacts_messaged": len(self.still_open),
                "still_open_incident_ids": self.still_open,
            },
            "metrics": self.metrics,
            "escalated_incidents": self.escalated_incidents,
            "rules": [
                {"name": r.name, "needs_review": r.needs_review, "meaning": r.meaning}
                for r in RULES
            ],
        }


async def beta_report(
    services: AppServices,
    *,
    since: date | None = None,
    until: date | None = None,
    heads: frozenset[str] | None = None,
) -> BetaReport:
    """The report for ``[since, until]`` (UTC days, inclusive; either may be left open).

    Raises :class:`SchemaMismatch` instead of reporting on a database that is not at the code's
    head (``heads`` overrides the migration scripts' head, for tests)."""
    period = Period(since=since, until=until)
    environment = getattr(services.settings.app_env, "value", str(services.settings.app_env))
    expected = code_heads() if heads is None else heads
    async with read_only_session(services) as session:
        source = await identify(session, environment=str(environment), heads=expected)
        now = await services.clock.now(session)
        holds = await _all_holds(session)
        metrics = await collect_metrics(session, period, holds, now)
        escalated = await collect_escalated(
            session,
            period,
            holds,
            now,
            fallback_provider=services.settings.email_fallback_provider,
        )
        coverage = await _coverage(session, period, metrics["accounts"]["deleted"])
        still_open = await _still_open_with_contacts_messaged(session)
    return BetaReport(
        generated_at=now.astimezone(UTC).isoformat(),
        source=source,
        period=period.as_dict(),
        coverage=coverage,
        still_open=still_open,
        metrics=metrics,
        escalated_incidents=escalated,
    )


# --- the text form ----------------------------------------------------------------------------


def _bar(counts: Mapping[str, int | float]) -> str:
    return " | ".join(f"{key} {value}" for key, value in counts.items()) or "none"


def format_text(document: Mapping[str, Any]) -> str:
    """The human-readable form of :meth:`BetaReport.as_dict` (nothing here the document lacks)."""
    out: list[str] = []
    add = out.append
    period = document["period"]
    review = document["review"]
    source = document["source"]
    coverage = document["coverage"]
    add("AfterMe closed-beta report")
    add(f"generated   {document['generated_at']} (database clock)")
    add(
        f"source      database {source['database']} as role {source['role']} | migration "
        f"revision {source['alembic_revision']} (the code's head) | environment "
        f"{source['environment']}"
    )
    since, until = period["since"], period["until"]
    span = (
        "all time" if not since and not until else f"{since or 'the beginning'} to {until or 'now'}"
    )
    add(f"period      {span} (UTC days, both ends inclusive)")
    oldest = coverage["oldest_notification_at"] or "none on record"
    add(
        f"coverage    oldest message still held: {oldest} (messages and their delivery log go "
        f"{coverage['notification_retention_days']} days after their incident closes) | "
        f"accounts purged in the period: {coverage['accounts_purged_in_period']} (their "
        "incidents went with them)"
    )
    if coverage["period_starts_before_oldest_notification"]:
        add(
            "            the period starts before the oldest message held: older incidents "
            "show no contacts"
        )
    add("")
    add(
        f"REVIEW      {review['escalated_incidents']} escalated incident(s) listed, "
        f"{review['needs_human_review']} NEED HUMAN REVIEW"
    )
    add("            (the report flags; an operator decides)")
    add(
        f"STILL OPEN  {review['still_open_with_contacts_messaged']} still open with contacts "
        "messaged: review when they close"
    )
    for incident_id in review["still_open_incident_ids"]:
        add(f"              {incident_id}")
    add("            (listed: contacts first messaged in the period, closed in the period, or")
    add("             still open; the incident counts below are by the day each one opened)")
    add("")
    add("== Metrics for the period ==")
    _metrics_text(document["metrics"], add)
    add("")
    add("== Incidents in which contacts were messaged ==")
    incidents = document["escalated_incidents"]
    if not incidents:
        add("none in this period")
    fired: set[str] = set()
    for item in incidents:
        add("")
        fired.update(item["hints"])
        _block_text(item, add)
    if fired:
        add("")
        add("== Rules that fired ==")
        for rule in document["rules"]:
            if rule["name"] in fired:
                kind = "review" if rule["needs_review"] else "context"
                add(f"{rule['name']} [{kind}]")
                add(f"    {rule['meaning']}")
    return "\n".join(out) + "\n"


def _metrics_text(metrics: Mapping[str, Any], add: Callable[[str], None]) -> None:
    users = metrics["users"]
    add(
        f"users       created {users['created']} | active (checked in) {users['active']} | "
        f"with an active schedule now {users['with_active_schedule_now']}"
    )
    checkins = metrics["checkins"]
    add(
        f"check-ins   {checkins['total']} | by source: {_bar(checkins['by_source'])} | "
        f"by kind: {_bar(checkins['by_kind'])}"
    )
    inc = metrics["incidents"]
    add(
        f"incidents   opened {inc['opened']} | still open {inc['still_open']} | "
        f"contacts messaged {inc['contacts_messaged']} | "
        f"stage ran but nobody was told {inc['stage_executed_nobody_messaged']}"
    )
    add(f"  closed_by   {_bar(inc['by_closed_by'])}")
    add(f"  status      {_bar(inc['by_status'])}")
    messages = metrics["messages"]
    add(f"messages    {messages['total']} created")
    for category, counts in messages["by_category"].items():
        add(f"  [{category}] {_bar(counts)}")
    for template, counts in messages["by_template"].items():
        add(f"  {template:<28} {_bar(counts)}")
    add(f"  cancelled reasons   {_bar(messages['cancelled_reasons'])}")
    delivery = metrics["delivery"]
    add(f"email       attempts: {_bar(delivery['email']['outcomes'])}")
    add(f"            accepted by provider: {_bar(delivery['email']['accepted_by_provider'])}")
    add(f"push        {_bar(delivery['push'])}")
    releases = metrics["releases"]
    why = _bar({k: v for k, v in releases["revoked_by_reason"].items() if v})
    add(
        f"releases    created {releases['created']} | viewed {releases['viewed']} | "
        f"revoked {releases['revoked']} ({why})"
    )
    holds = metrics["holds"]
    add(
        f"holds       entered {holds['entered']} | exited {holds['exited']} | "
        f"{holds['total_minutes']} min in total | by reason: {_bar(holds['by_reason'])}"
    )
    for hold in holds["history"]:
        end = hold["ended_at"] or "still active"
        processed = (
            ""
            if hold["ended_at"] is None
            else (" exit processed" if hold["exit_processed_at"] else " exit NOT processed yet")
        )
        add(
            f"  {hold['hold_id']}  {hold['reason']:<9} {hold['started_at']} -> {end} "
            f"({hold['duration_minutes']} min){processed}"
        )
    delays = metrics["delays"]
    add(
        f"delays      incident_delayed notices {delays['incident_delayed_notices']} "
        f"(in {delays['incidents_with_a_delayed_notice']} incident(s)) | "
        f"stage deferrals {delays['stage_deferrals']}"
    )
    contacts = metrics["contacts"]
    add(
        f"contacts    marked bounced now {contacts['bounced_now']} | "
        f"bounced in the period {contacts['bounced_in_period']}"
    )
    accounts = metrics["accounts"]
    add(
        f"accounts    deletion requested {accounts['deletion_requested']} | "
        f"deleted {accounts['deleted']} | pending deletion now {accounts['pending_deletion_now']}"
    )
    safety = metrics["safety"]
    add(
        f"safety      actions held by a gate {safety['actions_held']} | "
        f"consistency violations {safety['consistency_violations']}"
    )


def _block_text(item: Mapping[str, Any], add: Callable[[str], None]) -> None:
    flag = "   *** NEEDS HUMAN REVIEW ***" if item["needs_human_review"] else ""
    add(f"INCIDENT {item['incident_id']}{flag}")
    add(f"  owner (user id)   {item['user_id']}")
    add(f"  opened_at         {item['opened_at']}")
    ended = item["status"]
    if item["closed_by"]:
        ended += f" by {item['closed_by']}: {_CLOSER_TEXT.get(item['closed_by'], 'see closed_by')}"
    add(f"  ended             {ended}")
    resolution = item["minutes_from_first_contact_message_to_resolution"]
    add(
        "  first contact message -> resolution   "
        + ("not resolved yet" if resolution is None else f"{resolution} min")
    )
    add("  timeline (minutes from the due time)")
    for event in item["timeline"]:
        detail = f"  {event['detail']}" if event["detail"] else ""
        add(f"    {event['minutes']:>9.1f}  {event['event']}{detail}")
    add(
        f"  contacts          {item['contacts_messaged']} messaged, "
        f"{len(item['contacts'])} with a message on record"
    )
    for contact in item["contacts"]:
        add(f"    {contact['label']:<10} {contact['outcome']:<10} (id {contact['contact_id']})")
        for message in contact["messages"]:
            extra = []
            if message["cancelled_reason"]:
                extra.append(f"cancelled: {message['cancelled_reason']}")
            if message["delivery"]:
                extra.append(f"delivery: {message['delivery']}")
            if message["error_code"]:
                extra.append(f"error: {message['error_code']}")
            if message["provider"]:
                extra.append(f"via {message['provider']}")
            tail = f"  [{', '.join(extra)}]" if extra else ""
            add(
                f"        {message['template']} {message['channel']} {message['status']} "
                f"x{message['attempts']}{tail}"
            )
    notices = item["user_notices"]
    if notices:
        add("  the person was sent")
        for template, counts in notices.items():
            add(f"    {template:<28} {_bar(counts)}")
    releases = item["releases"]
    add(
        f"  releases          created {releases['created']} | viewed {releases['viewed']} | "
        f"revoked {releases['revoked']}"
    )
    actions = item["actions"]
    add(f"  actions           {_bar(actions)}")
    add("  verdict hints     " + (", ".join(item["hints"]) if item["hints"] else "none"))
    if item["needs_human_review"]:
        add("  review because    " + ", ".join(item["review_reasons"]))
