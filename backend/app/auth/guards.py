"""Guards that re-read the account after a lock was taken.

``get_current_user`` checks the account once, when a request starts. A request that is already
past it can then wait on the per-user lock behind an account deletion and proceed against a
``pending_deletion`` account. Every mutating service therefore re-reads the status *after* it has
the lock: under READ COMMITTED that read sees the deletion once it has committed.
"""

from __future__ import annotations

import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.models import User
from app.core.errors import SessionRevoked


async def ensure_owner_active(session: AsyncSession, user_id: uuid.UUID) -> None:
    """Raise :class:`SessionRevoked` unless the account is active (and exists)."""
    status = (
        await session.execute(select(User.status).where(User.id == user_id))
    ).scalar_one_or_none()
    if status != "active":
        raise SessionRevoked
