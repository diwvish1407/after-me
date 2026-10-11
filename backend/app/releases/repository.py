"""Releases and portal access: creation (engine) and revocation, views (API).

Revocation is one way and idempotent. Rows are never deleted: a revoked release keeps its
reason, so the portal can say "no longer available" and the owner can see what happened.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import func, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.contacts.models import TrustedContact
from app.plans.models import EscalationStep
from app.releases.models import PortalAccess, ReleaseEvent


class ReleaseRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    # ------------------------------------------------------------------ revocation

    async def _revoke(self, *conditions: object, reason: str, now: datetime) -> list[uuid.UUID]:
        result = await self._session.execute(
            update(ReleaseEvent)
            .where(ReleaseEvent.revoked_at.is_(None), *conditions)  # type: ignore[arg-type]
            .values(revoked_at=now, revoke_reason=reason)
            .returning(ReleaseEvent.id)
        )
        return [row[0] for row in result.all()]

    async def revoke_for_incident(
        self, *, owner_id: uuid.UUID, incident_id: uuid.UUID, reason: str, now: datetime
    ) -> int:
        """Everything of this incident: its releases and every portal access."""
        revoked = await self._revoke(
            ReleaseEvent.user_id == owner_id,
            ReleaseEvent.incident_id == incident_id,
            reason=reason,
            now=now,
        )
        await self._session.execute(
            update(PortalAccess)
            .where(
                PortalAccess.user_id == owner_id,
                PortalAccess.incident_id == incident_id,
                PortalAccess.revoked_at.is_(None),
            )
            .values(revoked_at=now)
        )
        return len(revoked)

    async def revoke_for_instruction(
        self, *, owner_id: uuid.UUID, instruction_id: uuid.UUID, reason: str, now: datetime
    ) -> int:
        revoked = await self._revoke(
            ReleaseEvent.user_id == owner_id,
            ReleaseEvent.instruction_id == instruction_id,
            reason=reason,
            now=now,
        )
        return len(revoked)

    async def revoke_for_recipient(
        self,
        *,
        owner_id: uuid.UUID,
        instruction_id: uuid.UUID,
        contact_ids: set[uuid.UUID],
        reason: str,
        now: datetime,
    ) -> int:
        if not contact_ids:
            return 0
        revoked = await self._revoke(
            ReleaseEvent.user_id == owner_id,
            ReleaseEvent.instruction_id == instruction_id,
            ReleaseEvent.contact_id.in_(contact_ids),
            reason=reason,
            now=now,
        )
        return len(revoked)

    async def revoke_for_contact(
        self, *, owner_id: uuid.UUID, contact_id: uuid.UUID, reason: str, now: datetime
    ) -> int:
        """All of a contact's releases and portal access, in every incident."""
        revoked = await self._revoke(
            ReleaseEvent.user_id == owner_id,
            ReleaseEvent.contact_id == contact_id,
            reason=reason,
            now=now,
        )
        await self._session.execute(
            update(PortalAccess)
            .where(
                PortalAccess.user_id == owner_id,
                PortalAccess.contact_id == contact_id,
                PortalAccess.revoked_at.is_(None),
            )
            .values(revoked_at=now)
        )
        return len(revoked)

    async def revoke_for_owner(self, *, owner_id: uuid.UUID, reason: str, now: datetime) -> int:
        """Everything this account ever released, and every portal access (account deletion)."""
        revoked = await self._revoke(ReleaseEvent.user_id == owner_id, reason=reason, now=now)
        await self._session.execute(
            update(PortalAccess)
            .where(PortalAccess.user_id == owner_id, PortalAccess.revoked_at.is_(None))
            .values(revoked_at=now)
        )
        return len(revoked)

    # ------------------------------------------------------------------ the engine's side

    async def create(
        self,
        *,
        owner_id: uuid.UUID,
        incident_id: uuid.UUID,
        action_id: uuid.UUID,
        instruction_id: uuid.UUID,
        contact_id: uuid.UUID,
        step_id: uuid.UUID,
        released_at: datetime,
        visible_after: datetime,
    ) -> bool:
        """Record one release. Returns ``True`` when it is new or was taken back by a Hold
        rollback (the stage ran again). A release that was revoked for any other reason stays
        revoked: nothing the engine does can make it visible again."""
        stmt = (
            insert(ReleaseEvent)
            .values(
                user_id=owner_id,
                incident_id=incident_id,
                action_id=action_id,
                instruction_id=instruction_id,
                contact_id=contact_id,
                step_id=step_id,
                released_at=released_at,
                visible_after=visible_after,
            )
            .on_conflict_do_update(
                constraint="uq_release_events_release",
                set_={
                    "action_id": action_id,
                    "step_id": step_id,
                    "released_at": released_at,
                    "visible_after": visible_after,
                    "revoked_at": None,
                    "revoke_reason": None,
                },
                where=ReleaseEvent.revoke_reason == "hold_rollback",
            )
            .returning(ReleaseEvent.id)
        )
        return (await self._session.execute(stmt)).first() is not None

    async def ensure_access(
        self, *, owner_id: uuid.UUID, incident_id: uuid.UUID, contact_id: uuid.UUID
    ) -> uuid.UUID:
        await self._session.execute(
            insert(PortalAccess)
            .values(user_id=owner_id, incident_id=incident_id, contact_id=contact_id)
            .on_conflict_do_nothing(constraint="uq_portal_access_incident_contact")
        )
        row = (
            await self._session.execute(
                select(PortalAccess.id).where(
                    PortalAccess.incident_id == incident_id, PortalAccess.contact_id == contact_id
                )
            )
        ).scalar_one()
        return row

    async def for_owner_view(
        self, *, owner_id: uuid.UUID, incident_id: uuid.UUID
    ) -> list[tuple[ReleaseEvent, str, int | None]]:
        """The incident's releases for its owner: the event, the contact's display name and the
        stage position, oldest first. (The title is opened by the caller, for the owner.)"""
        stmt = (
            select(ReleaseEvent, TrustedContact.display_name, EscalationStep.position)
            .join(TrustedContact, TrustedContact.id == ReleaseEvent.contact_id)
            .outerjoin(EscalationStep, EscalationStep.id == ReleaseEvent.step_id)
            .where(ReleaseEvent.user_id == owner_id, ReleaseEvent.incident_id == incident_id)
            .order_by(ReleaseEvent.released_at, ReleaseEvent.id)
        )
        return [(row[0], row[1], row[2]) for row in (await self._session.execute(stmt)).all()]

    async def live_counts_for_action(
        self, *, owner_id: uuid.UUID, action_id: uuid.UUID
    ) -> dict[uuid.UUID, int]:
        """Contact -> releases of this stage run that are in force (not revoked). The recorded
        row, not the attempt to record it: a release revoked for a real reason stays revoked."""
        stmt = (
            select(ReleaseEvent.contact_id, func.count())
            .where(
                ReleaseEvent.user_id == owner_id,
                ReleaseEvent.action_id == action_id,
                ReleaseEvent.revoked_at.is_(None),
            )
            .group_by(ReleaseEvent.contact_id)
        )
        return {row[0]: int(row[1]) for row in (await self._session.execute(stmt)).all()}

    async def rollback_action(
        self, *, owner_id: uuid.UUID, action_id: uuid.UUID, now: datetime
    ) -> int:
        """A Hold took the stage back: its releases never happened."""
        revoked = await self._revoke(
            ReleaseEvent.user_id == owner_id,
            ReleaseEvent.action_id == action_id,
            reason="hold_rollback",
            now=now,
        )
        return len(revoked)
