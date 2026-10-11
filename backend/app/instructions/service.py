"""Instructions (API_SPEC §10; SECURITY §6.2; ESCALATION_ENGINE §10).

Content is sealed with the owner's data key before it touches the database, and opened only
here for the owner's own requests (and by the portal for a verified recipient). Anything that
changes who may see an instruction, or whether, takes the per-user lock first and revokes the
releases it makes stale in the same transaction.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.api.deps import CurrentUser, RequestContext, has_fresh_reauth
from app.audit import writer as audit
from app.auth.base import AuthServiceBase
from app.auth.guards import ensure_owner_active
from app.checkins.models import CheckinConfiguration
from app.checkins.repository import CheckinConfigRepository
from app.contacts.repository import ContactRepository
from app.core.errors import NotFound, PlanLimitReached, ReauthRequired, ValidationFailed
from app.instructions.models import Instruction
from app.instructions.repository import InstructionRepository, RecipientRow
from app.instructions.schemas import (
    CategoryList,
    CategoryOut,
    InstructionCreateRequest,
    InstructionList,
    InstructionOut,
    InstructionPatchRequest,
    InstructionSummary,
    RecipientIn,
    RecipientOut,
)
from app.plans.models import EscalationStep
from app.plans.repository import PlanRepository
from app.releases.repository import ReleaseRepository
from app.security.envelope import DecryptionError
from app.security.vault import VaultUnavailableError
from app.users.entitlements import limits_for


class ContentUnavailableError(Exception):
    """The stored content could not be opened (a corrupted or moved ciphertext). Reported as a
    server error; nothing about the content is revealed."""


class InstructionService(AuthServiceBase):
    def __init__(
        self, *, session: AsyncSession, services: AppServices, ctx: RequestContext
    ) -> None:
        super().__init__(session=session, services=services, ctx=ctx)
        self.items = InstructionRepository(self.session)
        self.contacts = ContactRepository(self.session)
        self.plans = PlanRepository(self.session)
        self.releases = ReleaseRepository(self.session)

    # ------------------------------------------------------------------ reads

    async def categories(self) -> CategoryList:
        rows = await self.items.categories()
        await self.session.commit()
        return CategoryList(items=[CategoryOut(id=c.id, sort_order=c.sort_order) for c in rows])

    async def list_instructions(
        self, current: CurrentUser, category: str | None
    ) -> InstructionList:
        rows = await self.items.list_live(owner_id=current.user_id, category=category)
        recipients = await self.items.recipients(
            owner_id=current.user_id, instruction_ids=[r.id for r in rows]
        )
        summaries = [
            await self._summary(row, [r for r in recipients if r.instruction_id == row.id])
            for row in rows
        ]
        await self.services.audit.record(
            self.session,
            self._event(
                audit.INSTRUCTION_VIEWED,
                await self._now(),
                current.user_id,
                resource_type="instruction",
                count=len(rows),
            ),
        )
        await self.session.commit()
        return InstructionList(items=summaries)

    async def get_instruction(
        self, current: CurrentUser, instruction_id: uuid.UUID
    ) -> InstructionOut:
        row = await self.items.get(owner_id=current.user_id, instruction_id=instruction_id)
        if row is None:
            raise NotFound
        out = await self._full(row)
        await self.services.audit.record(
            self.session,
            self._event(
                audit.INSTRUCTION_VIEWED,
                await self._now(),
                current.user_id,
                resource_type="instruction",
                resource_id=row.id,
                count=1,
            ),
        )
        await self.session.commit()
        return out

    # ------------------------------------------------------------------ create

    async def create(self, current: CurrentUser, body: InstructionCreateRequest) -> InstructionOut:
        now = await self._now()
        config = await self._lock(current)
        if not await self.items.category_exists(body.category):
            raise ValidationFailed(
                [{"field": "category", "code": "unknown_category", "message": "Choose a category."}]
            )
        live = await self.items.count_live(owner_id=current.user_id)
        limit = limits_for(current.tier).instructions
        if live >= limit:
            raise PlanLimitReached(resource="instructions", limit=limit, current=live)
        wanted = await self._validate_recipients(current, body.recipients)
        self._step_up(current, config, now, routing=bool(wanted))

        instruction_id = uuid.uuid4()
        ciphertext, key_version = await self._seal(
            current.user_id, instruction_id, body.title, body.body
        )
        row = Instruction(
            id=instruction_id,
            user_id=current.user_id,
            category_id=body.category,
            status=body.status,
            content_ciphertext=ciphertext,
            content_key_version=key_version,
            created_at=now,
            updated_at=now,
        )
        self.items.add(row)
        await self.session.flush()
        await self.items.replace_recipients(
            owner_id=current.user_id, instruction_id=instruction_id, wanted=wanted, now=now
        )
        await self.services.audit.record(
            self.session,
            self._event(
                audit.INSTRUCTION_CREATED,
                now,
                current.user_id,
                resource_type="instruction",
                resource_id=instruction_id,
                category=body.category,
                recipients=len(wanted),
            ),
        )
        out = await self._full(row)
        await self.session.commit()
        return out

    # ------------------------------------------------------------------ update

    async def patch(
        self, current: CurrentUser, instruction_id: uuid.UUID, body: InstructionPatchRequest
    ) -> InstructionOut:
        now = await self._now()
        config = await self._lock(current)
        row = await self.items.get(
            owner_id=current.user_id, instruction_id=instruction_id, for_update=True
        )
        if row is None:
            raise NotFound
        fields = body.model_fields_set
        if "category" in fields and body.category is not None:
            if not await self.items.category_exists(body.category):
                raise ValidationFailed(
                    [
                        {
                            "field": "category",
                            "code": "unknown_category",
                            "message": "Choose a category.",
                        }
                    ]
                )
            row.category_id = body.category
        wanted = (
            await self._validate_recipients(current, body.recipients)
            if "recipients" in fields and body.recipients is not None
            else None
        )

        current_routes = {
            r.contact_id: r.release_step_id
            for r in await self.items.recipients(owner_id=current.user_id, instruction_ids=[row.id])
        }
        switching_off = (
            "status" in fields and body.status == "inactive" and row.status == "active"
        ) and bool(current_routes)
        self._step_up(
            current,
            config,
            now,
            routing=switching_off or (wanted is not None and wanted != current_routes),
        )

        if "title" in fields or "body" in fields:
            title, text = await self._content(row)
            title = body.title if "title" in fields and body.title is not None else title
            text = body.body if "body" in fields and body.body is not None else text
            row.content_ciphertext, row.content_key_version = await self._seal(
                current.user_id, row.id, title, text
            )
            row.content_version += 1

        deactivated = False
        if "status" in fields and body.status is not None:
            deactivated = row.status == "active" and body.status == "inactive"
            row.status = body.status
        row.updated_at = now

        revoked = 0
        if deactivated:
            revoked += await self.releases.revoke_for_instruction(
                owner_id=current.user_id,
                instruction_id=row.id,
                reason="instruction_removed",
                now=now,
            )
        if wanted is not None:
            removed, added = await self.items.replace_recipients(
                owner_id=current.user_id, instruction_id=row.id, wanted=wanted, now=now
            )
            revoked += await self.releases.revoke_for_recipient(
                owner_id=current.user_id,
                instruction_id=row.id,
                contact_ids=removed,
                reason="recipient_removed",
                now=now,
            )
            if removed or added:
                await self.services.audit.record(
                    self.session,
                    self._event(
                        audit.INSTRUCTION_RECIPIENTS_CHANGED,
                        now,
                        current.user_id,
                        resource_type="instruction",
                        resource_id=row.id,
                        added=len(added),
                        removed=len(removed),
                    ),
                )
        await self.services.audit.record(
            self.session,
            self._event(
                audit.INSTRUCTION_UPDATED,
                now,
                current.user_id,
                resource_type="instruction",
                resource_id=row.id,
                fields=".".join(sorted(fields)),
                revoked=revoked,
            ),
        )
        out = await self._full(row)
        await self.session.commit()
        return out

    # ------------------------------------------------------------------ delete

    async def delete(self, current: CurrentUser, instruction_id: uuid.UUID) -> None:
        now = await self._now()
        config = await self._lock(current)
        row = await self.items.get(
            owner_id=current.user_id, instruction_id=instruction_id, for_update=True
        )
        if row is None:
            raise NotFound
        has_routes = bool(
            await self.items.recipients(owner_id=current.user_id, instruction_ids=[row.id])
        )
        self._step_up(current, config, now, routing=has_routes)
        # Content wiped, recipients released (so no stage is held by it), releases of an open
        # incident taken back (ESCALATION_ENGINE §10).
        row.content_ciphertext = None
        row.status = "inactive"
        row.deleted_at = now
        row.updated_at = now
        await self.items.clear_recipients(owner_id=current.user_id, instruction_id=row.id)
        revoked = await self.releases.revoke_for_instruction(
            owner_id=current.user_id, instruction_id=row.id, reason="instruction_removed", now=now
        )
        await self.services.audit.record(
            self.session,
            self._event(
                audit.INSTRUCTION_DELETED,
                now,
                current.user_id,
                resource_type="instruction",
                resource_id=row.id,
                revoked=revoked,
            ),
        )
        await self.session.commit()

    # ------------------------------------------------------------------ helpers

    async def _lock(self, current: CurrentUser) -> CheckinConfiguration:
        """THE per-user lock (ESCALATION_ENGINE §6.2): the engine creates releases under it, so
        a change here is either wholly before a stage runs or wholly after."""
        config = await CheckinConfigRepository(self.session).get(
            owner_id=current.user_id, for_update=True
        )
        if config is None:  # pragma: no cover - created at signup verification
            raise NotFound
        await ensure_owner_active(self.session, current.user_id)
        return config

    @staticmethod
    def _step_up(
        current: CurrentUser, config: CheckinConfiguration, now: datetime, *, routing: bool
    ) -> None:
        """A fresh password (SECURITY §7) is needed to change *who receives* something, to
        switch off or delete an instruction that has recipients, while the safety net is on.
        Editing the text, the category, or switching one on never asks; neither does anything
        while the schedule is off (onboarding)."""
        if routing and config.status != "inactive" and not has_fresh_reauth(current, now):
            raise ReauthRequired

    async def _validate_recipients(
        self, current: CurrentUser, recipients: list[RecipientIn]
    ) -> dict[uuid.UUID, uuid.UUID]:
        """Contact → stage. Ownership first (a foreign ID is a 404, as for any resource), then
        the rules: no duplicates, and a release stage may not be earlier than the minimum."""
        if not recipients:
            return {}
        live = {c.id for c in await self.contacts.list(owner_id=current.user_id)}
        plan = await self.plans.get(owner_id=current.user_id)
        steps: dict[uuid.UUID, EscalationStep] = {}
        if plan is not None:
            steps = {
                s.id: s for s in await self.plans.steps(owner_id=current.user_id, plan_id=plan.id)
            }
        wanted: dict[uuid.UUID, uuid.UUID] = {}
        errors: list[dict[str, str]] = []
        for index, item in enumerate(recipients):
            if item.contact_id not in live or item.release_stage_id not in steps:
                raise NotFound
            if item.contact_id in wanted:
                errors.append(
                    {
                        "field": f"recipients[{index}].contact_id",
                        "code": "duplicate_recipient",
                        "message": "Each person can be chosen once.",
                    }
                )
                continue
            minimum = self.settings.min_release_offset_minutes
            if steps[item.release_stage_id].offset_minutes < minimum:
                errors.append(
                    {
                        "field": f"recipients[{index}].release_stage_id",
                        "code": "release_stage_too_early",
                        "message": "Choose a stage at least 24 hours after the missed check-in.",
                    }
                )
                continue
            wanted[item.contact_id] = item.release_stage_id
        if errors:
            raise ValidationFailed(errors)
        return wanted

    async def _seal(
        self, user_id: uuid.UUID, instruction_id: uuid.UUID, title: str, body: str
    ) -> tuple[bytes, int]:
        try:
            return await self.services.vault.seal(
                self.session,
                user_id=user_id,
                instruction_id=instruction_id,
                title=title,
                body=body,
            )
        except VaultUnavailableError:
            raise ContentUnavailableError from None

    async def _content(self, row: Instruction) -> tuple[str, str]:
        if row.content_ciphertext is None:
            raise ContentUnavailableError
        try:
            return await self.services.vault.open(
                self.session,
                user_id=row.user_id,
                instruction_id=row.id,
                ciphertext=row.content_ciphertext,
                key_version=row.content_key_version,
            )
        except (DecryptionError, VaultUnavailableError):
            raise ContentUnavailableError from None

    async def _summary(
        self, row: Instruction, recipients: list[RecipientRow]
    ) -> InstructionSummary:
        title, _ = await self._content(row)
        return InstructionSummary(
            id=row.id,
            category=row.category_id,
            title=title,
            status=row.status,  # type: ignore[arg-type]
            recipients=[recipient_out(r) for r in recipients],
            updated_at=row.updated_at,
        )

    async def _full(self, row: Instruction) -> InstructionOut:
        title, text = await self._content(row)
        recipients = await self.items.recipients(owner_id=row.user_id, instruction_ids=[row.id])
        return InstructionOut(
            id=row.id,
            category=row.category_id,
            title=title,
            body=text,
            status=row.status,  # type: ignore[arg-type]
            recipients=[recipient_out(r) for r in recipients],
            updated_at=row.updated_at,
            created_at=row.created_at,
        )


def recipient_out(row: RecipientRow) -> RecipientOut:
    return RecipientOut(
        contact_id=row.contact_id,
        display_name=row.display_name,
        release_stage_id=row.release_step_id,
        stage_position=row.stage_position,
    )
