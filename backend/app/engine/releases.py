"""The seam between the engine and instruction releases (ESCALATION_ENGINE §5.4, §6.5, G8).

At opening the snapshot records, per stage, which instruction goes to which contact
(:meth:`planned`); at execution gate G8 re-validates each one against live data
(:meth:`still_valid`). The engine never reads instruction *content*: the worker role has no
SELECT on ``instructions.content_ciphertext``, so every query here names its columns.
"""

from __future__ import annotations

import uuid
from typing import Protocol

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.incidents.snapshot import SnapshotRelease
from app.instructions.models import Instruction, InstructionRecipient
from app.plans.models import EscalationPlan, EscalationStep


class ReleaseSource(Protocol):
    async def planned(
        self, session: AsyncSession, *, user_id: uuid.UUID, step_ids: list[uuid.UUID]
    ) -> dict[uuid.UUID, list[SnapshotRelease]]:
        """Stage ID -> the releases planned at that stage (for the snapshot at opening)."""
        ...

    async def still_valid(
        self,
        session: AsyncSession,
        *,
        user_id: uuid.UUID,
        release: SnapshotRelease,
        step_id: uuid.UUID,
    ) -> str | None:
        """G8: ``None`` when this release may still happen at this stage, else a reason code."""
        ...


class NoReleases:
    """Nothing is ever released. Used by tests that exercise the engine without instructions."""

    async def planned(
        self, session: AsyncSession, *, user_id: uuid.UUID, step_ids: list[uuid.UUID]
    ) -> dict[uuid.UUID, list[SnapshotRelease]]:
        return {}

    async def still_valid(
        self,
        session: AsyncSession,
        *,
        user_id: uuid.UUID,
        release: SnapshotRelease,
        step_id: uuid.UUID,
    ) -> str | None:
        return "instructions_unavailable"


class InstructionReleases:
    """Releases backed by ``instructions`` and ``instruction_recipients``."""

    async def planned(
        self, session: AsyncSession, *, user_id: uuid.UUID, step_ids: list[uuid.UUID]
    ) -> dict[uuid.UUID, list[SnapshotRelease]]:
        if not step_ids:
            return {}
        stmt = (
            select(
                InstructionRecipient.release_step_id,
                InstructionRecipient.instruction_id,
                InstructionRecipient.contact_id,
            )
            .join(Instruction, Instruction.id == InstructionRecipient.instruction_id)
            .where(
                InstructionRecipient.user_id == user_id,
                InstructionRecipient.release_step_id.in_(step_ids),
                Instruction.user_id == user_id,
                Instruction.status == "active",
                Instruction.deleted_at.is_(None),
            )
            .order_by(
                InstructionRecipient.release_step_id,
                InstructionRecipient.contact_id,
                InstructionRecipient.instruction_id,
            )
        )
        planned: dict[uuid.UUID, list[SnapshotRelease]] = {}
        for step_id, instruction_id, contact_id in (await session.execute(stmt)).all():
            planned.setdefault(step_id, []).append(SnapshotRelease(instruction_id, contact_id))
        return planned

    async def still_valid(
        self,
        session: AsyncSession,
        *,
        user_id: uuid.UUID,
        release: SnapshotRelease,
        step_id: uuid.UUID,
    ) -> str | None:
        """G8: the instruction is the owner's, not deleted and active, and the recipient
        mapping still exists with this stage (the contact's own validity is G7)."""
        row = (
            await session.execute(
                select(Instruction.status, Instruction.deleted_at).where(
                    Instruction.id == release.instruction_id, Instruction.user_id == user_id
                )
            )
        ).first()
        if row is None:
            return "instruction_not_found"
        if row.deleted_at is not None:
            return "instruction_deleted"
        if row.status != "active":
            return "instruction_inactive"
        release_step_id = await _release_step_for(session, user_id=user_id, step_id=step_id)
        if release_step_id is None:
            return "recipient_removed"
        mapped = (
            await session.execute(
                select(InstructionRecipient.id).where(
                    InstructionRecipient.instruction_id == release.instruction_id,
                    InstructionRecipient.contact_id == release.contact_id,
                    InstructionRecipient.release_step_id == release_step_id,
                    InstructionRecipient.user_id == user_id,
                )
            )
        ).first()
        return None if mapped is not None else "recipient_removed"


async def _release_step_for(
    session: AsyncSession, *, user_id: uuid.UUID, step_id: uuid.UUID
) -> uuid.UUID | None:
    """Instructions are mapped to stages of the default plan. For a stage of an event's own
    plan, that is the default plan's stage at the same position (as at opening, opener.py)."""
    row = (
        await session.execute(
            select(EscalationStep.position, EscalationPlan.slot_id)
            .join(EscalationPlan, EscalationPlan.id == EscalationStep.plan_id)
            .where(EscalationStep.id == step_id, EscalationStep.user_id == user_id)
        )
    ).first()
    if row is None:
        return step_id  # the stage is gone: the mapping check below reports it
    if row.slot_id is None:
        return step_id
    return (
        await session.execute(
            select(EscalationStep.id)
            .join(EscalationPlan, EscalationPlan.id == EscalationStep.plan_id)
            .where(
                EscalationPlan.user_id == user_id,
                EscalationPlan.slot_id.is_(None),
                EscalationStep.position == row.position,
            )
        )
    ).scalar_one_or_none()
