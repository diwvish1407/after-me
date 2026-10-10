"""SQL for the check-in configuration and check-in events. Every method is scoped by
``owner_id`` (ARCHITECTURE §4.3)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.checkins.models import CheckinConfiguration, CheckinEvent


class CheckinConfigRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(
        self, *, owner_id: uuid.UUID, for_update: bool = False
    ) -> CheckinConfiguration | None:
        """``for_update`` takes THE per-user lock (ESCALATION_ENGINE §6.2): the connection's
        ``lock_timeout`` turns a long wait into a retryable ``503``."""
        stmt = select(CheckinConfiguration).where(CheckinConfiguration.user_id == owner_id)
        if for_update:
            stmt = stmt.with_for_update().execution_options(populate_existing=True)
        return (await self._session.execute(stmt)).scalar_one_or_none()


class CheckinEventRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def find_by_key(self, *, owner_id: uuid.UUID, key: str) -> CheckinEvent | None:
        stmt = select(CheckinEvent).where(
            CheckinEvent.user_id == owner_id, CheckinEvent.idempotency_key == key
        )
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def add(
        self,
        *,
        event_id: uuid.UUID,
        owner_id: uuid.UUID,
        kind: str,
        source: str,
        received_at: datetime,
        client_reported_at: datetime | None,
        idempotency_key: str,
        session_id: uuid.UUID | None,
        device_id: uuid.UUID | None,
        response_snapshot: dict[str, Any],
        incident_id: uuid.UUID | None = None,
    ) -> CheckinEvent:
        event = CheckinEvent(
            id=event_id,
            user_id=owner_id,
            kind=kind,
            source=source,
            received_at=received_at,
            client_reported_at=client_reported_at,
            idempotency_key=idempotency_key,
            session_id=session_id,
            device_id=device_id,
            incident_id=incident_id,
            response_snapshot=response_snapshot,
        )
        self._session.add(event)
        await self._session.flush()
        return event

    async def page(
        self,
        *,
        owner_id: uuid.UUID,
        limit: int,
        after: tuple[datetime, uuid.UUID] | None = None,
    ) -> list[CheckinEvent]:
        """Newest first. Returns up to ``limit`` rows (callers ask for one more to know whether
        another page exists)."""
        stmt = select(CheckinEvent).where(CheckinEvent.user_id == owner_id)
        if after is not None:
            stmt = stmt.where(tuple_(CheckinEvent.received_at, CheckinEvent.id) < tuple_(*after))
        stmt = stmt.order_by(CheckinEvent.received_at.desc(), CheckinEvent.id.desc()).limit(limit)
        return list((await self._session.execute(stmt)).scalars())
