"""Owner-scoped SQL for incidents on the API side (ARCHITECTURE §4.3).

The API role can read incidents and *stop* them; it can never create one (INV-1, DATABASE §6).
Updates here use only the columns that role is granted.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import or_, select, tuple_, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.incidents.models import OPEN_STATUSES, EscalationIncident, IncidentAction
from app.notifications.models import Notification


class IncidentRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get_open(
        self, *, owner_id: uuid.UUID, for_update: bool = False
    ) -> EscalationIncident | None:
        stmt = select(EscalationIncident).where(
            EscalationIncident.user_id == owner_id, EscalationIncident.status.in_(OPEN_STATUSES)
        )
        if for_update:
            stmt = stmt.with_for_update().execution_options(populate_existing=True)
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def get(
        self, *, owner_id: uuid.UUID, incident_id: uuid.UUID, for_update: bool = False
    ) -> EscalationIncident | None:
        stmt = select(EscalationIncident).where(
            EscalationIncident.id == incident_id, EscalationIncident.user_id == owner_id
        )
        if for_update:
            stmt = stmt.with_for_update().execution_options(populate_existing=True)
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def page(
        self,
        *,
        owner_id: uuid.UUID,
        limit: int,
        after: tuple[datetime, uuid.UUID] | None = None,
    ) -> list[EscalationIncident]:
        stmt = select(EscalationIncident).where(EscalationIncident.user_id == owner_id)
        if after is not None:
            stmt = stmt.where(
                tuple_(EscalationIncident.opened_at, EscalationIncident.id) < tuple_(*after)
            )
        stmt = stmt.order_by(EscalationIncident.opened_at.desc(), EscalationIncident.id.desc())
        return list((await self._session.execute(stmt.limit(limit))).scalars())

    async def actions(self, *, owner_id: uuid.UUID, incident_id: uuid.UUID) -> list[IncidentAction]:
        stmt = (
            select(IncidentAction)
            .where(IncidentAction.incident_id == incident_id, IncidentAction.user_id == owner_id)
            .order_by(IncidentAction.scheduled_for, IncidentAction.kind, IncidentAction.id)
        )
        return list((await self._session.execute(stmt)).scalars())

    async def close(
        self,
        *,
        owner_id: uuid.UUID,
        incident_id: uuid.UUID,
        status: str,
        closed_by: str,
        now: datetime,
    ) -> None:
        await self._session.execute(
            update(EscalationIncident)
            .where(EscalationIncident.id == incident_id, EscalationIncident.user_id == owner_id)
            .values(status=status, closed_at=now, closed_by=closed_by, updated_at=now)
        )

    async def cancel_pending_actions(
        self, *, owner_id: uuid.UUID, incident_id: uuid.UUID, now: datetime
    ) -> int:
        result = await self._session.execute(
            update(IncidentAction)
            .where(
                IncidentAction.incident_id == incident_id,
                IncidentAction.user_id == owner_id,
                IncidentAction.status == "pending",
            )
            .values(status="cancelled", updated_at=now)
            .returning(IncidentAction.id)
        )
        return len(result.all())

    async def messaged_contact_ids(
        self, *, owner_id: uuid.UUID, incident_id: uuid.UUID
    ) -> list[uuid.UUID]:
        """Contacts who may have received an escalation message: it was handed to a provider
        (``sending``, ``sent``), or an attempt was made and ended without a clear answer
        (a timeout leaves a row ``queued`` with ``attempt_count > 0``, or ``failed``). The
        provider may well have delivered it; they are owed an all-clear (§9.2). A contact whose
        message was never attempted is not, and is never told anything."""
        stmt = (
            select(Notification.contact_id)
            .where(
                Notification.user_id == owner_id,
                Notification.incident_id == incident_id,
                Notification.category == "contact_escalation",
                or_(
                    Notification.status.in_(("sending", "sent", "failed")),
                    Notification.attempt_count > 0,
                ),
                Notification.contact_id.is_not(None),
            )
            .distinct()
            .order_by(Notification.contact_id)
        )
        return [r[0] for r in (await self._session.execute(stmt)).all() if r[0] is not None]
