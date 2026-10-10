"""Writing to the notification outbox (ESCALATION_ENGINE §8; DATABASE §3.8).

Every external effect is a row here, written in the same transaction as the state change that
caused it, and sent later by the dispatcher, which re-checks state before sending. A dedupe key
makes enqueueing idempotent: running the engine twice on the same state adds nothing (INV-5).
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Final

from sqlalchemy import update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.notifications.models import Notification

# Template keys. The copy lives in the dispatcher's renderer; the row carries identifiers only.
USER_PRE_REMINDER: Final = "checkin_pre_reminder"
USER_MISSED: Final = "incident_missed"
USER_MIDPOINT: Final = "incident_midpoint"
USER_LAST_CHANCE: Final = "incident_last_chance"
USER_STAGE_EXECUTED: Final = "stage_executed"
USER_FINAL_WARNING: Final = "release_final_warning"
USER_ALL_CLEAR: Final = "all_clear_confirmation"
USER_HOLD_NOTICE: Final = "service_interruption"
CONTACT_ALERT: Final = "contact_alert"
CONTACT_ALL_CLEAR: Final = "contact_all_clear"

# Which channels each user-facing template uses (USER_FLOWS §6, ESCALATION_ENGINE §5.3).
USER_CHANNELS: Final[dict[str, tuple[str, ...]]] = {
    USER_PRE_REMINDER: ("push", "email"),
    USER_MISSED: ("push", "email"),
    USER_MIDPOINT: ("push",),
    USER_LAST_CHANCE: ("push", "email"),
    USER_STAGE_EXECUTED: ("push", "email"),
    USER_FINAL_WARNING: ("push", "email"),
    USER_ALL_CLEAR: ("push", "email"),
    USER_HOLD_NOTICE: ("push", "email"),
}

CATEGORY_USER: Final = "user"
CATEGORY_ESCALATION: Final = "contact_escalation"
CATEGORY_CONTACT_OTHER: Final = "contact_other"


@dataclass(frozen=True)
class Draft:
    """One message to enqueue. ``params`` may hold IDs, counts and instants, nothing else."""

    user_id: uuid.UUID
    audience: str
    category: str
    channel: str
    template_key: str
    send_after: datetime
    dedupe_key: str
    contact_id: uuid.UUID | None = None
    device_id: uuid.UUID | None = None
    incident_id: uuid.UUID | None = None
    action_id: uuid.UUID | None = None
    params: dict[str, Any] = field(default_factory=dict)


async def enqueue(session: AsyncSession, drafts: list[Draft], *, now: datetime) -> int:
    """Insert the drafts that are not already queued; returns how many were new."""
    inserted = 0
    for draft in drafts:
        stmt = (
            insert(Notification)
            .values(
                user_id=draft.user_id,
                audience=draft.audience,
                category=draft.category,
                contact_id=draft.contact_id,
                device_id=draft.device_id,
                channel=draft.channel,
                template_key=draft.template_key,
                params=draft.params,
                incident_id=draft.incident_id,
                action_id=draft.action_id,
                send_after=draft.send_after,
                dedupe_key=draft.dedupe_key,
                created_at=now,
                updated_at=now,
            )
            .on_conflict_do_nothing(index_elements=[Notification.dedupe_key])
            .returning(Notification.id)
        )
        if (await session.execute(stmt)).scalar_one_or_none() is not None:
            inserted += 1
    return inserted


async def cancel_queued(
    session: AsyncSession,
    *,
    incident_id: uuid.UUID,
    categories: tuple[str, ...],
    reason: str,
    now: datetime,
) -> int:
    """Cancel an incident's messages that have not been handed to a provider. Uses only the
    columns the API role may update (``status``, ``cancelled_reason``, ``updated_at``)."""
    result = await session.execute(
        update(Notification)
        .where(
            Notification.incident_id == incident_id,
            Notification.category.in_(categories),
            Notification.status == "queued",
        )
        .values(status="cancelled", cancelled_reason=reason, updated_at=now)
        .returning(Notification.id)
    )
    return len(result.all())


async def cancel_for_contact(
    session: AsyncSession, *, owner_id: uuid.UUID, contact_id: uuid.UUID, reason: str, now: datetime
) -> int:
    """Cancel everything still queued for one of the owner's contacts (they were removed). The
    dispatcher re-checks the contact anyway; this keeps the queue honest."""
    result = await session.execute(
        update(Notification)
        .where(
            Notification.user_id == owner_id,
            Notification.contact_id == contact_id,
            Notification.status == "queued",
        )
        .values(status="cancelled", cancelled_reason=reason, updated_at=now)
        .returning(Notification.id)
    )
    return len(result.all())
