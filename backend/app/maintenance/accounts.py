"""Finishing account deletion (DATABASE §4, §5).

``DELETE /v1/me`` closes an account at once and leaves the rest to this job:

* :func:`scrub_settled_contacts`: a contact that still had an all-clear queued when the account
  was closed could not be scrubbed then (the dispatcher re-reads a contact before sending, and a
  deleted contact is never written to). Once nothing is waiting for them, they are scrubbed
  here, and so is the person's name (the withdrawn-alert message says whose alert it withdraws).
* :func:`purge_due_accounts`: after the retention period the ``users`` row is deleted and every
  owned row goes with it (the foreign keys cascade). The audit log keeps only pseudonymous
  identifiers. An account whose all-clear has still not left is *not* purged: removing it would
  cascade-delete a message that undoes an alarm. Each account is removed in its own savepoint,
  so one that cannot be removed does not hold up the ones behind it.

Both are idempotent and take a batch size, so a long backlog is worked off in small steps.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta

from sqlalchemy import ColumnElement, delete, literal, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import InstrumentedAttribute

from app.audit import writer as audit
from app.audit.writer import AuditEvent, AuditWriter
from app.auth.models import User
from app.contacts.models import TrustedContact
from app.core.logging import get_logger
from app.notifications.models import Notification
from app.users.models import UserProfile

_WAITING = ("queued", "sending")
DELETED_NAME = "Deleted user"
_log = get_logger("afterme.maintenance")


def _waiting_for(user_id_column: InstrumentedAttribute[uuid.UUID]) -> ColumnElement[bool]:
    """A contact-facing message of this account that has not left yet."""
    # ``SELECT 1``, not ``SELECT *``: the role may read only three columns of ``notifications``.
    return (
        select(literal(1))
        .where(
            Notification.user_id == user_id_column,
            Notification.contact_id.is_not(None),
            Notification.status.in_(_WAITING),
        )
        .exists()
    )


async def scrub_settled_contacts(session: AsyncSession, *, now: datetime) -> int:
    """Scrub live contacts of accounts pending deletion that have no message waiting, then the
    names of accounts with nothing waiting at all. Returns the number of contacts scrubbed."""
    pending = select(User.id).where(User.status == "pending_deletion")
    waiting = select(Notification.contact_id).where(
        Notification.contact_id.is_not(None), Notification.status.in_(_WAITING)
    )
    result = await session.execute(
        update(TrustedContact)
        .where(
            TrustedContact.deleted_at.is_(None),
            TrustedContact.user_id.in_(pending),
            TrustedContact.id.not_in(waiting),
        )
        .values(
            deleted_at=now,
            display_name="Deleted contact",
            email=None,
            email_normalized=None,
            phone_e164=None,
            relationship_label=None,
            is_active=False,
            updated_at=now,
        )
        .returning(TrustedContact.id)
    )
    scrubbed = len(result.all())
    await session.execute(
        update(UserProfile)
        .where(
            UserProfile.user_id.in_(pending),
            UserProfile.display_name != DELETED_NAME,
            ~_waiting_for(UserProfile.user_id),
        )
        .values(display_name=DELETED_NAME, updated_at=now)
    )
    return scrubbed


async def purge_due_accounts(
    session: AsyncSession,
    writer: AuditWriter,
    *,
    now: datetime,
    retention_days: int,
    batch: int = 50,
) -> list[uuid.UUID]:
    """Hard-delete up to ``batch`` accounts closed at least ``retention_days`` ago. Returns the
    (now pseudonymous) ids that were removed."""
    due = (
        select(User.id)
        .where(
            User.status == "pending_deletion",
            User.deletion_requested_at <= now - timedelta(days=retention_days),
            ~_waiting_for(User.id),
        )
        .order_by(User.deletion_requested_at)
        .limit(batch)
    )
    candidates = list((await session.execute(due)).scalars())
    removed: list[uuid.UUID] = []
    for user_id in candidates:
        try:
            async with session.begin_nested():
                gone = await session.execute(
                    delete(User)
                    .where(User.id == user_id, User.status == "pending_deletion")
                    .returning(User.id)
                )
                if gone.first() is None:
                    continue
                await writer.record(
                    session,
                    AuditEvent(
                        action=audit.ACCOUNT_PURGED,
                        occurred_at=now,
                        subject_user_id=user_id,
                        actor_type="system",
                        resource_type="account",
                        metadata={"retention_days": retention_days},
                        user_visible=False,
                    ),
                )
        except Exception as exc:  # one account must never stop the ones behind it
            _log.error("maintenance.account_purge_failed", error_class=type(exc).__name__)
            continue
        removed.append(user_id)
    return removed
