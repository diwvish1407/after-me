"""Owner-scoped instruction queries (API_SPEC §10). Every query filters by ``user_id``."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import ColumnElement, delete, func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.contacts.models import TrustedContact
from app.instructions.models import Instruction, InstructionCategory, InstructionRecipient
from app.plans.models import EscalationStep


@dataclass(frozen=True)
class RecipientRow:
    instruction_id: uuid.UUID
    contact_id: uuid.UUID
    display_name: str
    release_step_id: uuid.UUID
    stage_position: int


class InstructionRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    # ------------------------------------------------------------------ categories

    async def categories(self) -> list[InstructionCategory]:
        stmt = (
            select(InstructionCategory)
            .where(InstructionCategory.is_active.is_(True))
            .order_by(InstructionCategory.sort_order)
        )
        return list((await self._session.execute(stmt)).scalars())

    async def category_exists(self, category_id: str) -> bool:
        stmt = select(
            select(InstructionCategory.id)
            .where(InstructionCategory.id == category_id, InstructionCategory.is_active.is_(True))
            .exists()
        )
        return bool((await self._session.execute(stmt)).scalar_one())

    # ------------------------------------------------------------------ instructions

    @staticmethod
    def _live(owner_id: uuid.UUID) -> tuple[ColumnElement[bool], ...]:
        return (Instruction.user_id == owner_id, Instruction.deleted_at.is_(None))

    async def count_live(self, *, owner_id: uuid.UUID) -> int:
        stmt = select(func.count()).select_from(Instruction).where(*self._live(owner_id))
        return int((await self._session.execute(stmt)).scalar_one())

    async def count_active(self, *, owner_id: uuid.UUID) -> int:
        stmt = (
            select(func.count())
            .select_from(Instruction)
            .where(*self._live(owner_id), Instruction.status == "active")
        )
        return int((await self._session.execute(stmt)).scalar_one())

    async def list_live(self, *, owner_id: uuid.UUID, category: str | None) -> list[Instruction]:
        stmt = select(Instruction).where(*self._live(owner_id))
        if category is not None:
            stmt = stmt.where(Instruction.category_id == category)
        stmt = stmt.order_by(Instruction.updated_at.desc(), Instruction.id)
        return list((await self._session.execute(stmt)).scalars())

    async def get(
        self, *, owner_id: uuid.UUID, instruction_id: uuid.UUID, for_update: bool = False
    ) -> Instruction | None:
        stmt = select(Instruction).where(
            Instruction.id == instruction_id,
            *self._live(owner_id),
        )
        if for_update:
            stmt = stmt.with_for_update().execution_options(populate_existing=True)
        return (await self._session.execute(stmt)).scalar_one_or_none()

    def add(self, instruction: Instruction) -> None:
        self._session.add(instruction)

    # ------------------------------------------------------------------ recipients

    async def recipients(
        self, *, owner_id: uuid.UUID, instruction_ids: list[uuid.UUID]
    ) -> list[RecipientRow]:
        if not instruction_ids:
            return []
        stmt = (
            select(
                InstructionRecipient.instruction_id,
                InstructionRecipient.contact_id,
                TrustedContact.display_name,
                InstructionRecipient.release_step_id,
                EscalationStep.position,
            )
            .join(TrustedContact, TrustedContact.id == InstructionRecipient.contact_id)
            .join(EscalationStep, EscalationStep.id == InstructionRecipient.release_step_id)
            .where(
                InstructionRecipient.user_id == owner_id,
                InstructionRecipient.instruction_id.in_(instruction_ids),
                TrustedContact.deleted_at.is_(None),
            )
            .order_by(EscalationStep.position, TrustedContact.display_name, TrustedContact.id)
        )
        return [RecipientRow(*row) for row in (await self._session.execute(stmt)).all()]

    async def replace_recipients(
        self,
        *,
        owner_id: uuid.UUID,
        instruction_id: uuid.UUID,
        wanted: dict[uuid.UUID, uuid.UUID],
        now: datetime,
    ) -> tuple[set[uuid.UUID], set[uuid.UUID]]:
        """Make the recipients exactly ``wanted`` (contact → stage). Returns the contacts whose
        mapping was removed or moved (their open releases are revoked) and those added."""
        current_rows = (
            await self._session.execute(
                select(InstructionRecipient).where(
                    InstructionRecipient.user_id == owner_id,
                    InstructionRecipient.instruction_id == instruction_id,
                )
            )
        ).scalars()
        current = {r.contact_id: r for r in current_rows}
        removed: set[uuid.UUID] = set()
        added: set[uuid.UUID] = set()
        for contact_id, row in current.items():
            if contact_id not in wanted:
                await self._session.delete(row)
                removed.add(contact_id)
            elif row.release_step_id != wanted[contact_id]:
                row.release_step_id = wanted[contact_id]
                row.updated_at = now
                removed.add(contact_id)  # a different stage is a different release
        for contact_id, step_id in wanted.items():
            if contact_id not in current:
                self._session.add(
                    InstructionRecipient(
                        instruction_id=instruction_id,
                        contact_id=contact_id,
                        release_step_id=step_id,
                        user_id=owner_id,
                    )
                )
                added.add(contact_id)
        await self._session.flush()
        return removed, added

    async def counts_by_contact(self, *, owner_id: uuid.UUID) -> dict[uuid.UUID, int]:
        """Contact -> how many active instructions are assigned to them."""
        stmt = (
            select(InstructionRecipient.contact_id, func.count())
            .join(Instruction, Instruction.id == InstructionRecipient.instruction_id)
            .where(
                InstructionRecipient.user_id == owner_id,
                Instruction.deleted_at.is_(None),
                Instruction.status == "active",
            )
            .group_by(InstructionRecipient.contact_id)
        )
        return {row[0]: int(row[1]) for row in (await self._session.execute(stmt)).all()}

    async def is_recipient(self, *, owner_id: uuid.UUID, contact_id: uuid.UUID) -> bool:
        """Whether an active instruction is assigned to this contact."""
        stmt = select(
            select(InstructionRecipient.id)
            .join(Instruction, Instruction.id == InstructionRecipient.instruction_id)
            .where(
                InstructionRecipient.user_id == owner_id,
                InstructionRecipient.contact_id == contact_id,
                Instruction.deleted_at.is_(None),
                Instruction.status == "active",
            )
            .exists()
        )
        return bool((await self._session.execute(stmt)).scalar_one())

    async def remove_contact(self, *, owner_id: uuid.UUID, contact_id: uuid.UUID) -> int:
        """The contact was deleted: it receives nothing any more. Returns the rows removed."""
        result = await self._session.execute(
            delete(InstructionRecipient)
            .where(
                InstructionRecipient.user_id == owner_id,
                InstructionRecipient.contact_id == contact_id,
            )
            .returning(InstructionRecipient.id)
        )
        return len(result.all())

    async def clear_recipients(self, *, owner_id: uuid.UUID, instruction_id: uuid.UUID) -> None:
        await self._session.execute(
            delete(InstructionRecipient).where(
                InstructionRecipient.user_id == owner_id,
                InstructionRecipient.instruction_id == instruction_id,
            )
        )

    async def wipe_all(self, *, owner_id: uuid.UUID, now: datetime) -> int:
        """Account deletion: no instruction of this owner keeps its content or its recipients.
        The rows stay (releases and the incident history refer to them) until the account is
        purged. Returns the number of instructions wiped."""
        await self._session.execute(
            delete(InstructionRecipient).where(InstructionRecipient.user_id == owner_id)
        )
        result = await self._session.execute(
            update(Instruction)
            .where(Instruction.user_id == owner_id, Instruction.deleted_at.is_(None))
            .values(content_ciphertext=None, status="inactive", deleted_at=now, updated_at=now)
            .returning(Instruction.id)
        )
        return len(result.all())
