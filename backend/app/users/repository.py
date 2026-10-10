"""SQL for user profiles. Every method is scoped by ``owner_id``."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.users.models import UserProfile


class ProfileRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, *, owner_id: uuid.UUID, for_update: bool = False) -> UserProfile | None:
        stmt = select(UserProfile).where(UserProfile.user_id == owner_id)
        if for_update:
            stmt = stmt.with_for_update().execution_options(populate_existing=True)
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def upsert(
        self,
        *,
        owner_id: uuid.UUID,
        display_name: str,
        timezone: str,
        locale: str,
        country_code: str | None,
        now: datetime,
    ) -> None:
        values = {
            "display_name": display_name,
            "timezone": timezone,
            "locale": locale,
            "country_code": country_code,
            "updated_at": now,
        }
        stmt = (
            insert(UserProfile)
            .values(user_id=owner_id, created_at=now, **values)
            .on_conflict_do_update(index_elements=[UserProfile.user_id], set_=values)
        )
        await self._session.execute(stmt)
