"""The plan's view of instruction releases.

The plan must know which stages carry releases: they may not move earlier than the release
minimum, and cannot be removed while an instruction is assigned. The catalog answers from
``instruction_recipients``; a stage that holds even an *inactive* instruction is still in use
(activating it later must not find the stage gone or too early).
"""

from __future__ import annotations

import uuid
from typing import Protocol

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.instructions.models import Instruction, InstructionRecipient


class ReleaseCatalog(Protocol):
    async def instructions_by_stage(
        self, session: AsyncSession, *, owner_id: uuid.UUID
    ) -> dict[uuid.UUID, list[uuid.UUID]]:
        """Stage ID -> IDs of the instructions assigned to be released at that stage."""
        ...

    async def active_by_stage(
        self, session: AsyncSession, *, owner_id: uuid.UUID
    ) -> dict[uuid.UUID, list[uuid.UUID]]:
        """The same, only the instructions that would actually be released (active)."""
        ...


class NoReleases:
    """For tests of the plan in isolation: no instruction is assigned anywhere."""

    async def instructions_by_stage(
        self, session: AsyncSession, *, owner_id: uuid.UUID
    ) -> dict[uuid.UUID, list[uuid.UUID]]:
        return {}

    async def active_by_stage(
        self, session: AsyncSession, *, owner_id: uuid.UUID
    ) -> dict[uuid.UUID, list[uuid.UUID]]:
        return {}


class InstructionCatalog:
    async def instructions_by_stage(
        self, session: AsyncSession, *, owner_id: uuid.UUID
    ) -> dict[uuid.UUID, list[uuid.UUID]]:
        return await self._grouped(session, owner_id, active_only=False)

    async def active_by_stage(
        self, session: AsyncSession, *, owner_id: uuid.UUID
    ) -> dict[uuid.UUID, list[uuid.UUID]]:
        return await self._grouped(session, owner_id, active_only=True)

    @staticmethod
    async def _grouped(
        session: AsyncSession, owner_id: uuid.UUID, *, active_only: bool
    ) -> dict[uuid.UUID, list[uuid.UUID]]:
        stmt = (
            select(InstructionRecipient.release_step_id, InstructionRecipient.instruction_id)
            .join(Instruction, Instruction.id == InstructionRecipient.instruction_id)
            .where(
                InstructionRecipient.user_id == owner_id,
                Instruction.user_id == owner_id,
                Instruction.deleted_at.is_(None),
            )
            .order_by(InstructionRecipient.release_step_id, InstructionRecipient.instruction_id)
        )
        if active_only:
            stmt = stmt.where(Instruction.status == "active")
        grouped: dict[uuid.UUID, list[uuid.UUID]] = {}
        for step_id, instruction_id in (await session.execute(stmt)).all():
            ids = grouped.setdefault(step_id, [])
            if instruction_id not in ids:
                ids.append(instruction_id)
        return grouped
