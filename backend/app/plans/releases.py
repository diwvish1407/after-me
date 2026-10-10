"""The seam between the plan and instruction releases (arrive in Phase 6).

The plan must know which stages carry releases (they may not move earlier than the release
minimum, and cannot be removed while in use). Instructions do not exist until Phase 6, so this
phase installs an implementation that reports none; Phase 6 replaces it with a query over
``instruction_recipients``. Nothing else in the plan code needs to change.
"""

from __future__ import annotations

import uuid
from typing import Protocol

from sqlalchemy.ext.asyncio import AsyncSession


class ReleaseCatalog(Protocol):
    async def instructions_by_stage(
        self, session: AsyncSession, *, owner_id: uuid.UUID
    ) -> dict[uuid.UUID, list[uuid.UUID]]:
        """Stage ID -> IDs of the active instructions released at that stage."""
        ...


class NoReleases:
    """Phase 5: no instruction exists, so no stage carries a release."""

    async def instructions_by_stage(
        self, session: AsyncSession, *, owner_id: uuid.UUID
    ) -> dict[uuid.UUID, list[uuid.UUID]]:
        return {}
