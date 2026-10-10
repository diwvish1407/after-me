"""The seam between the engine and instruction releases (arrive in Phase 6).

At opening the snapshot records, per stage, which instruction goes to which contact; at
execution gate G8 re-validates each one against live data. Instructions do not exist until
Phase 6, so this phase installs an implementation with nothing to release; the rest of the
engine already handles releases (final warnings, G8/G9, the release minimum) and is exercised
with synthetic snapshots in the tests.
"""

from __future__ import annotations

import uuid
from typing import Protocol

from sqlalchemy.ext.asyncio import AsyncSession

from app.incidents.snapshot import SnapshotRelease


class ReleaseSource(Protocol):
    async def planned(
        self, session: AsyncSession, *, user_id: uuid.UUID, step_ids: list[uuid.UUID]
    ) -> dict[uuid.UUID, list[SnapshotRelease]]:
        """Stage ID -> the releases planned at that stage (for the snapshot at opening)."""
        ...

    async def still_valid(
        self, session: AsyncSession, *, user_id: uuid.UUID, release: SnapshotRelease
    ) -> str | None:
        """G8: ``None`` when this release may still happen, else a short reason code."""
        ...


class NoReleases:
    async def planned(
        self, session: AsyncSession, *, user_id: uuid.UUID, step_ids: list[uuid.UUID]
    ) -> dict[uuid.UUID, list[SnapshotRelease]]:
        return {}

    async def still_valid(
        self, session: AsyncSession, *, user_id: uuid.UUID, release: SnapshotRelease
    ) -> str | None:
        return "instructions_unavailable"  # nothing can be released before Phase 6
