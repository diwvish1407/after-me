"""Retention (DATABASE §5): what is kept, and for how long.

Each purge deletes the oldest rows in batches and stops after a bounded number of batches per
run, so a large backlog is worked off over several runs and never holds a long transaction. The
role that runs it (``afterme_maintenance``) may delete only these tables and read only the two
columns each purge filters on.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Final

from sqlalchemy import ColumnElement, delete, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import InstrumentedAttribute

from app.checkins.models import CheckinEvent
from app.contacts.models import ContactVerification
from app.incidents.models import OPEN_STATUSES, EscalationIncident
from app.notifications.models import EmailReceipt, Notification
from app.ops.models import IngestionProbe
from app.releases.models import PortalOtpChallenge, PortalSession, PortalToken

BATCH: Final = 1_000
MAX_BATCHES: Final = 20
_TERMINAL: Final = ("sent", "failed", "cancelled")


@dataclass(frozen=True)
class Rule:
    name: str
    id_column: InstrumentedAttribute[object]
    time_column: InstrumentedAttribute[datetime]
    keep: timedelta
    extra: ColumnElement[bool] | None = None


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
)


async def purge(session: AsyncSession, rule: Rule, *, now: datetime) -> int:
    """Delete ``rule``'s expired rows, oldest first. Returns how many went."""
    cutoff = now - rule.keep
    removed = 0
    model = rule.id_column.class_
    for _ in range(MAX_BATCHES):
        due = select(rule.id_column).where(rule.time_column < cutoff)
        if rule.extra is not None:
            due = due.where(rule.extra)
        due = due.order_by(rule.time_column).limit(BATCH)
        result = await session.execute(
            delete(model).where(rule.id_column.in_(due)).returning(rule.id_column)
        )
        count = len(result.all())
        removed += count
        if count < BATCH:
            break
    return removed


async def purge_all(session: AsyncSession, *, now: datetime) -> dict[str, int]:
    return {rule.name: await purge(session, rule, now=now) for rule in RULES}
