"""``GET`` and ``PUT /v1/plan`` (API_SPEC §8; ESCALATION_ENGINE §5.1).

Every change takes the per-user lock first (the ``checkin_configurations`` row) so that a plan
edit, a check-in and a stage execution are serialised for one user (§6.2). The engine reads the
plan only through a snapshot taken when an incident opens, so an edit can never change an
incident that is already running; it is refused with ``409 incident_open`` instead.
"""

from __future__ import annotations

import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.api.deps import CurrentUser, RequestContext, has_fresh_reauth
from app.audit import writer as audit
from app.auth.base import AuthServiceBase
from app.checkins.repository import CheckinConfigRepository
from app.contacts.repository import ContactRepository
from app.core.errors import (
    IncidentOpen,
    NotFound,
    PlanLimitReached,
    PreconditionFailed,
    PreconditionRequired,
    ReauthRequired,
    StageInUse,
    ValidationFailed,
)
from app.plans.models import EscalationPlan, EscalationStep
from app.plans.releases import InstructionCatalog, ReleaseCatalog
from app.plans.repository import PlanRepository
from app.plans.rules import PlanRules, StageDraft, plan_rules, validate_plan
from app.plans.schemas import PlanOut, PlanPutRequest, RulesOut, StageOut
from app.users.entitlements import limits_for


def plan_etag(version: int) -> str:
    """The ``ETag`` of the plan singleton: a strong validator (API_SPEC §1)."""
    return f'"plan-{version}"'


def rules_out(rules: PlanRules) -> RulesOut:
    return RulesOut(
        grace_min=rules.grace_min,
        grace_max=rules.grace_max,
        stage_gap_min=rules.stage_gap_min,
        offset_max=rules.offset_max,
        release_offset_min=rules.release_offset_min,
        max_stages=rules.max_stages,
        custom_offsets=rules.custom_offsets,
        presets=list(rules.presets),
    )


class PlanService(AuthServiceBase):
    def __init__(
        self,
        *,
        session: AsyncSession,
        services: AppServices,
        ctx: RequestContext,
        releases: ReleaseCatalog | None = None,
    ) -> None:
        super().__init__(session=session, services=services, ctx=ctx)
        self.plans = PlanRepository(self.session)
        self.configs = CheckinConfigRepository(self.session)
        self.contacts = ContactRepository(self.session)
        self.releases: ReleaseCatalog = releases or InstructionCatalog()

    # ------------------------------------------------------------------ helpers

    def _rules(self, tier: str) -> PlanRules:
        limits = limits_for(tier)
        return plan_rules(
            self.settings, max_stages=limits.stages, custom_offsets=limits.custom_offsets
        )

    async def _out(self, current: CurrentUser, plan: EscalationPlan) -> PlanOut:
        steps = await self.plans.steps(owner_id=current.user_id, plan_id=plan.id)
        by_step = await self.plans.contacts_by_step(owner_id=current.user_id, plan_id=plan.id)
        released = await self.releases.active_by_stage(self.session, owner_id=current.user_id)
        return PlanOut(
            id=plan.id,
            version=plan.version,
            grace_minutes=plan.grace_minutes,
            stages=[
                StageOut(
                    id=step.id,
                    position=step.position,
                    offset_minutes=step.offset_minutes,
                    notify_contact_ids=by_step.get(step.id, []),
                    release_count=len(released.get(step.id, [])),
                )
                for step in steps
            ],
            rules=rules_out(self._rules(current.tier)),
        )

    # ------------------------------------------------------------------ read

    async def get_plan(self, current: CurrentUser) -> PlanOut:
        now = await self._now()
        plan = await self.plans.get(owner_id=current.user_id)
        if plan is None:  # lazily created: accounts that predate Phase 5, or a lost signup row
            await self.plans.ensure(owner_id=current.user_id, now=now)
            plan = await self.plans.get(owner_id=current.user_id)
        if plan is None:  # pragma: no cover - ensure() just inserted it
            raise NotFound
        out = await self._out(current, plan)
        await self.session.commit()
        return out

    # ------------------------------------------------------------------ replace

    async def put_plan(
        self, current: CurrentUser, if_match: str | None, body: PlanPutRequest
    ) -> PlanOut:
        if if_match is None:
            raise PreconditionRequired
        now = await self._now()
        # The per-user lock first (lock order, ESCALATION_ENGINE §6.2).
        config = await self.configs.get(owner_id=current.user_id, for_update=True)
        if config is None:  # pragma: no cover - created at signup verification
            raise NotFound
        await self.plans.ensure(owner_id=current.user_id, now=now)
        plan = await self.plans.get(owner_id=current.user_id, for_update=True)
        if plan is None:  # pragma: no cover
            raise NotFound
        if if_match != plan_etag(plan.version):
            raise PreconditionFailed
        if config.status == "incident_open":
            raise IncidentOpen

        steps = await self.plans.steps(owner_id=current.user_id, plan_id=plan.id)
        by_step = await self.plans.contacts_by_step(owner_id=current.user_id, plan_id=plan.id)
        existing = {s.id: s for s in steps}
        rules = self._rules(current.tier)

        # Ownership first: a foreign or unknown stage or contact is a 404, as for any resource.
        live = {c.id for c in await self.contacts.list(owner_id=current.user_id)}
        for stage in body.stages:
            if stage.id is not None and stage.id not in existing:
                raise NotFound
            if any(contact_id not in live for contact_id in stage.notify_contact_ids):
                raise NotFound

        assigned = await self.releases.instructions_by_stage(self.session, owner_id=current.user_id)
        drafts = [
            StageDraft(s.id, s.offset_minutes, tuple(s.notify_contact_ids)) for s in body.stages
        ]
        errors = validate_plan(
            grace_minutes=body.grace_minutes,
            stages=drafts,
            rules=rules,
            kept_offsets=frozenset(s.offset_minutes for s in steps),
            release_stage_ids=frozenset(sid for sid, ids in assigned.items() if ids),
        )
        if errors:
            raise ValidationFailed([e.as_dict() for e in errors])
        # The tier limit: an account that was downgraded keeps what it has but cannot add.
        allowed = max(rules.max_stages, len(steps))
        if len(body.stages) > allowed:
            raise PlanLimitReached(
                resource="stages", limit=rules.max_stages, current=len(body.stages)
            )

        kept_ids = {s.id for s in body.stages if s.id is not None}
        removed = [sid for sid in existing if sid not in kept_ids]
        in_use = [iid for sid in removed for iid in assigned.get(sid, [])]
        if in_use:
            raise StageInUse(in_use)

        unchanged = (
            plan.grace_minutes == body.grace_minutes
            and len(steps) == len(body.stages)
            and all(
                s.id == d.id
                and s.offset_minutes == d.offset_minutes
                and sorted(by_step.get(s.id, [])) == sorted(d.notify_contact_ids)
                for s, d in zip(steps, drafts, strict=True)
            )
        )
        if not unchanged:
            # Step-up (review F-12): the plan decides who is told and when, so changing it while
            # the safety net is on needs the password, like turning the net off does. While the
            # schedule is off (onboarding) there is nothing to neutralise yet. A stolen access
            # token alone must not be able to empty the stages.
            if config.status == "active" and not has_fresh_reauth(current, now):
                raise ReauthRequired
            await self._apply(current, plan, body, existing, now)
            plan.version += 1
            plan.updated_at = now
            await self.services.audit.record(
                self.session,
                self._event(
                    audit.PLAN_UPDATED,
                    now,
                    current.user_id,
                    resource_type="plan",
                    resource_id=plan.id,
                    stages=len(body.stages),
                    removed=len(removed),
                ),
            )
        out = await self._out(current, plan)
        await self.session.commit()
        return out

    async def _apply(
        self,
        current: CurrentUser,
        plan: EscalationPlan,
        body: PlanPutRequest,
        existing: dict[uuid.UUID, EscalationStep],
        now: object,
    ) -> None:
        """Replace the plan's stages. Positions follow the request order (offsets are strictly
        increasing, so that is time order); the position and offset uniqueness constraints are
        deferred, so stages can swap places inside this transaction."""
        owner = current.user_id
        kept = {s.id for s in body.stages if s.id is not None}
        await self.plans.delete_steps(
            owner_id=owner, step_ids=[sid for sid in existing if sid not in kept]
        )
        plan.grace_minutes = body.grace_minutes
        for position, stage in enumerate(body.stages, start=1):
            if stage.id is not None:
                step = existing[stage.id]
                step.position = position
                step.offset_minutes = stage.offset_minutes
                step.updated_at = now  # type: ignore[assignment]
            else:
                step = await self.plans.add_step(
                    owner_id=owner,
                    plan_id=plan.id,
                    position=position,
                    offset_minutes=stage.offset_minutes,
                    now=now,  # type: ignore[arg-type]
                )
            await self.plans.set_step_contacts(
                owner_id=owner,
                step_id=step.id,
                contact_ids=sorted(set(stage.notify_contact_ids)),
            )
        await self.session.flush()
