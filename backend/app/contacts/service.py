"""Trusted contacts for the signed-in user (API_SPEC §7; PRD CON-*).

Transaction discipline follows :class:`app.auth.account_service.AccountService`: the request
transaction commits before any email is sent, and the emails are returned to the router, which
sends them after the response so delivery time cannot tell a suppressed address from any other.
Rate-limit counters live in independent transactions and are never taken before the checks that
decide whether the request is valid, so rejected requests do not burn the daily budgets.

Suppression (the global list): a suppressed address behaves exactly like any other for the
caller. The contact is created, the same limits are counted, the same response is returned; only
the email, the invitation row and the ``contact.invitation_sent`` audit record are skipped.
"""

from __future__ import annotations

import uuid
from dataclasses import replace
from datetime import datetime
from typing import Final

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.api.deps import CurrentUser, RequestContext, has_fresh_reauth
from app.audit import writer as audit
from app.auth.base import AuthServiceBase
from app.auth.guards import ensure_owner_active
from app.checkins.repository import CheckinConfigRepository
from app.contacts.models import PRIORITY_MAX, TrustedContact
from app.contacts.repository import ContactRepository, SuppressionRepository
from app.contacts.schemas import (
    ContactCreateRequest,
    ContactList,
    ContactOut,
    ContactPatchRequest,
)
from app.contacts.tokens import (
    INVITATION_TTL,
    hash_invitation_token,
    invitation_link,
    new_invitation_token,
    new_optout_token,
    optout_link,
    suppression_hash_candidates,
)
from app.core.errors import (
    CannotBeOwnEmail,
    ContactDuplicate,
    InvalidState,
    NotFound,
    PlanLimitReached,
    ReauthRequired,
    SessionRevoked,
    ValidationFailed,
)
from app.instructions.repository import InstructionRepository
from app.notifications import outbox
from app.notifications.email import EmailMessage
from app.notifications.mailer import EmailTemplate
from app.plans.repository import PlanRepository
from app.releases.repository import ReleaseRepository
from app.security.rate_limit import (
    CONTACT_CREATE_PER_USER,
    INVITATION_PER_USER,
    INVITATION_RESEND_PER_CONTACT,
    RateLimit,
)
from app.users.entitlements import limits_for

_DUPLICATE_INDEX: Final = "uq_trusted_contacts_user_email"
RESENDABLE_STATUSES: Final = frozenset({"pending", "bounced"})

# Field names in ``contact.updated`` audit records (short reason codes, never values).
_AUDIT_FIELD: Final = {
    "display_name": "name",
    "relationship": "relationship",
    "relationship_label": "label",
    "email": "email",
    "phone_e164": "phone",
    "priority": "priority",
    "is_active": "active",
}


def contact_out(
    contact: TrustedContact, *, stages: list[int] | None = None, instructions: int = 0
) -> ContactOut:
    assert contact.email is not None  # noqa: S101 - live contacts always carry an address
    return ContactOut(
        id=contact.id,
        display_name=contact.display_name,
        relationship=contact.relationship,  # type: ignore[arg-type]
        relationship_label=contact.relationship_label,
        email=contact.email,
        phone_e164=contact.phone_e164,
        priority=contact.priority,
        verification_status=contact.verification_status,  # type: ignore[arg-type]
        verified_at=contact.verified_at,
        is_active=contact.is_active,
        invitation_sent_at=contact.invitation_sent_at,
        invitation_send_count=contact.invitation_send_count,
        notified_at_stages=stages or [],
        receives_instructions=instructions,
        created_at=contact.created_at,
        updated_at=contact.updated_at,
    )


def _is_duplicate_violation(exc: IntegrityError) -> bool:
    diag = getattr(exc.orig, "diag", None)
    return getattr(diag, "constraint_name", None) == _DUPLICATE_INDEX


class ContactService(AuthServiceBase):
    def __init__(
        self, *, session: AsyncSession, services: AppServices, ctx: RequestContext
    ) -> None:
        super().__init__(session=session, services=services, ctx=ctx)
        self.contacts = ContactRepository(self.session)
        self.suppression = SuppressionRepository(self.session)

    # ------------------------------------------------------------------ reads

    async def list_contacts(self, current: CurrentUser) -> ContactList:
        rows = await self.contacts.list(owner_id=current.user_id)
        stages, counts = await self._links(current)
        await self.session.commit()
        return ContactList(
            items=[
                contact_out(c, stages=stages.get(c.id), instructions=counts.get(c.id, 0))
                for c in rows
            ]
        )

    async def get_contact(self, current: CurrentUser, contact_id: uuid.UUID) -> ContactOut:
        contact = await self.contacts.get(owner_id=current.user_id, contact_id=contact_id)
        if contact is None:
            raise NotFound
        stages, counts = await self._links(current)
        await self.session.commit()
        return contact_out(
            contact, stages=stages.get(contact.id), instructions=counts.get(contact.id, 0)
        )

    async def _links(
        self, current: CurrentUser
    ) -> tuple[dict[uuid.UUID, list[int]], dict[uuid.UUID, int]]:
        """What each contact is part of: the stages that notify them, and how many active
        instructions are assigned to them."""
        stages = await PlanRepository(self.session).stage_positions_by_contact(
            owner_id=current.user_id
        )
        counts = await InstructionRepository(self.session).counts_by_contact(
            owner_id=current.user_id
        )
        return stages, counts

    # ------------------------------------------------------------------ create

    async def create(
        self, current: CurrentUser, body: ContactCreateRequest
    ) -> tuple[ContactOut, list[EmailMessage]]:
        now = await self._now()
        # Serialise this user's creates: the count below and the insert must not interleave with
        # another create, or two requests could both pass a limit of one.
        user = await self.users.get(current.user_id, for_update=True)
        if user is None or user.status != "active":
            raise SessionRevoked  # closed while this request waited for the lock
        email = body.email_normalized
        await self._check_address(user.email_normalized, current.user_id, email)
        limit = limits_for(user.tier).contacts
        live = await self.contacts.count_live(owner_id=current.user_id)
        if live >= limit:
            raise PlanLimitReached(resource="contacts", limit=limit, current=live)
        await self._limit_many(
            [
                (CONTACT_CREATE_PER_USER, str(current.user_id)),
                (INVITATION_PER_USER, str(current.user_id)),
            ],
            now,
        )

        priority = body.priority
        if priority is None:
            priority = min(
                await self.contacts.max_priority(owner_id=current.user_id) + 1, PRIORITY_MAX
            )
        try:
            contact = await self.contacts.create(
                owner_id=current.user_id,
                display_name=body.display_name,
                relationship=body.relationship,
                relationship_label=body.relationship_label,
                email=email,
                phone_e164=body.phone_e164,
                priority=priority,
                now=now,
            )
        except IntegrityError as exc:
            if _is_duplicate_violation(exc):
                raise ContactDuplicate from None
            raise  # pragma: no cover - no other constraint can fail here
        await self.services.audit.record(
            self.session,
            self._event(
                audit.CONTACT_CREATED,
                now,
                current.user_id,
                resource_type="contact",
                resource_id=contact.id,
            ),
        )
        outbox = await self._invite(current, user.email, contact, now)
        await self.session.commit()
        return contact_out(contact), outbox

    # ------------------------------------------------------------------ update

    async def update(
        self, current: CurrentUser, contact_id: uuid.UUID, body: ContactPatchRequest
    ) -> tuple[ContactOut, list[EmailMessage]]:
        now = await self._now()
        contact = await self.contacts.get(
            owner_id=current.user_id, contact_id=contact_id, for_update=True
        )
        if contact is None:
            raise NotFound
        await ensure_owner_active(self.session, current.user_id)
        changes = self._effective_changes(contact, body.changes())
        changed = sorted(name for name, value in changes.items() if getattr(contact, name) != value)
        if not changed:
            stages, counts = await self._links(current)
            await self.session.commit()
            return contact_out(
                contact, stages=stages.get(contact.id), instructions=counts.get(contact.id, 0)
            ), []

        email_changed = "email" in changed
        user_email = ""
        if email_changed:
            user = await self.users.get(current.user_id)
            if user is None:  # pragma: no cover - the session check already loaded this user
                raise SessionRevoked
            user_email = user.email
            new_email = str(changes["email"])
            await self._check_address(
                user.email_normalized, current.user_id, new_email, except_contact_id=contact.id
            )
        if email_changed or changes.get("is_active") is False:
            # Taking a contact out of the safety net (or pointing it at another address, which
            # starts again from "pending") is what a thief with a stolen token would do first.
            # Asked after ownership and validation, and before anything is spent or changed.
            await self._lock_user(current)
            await self._require_step_up(current, contact, now)
        if email_changed:
            # An email change sends a new invitation: it counts against the daily budget, and
            # nothing may change if the budget is used up.
            await self._limit_many([(INVITATION_PER_USER, str(current.user_id))], now)

        for name in changed:
            setattr(contact, name, changes[name])
        contact.updated_at = now
        if email_changed:
            contact.email_normalized = contact.email
            # The new address starts from scratch: nothing of the old answer carries over.
            contact.verification_status = "pending"
            contact.verified_at = None
            contact.status_changed_at = now
            contact.invitation_sent_at = None
            contact.invitation_send_count = 0
        try:
            # The unique index is the final arbiter of duplicates (a concurrent edit may have
            # taken the address since the check above).
            await self.session.flush()
        except IntegrityError as exc:
            if _is_duplicate_violation(exc):
                raise ContactDuplicate from None
            raise  # pragma: no cover - no other constraint can fail here
        if email_changed:
            await self.contacts.invalidate_invitations(
                owner_id=current.user_id, contact_id=contact.id, now=now
            )
        await self.services.audit.record(
            self.session,
            self._event(
                audit.CONTACT_UPDATED,
                now,
                current.user_id,
                resource_type="contact",
                resource_id=contact.id,
                fields=".".join(_AUDIT_FIELD[name] for name in changed),
            ),
        )
        outbox = await self._invite(current, user_email, contact, now) if email_changed else []
        stages, counts = await self._links(current)
        await self.session.commit()
        return (
            contact_out(
                contact, stages=stages.get(contact.id), instructions=counts.get(contact.id, 0)
            ),
            outbox,
        )

    async def _lock_user(self, current: CurrentUser) -> None:
        """THE per-user lock (ESCALATION_ENGINE §6.2), taken before a change that decides who is
        told or who receives what, so the engine sees it wholly before or wholly after."""
        await CheckinConfigRepository(self.session).get(owner_id=current.user_id, for_update=True)
        await ensure_owner_active(self.session, current.user_id)

    async def _require_step_up(
        self, current: CurrentUser, contact: TrustedContact, now: datetime
    ) -> None:
        """A fresh password (SECURITY §7) is needed to take a contact **who would be told** out
        of a safety net that is on. Contacts in no stage, and any change while the schedule is
        off (onboarding), need nothing more: they cannot make anyone miss an alert. Ownership and
        validation were answered before this is asked (a stranger still gets 404)."""
        config = await CheckinConfigRepository(self.session).get(owner_id=current.user_id)
        if config is None or config.status == "inactive":
            return
        routed = await PlanRepository(self.session).contact_in_plan(
            owner_id=current.user_id, contact_id=contact.id
        ) or await InstructionRepository(self.session).is_recipient(
            owner_id=current.user_id, contact_id=contact.id
        )  # told by a stage, or the recipient of something that is to be released
        if routed and not has_fresh_reauth(current, now):
            raise ReauthRequired

    @staticmethod
    def _effective_changes(
        contact: TrustedContact, changes: dict[str, object]
    ) -> dict[str, object]:
        """The requested changes plus the rule that a description belongs to ``other`` only."""
        relationship = changes.get("relationship", contact.relationship)
        effective = dict(changes)
        if relationship != "other":
            if effective.get("relationship_label") is not None:
                raise ValidationFailed(
                    [
                        {
                            "field": "relationship_label",
                            "code": "label_not_allowed",
                            "message": "A description is only allowed when the relationship is "
                            "Other.",
                        }
                    ]
                )
            if contact.relationship_label is not None or "relationship_label" in effective:
                effective["relationship_label"] = None
        return effective

    # ------------------------------------------------------------------ delete

    async def delete(self, current: CurrentUser, contact_id: uuid.UUID) -> None:
        now = await self._now()
        contact = await self.contacts.get(
            owner_id=current.user_id, contact_id=contact_id, for_update=True
        )
        if contact is None:
            raise NotFound
        await self._lock_user(current)
        await self._require_step_up(current, contact, now)
        await self.contacts.invalidate_invitations(
            owner_id=current.user_id, contact_id=contact.id, now=now
        )
        # The contact leaves every stage (an empty stage is allowed and simply does nothing).
        # An open incident is narrowed by the engine's gate G7, which re-reads the contact.
        plans = PlanRepository(self.session)
        if await plans.remove_contact(owner_id=current.user_id, contact_id=contact.id):
            await plans.bump_version(owner_id=current.user_id, now=now)
        # ... and is nobody's recipient any more; what was released to them in an open
        # incident is taken back (ESCALATION_ENGINE §10).
        await InstructionRepository(self.session).remove_contact(
            owner_id=current.user_id, contact_id=contact.id
        )
        await ReleaseRepository(self.session).revoke_for_contact(
            owner_id=current.user_id, contact_id=contact.id, reason="contact_removed", now=now
        )
        await outbox.cancel_for_contact(
            self.session,
            owner_id=current.user_id,
            contact_id=contact.id,
            reason="contact_removed",
            now=now,
        )
        if not await self.contacts.soft_delete(
            owner_id=current.user_id, contact_id=contact.id, now=now
        ):  # pragma: no cover - the row is locked
            raise NotFound
        await self.services.audit.record(
            self.session,
            self._event(
                audit.CONTACT_DELETED,
                now,
                current.user_id,
                resource_type="contact",
                resource_id=contact.id,
                user_visible=True,
            ),
        )
        await self.session.commit()

    # ------------------------------------------------------------------ resend

    async def resend_invitation(
        self, current: CurrentUser, contact_id: uuid.UUID
    ) -> list[EmailMessage]:
        now = await self._now()
        contact = await self.contacts.get(
            owner_id=current.user_id, contact_id=contact_id, for_update=True
        )
        if contact is None:
            raise NotFound
        if contact.verification_status not in RESENDABLE_STATUSES:
            raise InvalidState("This contact has already answered and cannot be invited again.")
        await ensure_owner_active(self.session, current.user_id)
        user = await self.users.get(current.user_id)
        if user is None:  # pragma: no cover - the session check already loaded this user
            raise SessionRevoked
        await self._limit_many(
            [
                (INVITATION_RESEND_PER_CONTACT, str(contact.id)),
                (INVITATION_PER_USER, str(current.user_id)),
            ],
            now,
        )
        await self.contacts.invalidate_invitations(
            owner_id=current.user_id, contact_id=contact.id, now=now
        )
        outbox = await self._invite(current, user.email, contact, now)
        contact.updated_at = now
        await self.session.commit()
        return outbox

    # ------------------------------------------------------------------ helpers

    async def _limit_many(self, rules: list[tuple[RateLimit, str]], now: datetime) -> None:
        result = await self.services.limiter.enforce(rules, now=now)
        self.ctx.note_rate_limit(result)

    async def _check_address(
        self,
        own_email_normalized: str,
        owner_id: uuid.UUID,
        email: str,
        *,
        except_contact_id: uuid.UUID | None = None,
    ) -> None:
        if email == own_email_normalized:
            raise CannotBeOwnEmail
        if await self.contacts.email_in_use(
            owner_id=owner_id, email_normalized=email, except_contact_id=except_contact_id
        ):
            raise ContactDuplicate

    async def _invite(
        self, current: CurrentUser, owner_email: str, contact: TrustedContact, now: datetime
    ) -> list[EmailMessage]:
        """Issue an invitation unless the address is suppressed. Both branches do the same work
        (token, hashing, rendering, one INSERT); a suppressed address just writes nothing and
        records nothing the owner could read."""
        assert contact.email_normalized is not None  # noqa: S101 - live contact
        suppressed = await self.suppression.is_suppressed(
            suppression_hash_candidates(self.services.pepper, contact.email_normalized)
        )
        token = new_invitation_token()
        message = self.services.mailer.render(
            EmailTemplate.CONTACT_INVITATION,
            to=contact.email or contact.email_normalized,
            contact_name=contact.display_name,
            inviter_name=await self._display_name(current.user_id),
            inviter_email=owner_email,
            accept_link=invitation_link(self.settings.public_base_url, token),
            optout_link=optout_link(
                self.settings.public_base_url,
                new_optout_token(self.services.pepper, contact.id, contact.email_normalized),
            ),
            expires_days=int(INVITATION_TTL.days),
            support_url=f"{self.settings.public_base_url}/support",
        )
        message = replace(message, contact_id=contact.id, owner_id=current.user_id)
        await self.contacts.add_invitation(
            owner_id=current.user_id,
            contact_id=contact.id,
            token_hash=hash_invitation_token(token),
            expires_at=now + INVITATION_TTL,
            now=now,
            decoy=suppressed,
        )
        if suppressed:
            return []
        contact.invitation_sent_at = now
        contact.invitation_send_count += 1
        await self.services.audit.record(
            self.session,
            self._event(
                audit.CONTACT_INVITATION_SENT,
                now,
                current.user_id,
                resource_type="contact",
                resource_id=contact.id,
                user_visible=True,
                send_count=contact.invitation_send_count,
            ),
        )
        return [message]
