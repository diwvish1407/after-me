"""SQL behind the Home aggregate. Scoped by ``owner_id``."""

from __future__ import annotations

import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.audit.models import AuditLog


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
