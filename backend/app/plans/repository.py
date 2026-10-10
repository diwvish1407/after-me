"""SQL for the escalation plan. Every method is scoped by ``owner_id`` (ARCHITECTURE §4.3)."""

from __future__ import annotations

import uuid
from collections import defaultdict
from datetime import datetime

from sqlalchemy import delete, func, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.plans.models import EscalationPlan, EscalationStep, EscalationStepContact


class PlanRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def ensure(self, *, owner_id: uuid.UUID, now: datetime) -> None:
        """Create the user's (empty) plan if it does not exist yet. Idempotent."""
        await self._session.execute(
            insert(EscalationPlan)
            .values(user_id=owner_id, created_at=now, updated_at=now)
            .on_conflict_do_nothing(index_elements=[EscalationPlan.user_id])
        )

    async def get(self, *, owner_id: uuid.UUID, for_update: bool = False) -> EscalationPlan | None:
        stmt = select(EscalationPlan).where(EscalationPlan.user_id == owner_id)
        if for_update:
            stmt = stmt.with_for_update().execution_options(populate_existing=True)
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def steps(self, *, owner_id: uuid.UUID, plan_id: uuid.UUID) -> list[EscalationStep]:
        stmt = (
            select(EscalationStep)
            .where(EscalationStep.user_id == owner_id, EscalationStep.plan_id == plan_id)
            .order_by(EscalationStep.position)
        )
        return list((await self._session.execute(stmt)).scalars())

    async def contacts_by_step(
        self, *, owner_id: uuid.UUID, plan_id: uuid.UUID
    ) -> dict[uuid.UUID, list[uuid.UUID]]:
        stmt = (
            select(EscalationStepContact.step_id, EscalationStepContact.contact_id)
            .join(EscalationStep, EscalationStep.id == EscalationStepContact.step_id)
            .where(EscalationStep.user_id == owner_id, EscalationStep.plan_id == plan_id)
            .order_by(EscalationStepContact.step_id, EscalationStepContact.contact_id)
        )
        grouped: dict[uuid.UUID, list[uuid.UUID]] = defaultdict(list)
        for step_id, contact_id in (await self._session.execute(stmt)).all():
            grouped[step_id].append(contact_id)
        return grouped

    async def count_steps(self, *, owner_id: uuid.UUID) -> int:
        stmt = (
            select(func.count())
            .select_from(EscalationStep)
            .where(EscalationStep.user_id == owner_id)
        )
        return int((await self._session.execute(stmt)).scalar_one())

    async def delete_steps(self, *, owner_id: uuid.UUID, step_ids: list[uuid.UUID]) -> None:
        if step_ids:
            await self._session.execute(
                delete(EscalationStep).where(
                    EscalationStep.user_id == owner_id, EscalationStep.id.in_(step_ids)
                )
            )

    async def add_step(
        self,
        *,
        owner_id: uuid.UUID,
        plan_id: uuid.UUID,
        position: int,
        offset_minutes: int,
        now: datetime,
    ) -> EscalationStep:
        step = EscalationStep(
            user_id=owner_id,
            plan_id=plan_id,
            position=position,
            offset_minutes=offset_minutes,
            created_at=now,
            updated_at=now,
        )
        self._session.add(step)
        await self._session.flush()
        return step

    async def set_step_contacts(
        self, *, owner_id: uuid.UUID, step_id: uuid.UUID, contact_ids: list[uuid.UUID]
    ) -> None:
        await self._session.execute(
            delete(EscalationStepContact).where(
                EscalationStepContact.user_id == owner_id,
                EscalationStepContact.step_id == step_id,
            )
        )
        for contact_id in contact_ids:
            self._session.add(
                EscalationStepContact(step_id=step_id, contact_id=contact_id, user_id=owner_id)
            )
        await self._session.flush()

    async def bump_version(self, *, owner_id: uuid.UUID, now: datetime) -> None:
        """A plan content change made outside a plan edit (a contact was removed from stages):
        a client that is editing must see a new ETag and not silently re-add the contact."""
        await self._session.execute(
            update(EscalationPlan)
            .where(EscalationPlan.user_id == owner_id)
            .values(version=EscalationPlan.version + 1, updated_at=now)
        )

    async def stage_contacts(
        self, *, owner_id: uuid.UUID
    ) -> list[tuple[uuid.UUID, uuid.UUID | None]]:
        """``(step_id, contact_id | None)`` for every stage; ``None`` marks a stage with no
        contact at all. Ordered by position."""
        stmt = (
            select(EscalationStep.id, EscalationStepContact.contact_id)
            .outerjoin(EscalationStepContact, EscalationStepContact.step_id == EscalationStep.id)
            .where(EscalationStep.user_id == owner_id)
            .order_by(EscalationStep.position)
        )
        return [(row[0], row[1]) for row in (await self._session.execute(stmt)).all()]

    async def remove_contact(self, *, owner_id: uuid.UUID, contact_id: uuid.UUID) -> int:
        """Drop a contact from every stage (the contact was deleted). Returns the rows removed."""
        result = await self._session.execute(
            delete(EscalationStepContact)
            .where(
                EscalationStepContact.user_id == owner_id,
                EscalationStepContact.contact_id == contact_id,
            )
            .returning(EscalationStepContact.step_id)
        )
        return len(result.all())
