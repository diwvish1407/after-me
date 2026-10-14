"""Retention (DATABASE §5): what is kept, and for how long.

Each purge deletes the oldest rows in batches and stops after a bounded number of batches per
run, so a large backlog is worked off over several runs and never holds a long transaction. The
role that runs it (``afterme_maintenance``) may delete only these tables and read only the
columns each purge filters on.

Sessions, refresh tokens, one-time tokens, devices and the audit log (Phase 10): a login session
and what hangs off it goes 30 days after it expired or was revoked, a device 90 days after it was
last seen once no live session uses it, and an audit record after ``AUDIT_RETENTION_DAYS``
(365 by default, never less than 90: counsel confirms the period). What a rule never touches:
a live session, anything of an account that is ``pending_deletion`` (it goes with the account,
which is the hard limit), and the devices and audit records an *open* incident still needs.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Final

from sqlalchemy import ColumnElement, delete, func, literal_column, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import InstrumentedAttribute

from app.audit.models import AuditLog
from app.auth.models import AuthSession, AuthToken, Device, RefreshToken, User
from app.checkins.models import CheckinEvent
from app.contacts.models import ContactVerification
from app.incidents.models import OPEN_STATUSES, EscalationIncident
from app.notifications.models import EmailReceipt, Notification
from app.ops.models import IngestionProbe
from app.releases.models import PortalOtpChallenge, PortalSession, PortalToken

BATCH: Final = 1_000
MAX_BATCHES: Final = 20
_TERMINAL: Final = ("sent", "failed", "cancelled")


AUDIT_RETENTION_DEFAULT_DAYS: Final = 365
AUDIT_RETENTION_MIN_DAYS: Final = 90


def _exists(*conditions: ColumnElement[bool]) -> ColumnElement[bool]:
    """``EXISTS (SELECT 1 ...)``. Not ``exists().where()``, which renders ``SELECT *``: that
    needs SELECT on every column of the table, and this role may read only a few."""
    return select(literal_column("1")).where(*conditions).exists()


def _pending_deletion(
    user_id: ColumnElement[Any] | InstrumentedAttribute[Any],
) -> ColumnElement[bool]:
    return _exists(User.id == user_id, User.status == "pending_deletion")


def _pending_deletion_of_session(
    session_id: ColumnElement[Any] | InstrumentedAttribute[Any],
) -> ColumnElement[bool]:
    return _exists(
        AuthSession.id == session_id,
        User.id == AuthSession.user_id,
        User.status == "pending_deletion",
    )


def _live_session(
    session_id: ColumnElement[Any] | InstrumentedAttribute[Any], now: datetime
) -> ColumnElement[bool]:
    return _exists(
        AuthSession.id == session_id,
        AuthSession.revoked_at.is_(None),
        AuthSession.idle_expires_at > now,
        AuthSession.absolute_expires_at > now,
    )


def _has_open_incident(
    user_id: ColumnElement[Any] | InstrumentedAttribute[Any],
) -> ColumnElement[bool]:
    return _exists(
        EscalationIncident.user_id == user_id, EscalationIncident.status.in_(OPEN_STATUSES)
    )


@dataclass(frozen=True)
class Rule:
    """Rows of ``id_column``'s table whose ``time_column`` is older than ``keep``. ``guard`` is a
    condition every deleted row must also meet; as a callable it is given the clock's ``now``
    (a live session is "live" at an instant)."""

    name: str
    id_column: InstrumentedAttribute[Any]
    time_column: ColumnElement[Any] | InstrumentedAttribute[Any]
    keep: timedelta
    guard: ColumnElement[bool] | Callable[[datetime], ColumnElement[bool]] | None = None


RULES: Final[tuple[Rule, ...]] = (
    # Messages and their attempt log (cascade): 90 days after they finished, and **never** while
    # their incident is still open: an incident stays open until the person returns, however
    # long that takes, and the messages it sent are who must be told it is over.
    Rule(
        "notifications",
        Notification.id,
        Notification.created_at,
        timedelta(days=90),
        Notification.status.in_(_TERMINAL)
        & or_(
            Notification.incident_id.is_(None),
            Notification.incident_id.not_in(
                select(EscalationIncident.id).where(EscalationIncident.status.in_(OPEN_STATUSES))
            ),
        ),
    ),
    Rule("email_receipts", EmailReceipt.id, EmailReceipt.sent_at, timedelta(days=90)),
    Rule("ingestion_probes", IngestionProbe.id, IngestionProbe.received_at, timedelta(days=30)),
    Rule("checkin_events", CheckinEvent.id, CheckinEvent.received_at, timedelta(days=400)),
    # Expired links and codes: kept 30 days after they stopped working (support questions).
    Rule(
        "contact_verifications",
        ContactVerification.id,
        ContactVerification.expires_at,
        timedelta(days=30),
    ),
    Rule("portal_tokens", PortalToken.id, PortalToken.expires_at, timedelta(days=30)),
    Rule("portal_sessions", PortalSession.id, PortalSession.expires_at, timedelta(days=30)),
    Rule(
        "portal_otp_challenges",
        PortalOtpChallenge.id,
        PortalOtpChallenge.expires_at,
        timedelta(days=30),
    ),
    # Login material (PRIVACY: "removed 30 days after they expire or are revoked"). A refresh
    # token goes 30 days after it was used (rotated out) or expired; the token a *live* session
    # would use next is never among them. One-time codes and links: 30 days after they were
    # used or expired. A session (it carries an IP hash and a user agent): 30 days after the
    # earlier of its revocation and its expiry; a live session has neither and is not touched.
    Rule(
        "refresh_tokens",
        RefreshToken.id,
        func.least(RefreshToken.used_at, RefreshToken.expires_at),
        timedelta(days=30),
        lambda now: (
            ~_pending_deletion_of_session(RefreshToken.session_id)
            & or_(RefreshToken.used_at.is_not(None), ~_live_session(RefreshToken.session_id, now))
        ),
    ),
    Rule(
        "auth_tokens",
        AuthToken.id,
        func.least(AuthToken.used_at, AuthToken.expires_at),
        timedelta(days=30),
        ~_pending_deletion(AuthToken.user_id),
    ),
    Rule(
        "sessions",
        AuthSession.id,
        func.least(
            AuthSession.revoked_at, AuthSession.idle_expires_at, AuthSession.absolute_expires_at
        ),
        timedelta(days=30),
        ~_pending_deletion(AuthSession.user_id),
    ),
    # A device nobody has used for 90 days and no live session runs on. Not while its owner has
    # an open incident: the push reminders of that incident go to it.
    Rule(
        "devices",
        Device.id,
        Device.last_seen_at,
        timedelta(days=90),
        lambda now: (
            ~_exists(
                AuthSession.device_id == Device.id,
                AuthSession.revoked_at.is_(None),
                AuthSession.idle_expires_at > now,
                AuthSession.absolute_expires_at > now,
            )
            & ~_pending_deletion(Device.user_id)
            & ~_has_open_incident(Device.user_id)
        ),
    ),
)


def audit_rule(days: int) -> Rule:
    """Audit records older than ``days``, except the trail of an incident that is still open
    and anything about an account that is being deleted (both are read by someone yet)."""
    if days < AUDIT_RETENTION_MIN_DAYS:
        msg = f"audit retention must be at least {AUDIT_RETENTION_MIN_DAYS} days, not {days}"
        raise ValueError(msg)
    return Rule(
        "audit_logs",
        AuditLog.id,
        AuditLog.occurred_at,
        timedelta(days=days),
        ~_exists(
            AuditLog.resource_type == "incident",
            EscalationIncident.id == AuditLog.resource_id,
            EscalationIncident.status.in_(OPEN_STATUSES),
        )
        & or_(AuditLog.subject_user_id.is_(None), ~_pending_deletion(AuditLog.subject_user_id)),
    )


async def purge(session: AsyncSession, rule: Rule, *, now: datetime) -> int:
    """Delete ``rule``'s expired rows, oldest first. Returns how many went."""
    cutoff = now - rule.keep
    removed = 0
    model = rule.id_column.class_
    for _ in range(MAX_BATCHES):
        due = select(rule.id_column).where(rule.time_column < cutoff)
        guard = rule.guard(now) if callable(rule.guard) else rule.guard
        if guard is not None:
            due = due.where(guard)
        due = due.order_by(rule.time_column).limit(BATCH)
        result = await session.execute(
            delete(model).where(rule.id_column.in_(due)).returning(rule.id_column)
        )
        count = len(result.all())
        removed += count
        if count < BATCH:
            break
    return removed


async def purge_all(
    session: AsyncSession,
    *,
    now: datetime,
    audit_retention_days: int = AUDIT_RETENTION_DEFAULT_DAYS,
) -> dict[str, int]:
    """Every rule once; ``{rule name: rows removed}``."""
    rules = (*RULES, audit_rule(audit_retention_days))
    return {rule.name: await purge(session, rule, now=now) for rule in rules}
