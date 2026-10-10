"""Tier limits and usage (PRD FR-INS-08; API_SPEC §3 ``GET /me/entitlements``).

The server is the only place that enforces limits; the app merely mirrors them.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Final

from app.api.deps import CurrentUser
from app.auth.base import AuthServiceBase
from app.contacts.repository import ContactRepository
from app.instructions.repository import InstructionRepository
from app.plans.repository import PlanRepository
from app.users.schemas import EntitlementLimits, EntitlementsResponse, EntitlementUsage


@dataclass(frozen=True)
class TierLimits:
    contacts: int
    instructions: int
    stages: int
    custom_offsets: bool


TIER_LIMITS: Final[dict[str, TierLimits]] = {
    "free": TierLimits(contacts=1, instructions=3, stages=2, custom_offsets=False),
    "premium": TierLimits(contacts=25, instructions=200, stages=10, custom_offsets=True),
}


def limits_for(tier: str) -> TierLimits:
    """Unknown tiers get the free limits: failing closed never grants more than was paid for."""
    return TIER_LIMITS.get(tier, TIER_LIMITS["free"])


class EntitlementService(AuthServiceBase):
    async def entitlements(self, current: CurrentUser) -> EntitlementsResponse:
        limits = limits_for(current.tier)
        contacts = await ContactRepository(self.session).count_live(owner_id=current.user_id)
        stages = await PlanRepository(self.session).count_steps(owner_id=current.user_id)
        instructions = await InstructionRepository(self.session).count_live(
            owner_id=current.user_id
        )
        await self.session.commit()
        return EntitlementsResponse(
            tier=current.tier,
            limits=EntitlementLimits(
                contacts=limits.contacts,
                instructions=limits.instructions,
                stages=limits.stages,
                custom_offsets=limits.custom_offsets,
            ),
            usage=EntitlementUsage(contacts=contacts, instructions=instructions, stages=stages),
        )
