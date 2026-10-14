"""SQL behind the Home aggregate. Scoped by ``owner_id``."""

from __future__ import annotations

import uuid

from sqlalchemy import exists, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.audit.models import AuditLog
from app.ops.models import SystemHold


class ActivityRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def recent_visible(self, *, owner_id: uuid.UUID, limit: int) -> list[AuditLog]:
        """The newest user-visible audit records about this account (the Activity feed)."""
        stmt = (
            select(AuditLog)
            .where(AuditLog.subject_user_id == owner_id, AuditLog.user_visible.is_(True))
            .order_by(AuditLog.occurred_at.desc(), AuditLog.id.desc())
            .limit(limit)
        )
        return list((await self._session.execute(stmt)).scalars())


async def service_interruption(session: AsyncSession) -> bool:
    """Is a Hold blocking contact-facing work? Same definition as the engine's own (a Hold blocks
    until its exit has been *processed*, not merely ended), written here because the API process
    never imports the engine (INV-1). The API role may read ``system_holds`` and nothing else
    about it."""
    stmt = select(
        exists().where(or_(SystemHold.ended_at.is_(None), SystemHold.exit_processed_at.is_(None)))
    )
    return bool((await session.execute(stmt)).scalar_one())
