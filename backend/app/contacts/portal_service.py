"""What a contact can do with their emailed links (API_SPEC §13.1; USER_FLOWS §12).

There is no contact session: every step presents the token again in a POST body. Nothing here
changes state unless a method says so, and every unusable token (malformed, unknown, expired,
answered, forged, or its contact gone or no longer invitable) raises the same
:class:`LinkInvalid`, which the web layer renders as one generic page.

Lock order is contact row first, then its invitations, everywhere (owner-side operations lock the
contact before touching invitations too), so concurrent answers and edits cannot deadlock.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Literal

from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.api.deps import RequestContext
from app.audit import writer as audit
from app.contacts.repository import (
    OptedOutContact,
    PortalContact,
    PortalRepository,
    SuppressionRepository,
)
from app.contacts.service import RESENDABLE_STATUSES
from app.contacts.tokens import (
    hash_invitation_token,
    looks_like_invitation_token,
    optout_token_contact_id,
    suppression_hash,
    verify_optout_token,
)
from app.notifications.email import EmailMessage
from app.notifications.mailer import EmailTemplate

OptOutScope = Literal["this_person", "everyone"]


class LinkInvalid(Exception):  # noqa: N818 - domain signal, rendered as a generic page
    """The token cannot be used. Deliberately carries no reason."""


@dataclass(frozen=True)
class InvitationView:
    inviter_name: str
    inviter_email: str
    contact_name: str


@dataclass(frozen=True)
class OptOutView:
    inviter_name: str


@dataclass(frozen=True)
class OptOutResult:
    scope: OptOutScope
    inviter_name: str


class ContactPortalService:
    def __init__(
        self, *, session: AsyncSession, services: AppServices, ctx: RequestContext
    ) -> None:
        self.session = session
        self.services = services
        self.ctx = ctx
        self.portal = PortalRepository(session)
        self.suppression = SuppressionRepository(session)

    # ------------------------------------------------------------------ helpers

    async def _now(self) -> datetime:
        return await self.services.clock.now(self.session)

    def _event(
        self,
        action: str,
        now: datetime,
        *,
        owner_id: uuid.UUID,
        contact_id: uuid.UUID,
        **metadata: str | int | bool | None,
    ) -> audit.AuditEvent:
        """The contact acts, the account holder is the subject (and sees it in their feed)."""
        return audit.AuditEvent(
            action=action,
            occurred_at=now,
            subject_user_id=owner_id,
            actor_type="contact",
            actor_id=contact_id,
            resource_type="contact",
            resource_id=contact_id,
            request_id=self.ctx.request_id,
            ip_hash=self.ctx.ip_hash,
            metadata=dict(metadata),
        )

    def _notice(self, template: EmailTemplate, *, to: str, contact_name: str) -> EmailMessage:
        return self.services.mailer.render(template, to=to, contact_name=contact_name)

    async def _commit_and_send(self, outbox: list[EmailMessage]) -> None:
        await self.session.commit()
        await self.services.mailer.deliver(outbox)

    async def _lock_contact(
        self, contact_id: uuid.UUID, *, lock_address: bool, seen: PortalContact
    ) -> PortalContact:
        """Lock the contact row for the rest of the transaction, after the address lock when the
        request may block the address everywhere (lock order: address, then contact rows; see
        :meth:`SuppressionRepository.lock_address`). ``seen`` is the unlocked read that named the
        address; if the account holder changed or deleted it in between, the link is unusable."""
        address = seen.contact.email_normalized
        if lock_address and address is not None:
            await self.suppression.lock_address(suppression_hash(self.services.pepper, address))
        found = await self.portal.get_contact(contact_id, for_update=True)
        if found is None or found.contact.email_normalized != address:
            raise LinkInvalid
        return found

    async def _invitable_contact(
        self, token: str, now: datetime, *, for_update: bool, lock_address: bool = False
    ) -> tuple[bytes, PortalContact]:
        """Resolve an invitation token to its contact, or raise :class:`LinkInvalid`."""
        if not looks_like_invitation_token(token):
            raise LinkInvalid
        token_hash = hash_invitation_token(token)
        invitation = await self.portal.find_invitation(token_hash)
        if invitation is None:
            raise LinkInvalid
        found = await self.portal.get_contact(invitation.contact_id)
        if found is None:
            raise LinkInvalid
        if for_update:
            found = await self._lock_contact(
                invitation.contact_id, lock_address=lock_address, seen=found
            )
        # Re-read the invitation under the contact lock: an owner-side change that ran first
        # (resend, email change, delete) has already invalidated it.
        current = await self.portal.find_invitation(token_hash)
        if (
            current is None
            or current.responded_at is not None
            or current.expires_at <= now
            or found.contact.verification_status not in RESENDABLE_STATUSES
        ):
            raise LinkInvalid
        return token_hash, found

    # ------------------------------------------------------------------ invitation

    async def open_invitation(self, token: str) -> InvitationView:
        """Show the invitation. Changes nothing."""
        now = await self._now()
        _, found = await self._invitable_contact(token, now, for_update=False)
        await self.session.commit()
        return InvitationView(
            inviter_name=found.owner_name,
            inviter_email=found.owner_email,
            contact_name=found.contact.display_name,
        )

    async def accept(self, token: str) -> InvitationView:
        now = await self._now()
        token_hash, found = await self._invitable_contact(token, now, for_update=True)
        if not await self.portal.answer_invitation(
            token_hash=token_hash, response="accepted", ip_hash=self.ctx.ip_hash, now=now
        ):
            raise LinkInvalid
        contact = found.contact
        contact.verification_status = "verified"
        contact.verified_at = now
        contact.status_changed_at = now
        contact.updated_at = now
        await self.services.audit.record(
            self.session,
            self._event(
                audit.CONTACT_ACCEPTED,
                now,
                owner_id=found.owner_id,
                contact_id=contact.id,
            ),
        )
        await self._commit_and_send(
            [
                self._notice(
                    EmailTemplate.CONTACT_ACCEPTED,
                    to=found.owner_email,
                    contact_name=contact.display_name,
                )
            ]
        )
        return InvitationView(found.owner_name, found.owner_email, contact.display_name)

    async def decline(self, token: str, *, never_contact: bool) -> InvitationView:
        now = await self._now()
        token_hash, found = await self._invitable_contact(
            token, now, for_update=True, lock_address=never_contact
        )
        if not await self.portal.answer_invitation(
            token_hash=token_hash, response="declined", ip_hash=self.ctx.ip_hash, now=now
        ):
            raise LinkInvalid
        contact = found.contact
        contact.verification_status = "declined"
        contact.verified_at = None
        contact.status_changed_at = now
        contact.updated_at = now
        await self.portal.invalidate_invitations(contact.id, now=now)
        await self.services.audit.record(
            self.session,
            self._event(
                audit.CONTACT_DECLINED,
                now,
                owner_id=found.owner_id,
                contact_id=contact.id,
                never_contact=never_contact,
            ),
        )
        outbox = [
            self._notice(
                EmailTemplate.CONTACT_DECLINED,
                to=found.owner_email,
                contact_name=contact.display_name,
            )
        ]
        if never_contact:
            assert contact.email_normalized is not None  # noqa: S101 - a live contact has one
            outbox += await self._block_everywhere(
                contact.email_normalized,
                source_contact_id=contact.id,
                now=now,
                except_contact_id=contact.id,
            )
        await self._commit_and_send(outbox)
        return InvitationView(found.owner_name, found.owner_email, contact.display_name)

    # ------------------------------------------------------------------ opt-out

    async def _optout_contact(
        self, token: str, *, for_update: bool, lock_address: bool = False
    ) -> PortalContact:
        """The contact an opt-out link was issued for, while it still holds the address the link
        was issued for (the MAC covers both)."""
        contact_id = optout_token_contact_id(token)
        if contact_id is None:
            raise LinkInvalid
        found = await self.portal.get_contact(contact_id)
        address = None if found is None else found.contact.email_normalized
        if found is None or address is None:
            raise LinkInvalid
        if verify_optout_token(self.services.pepper, token, email_normalized=address) is None:
            raise LinkInvalid
        if for_update:
            found = await self._lock_contact(contact_id, lock_address=lock_address, seen=found)
        return found

    async def optout_preview(self, token: str) -> OptOutView:
        """Show the two choices. Changes nothing."""
        found = await self._optout_contact(token, for_update=False)
        await self.session.commit()
        return OptOutView(inviter_name=found.owner_name)

    async def opt_out(self, token: str, scope: str) -> OptOutResult:
        if scope == "everyone":
            chosen: OptOutScope = "everyone"
        elif scope == "this_person":
            chosen = "this_person"
        else:
            raise LinkInvalid
        now = await self._now()
        found = await self._optout_contact(
            token, for_update=True, lock_address=chosen == "everyone"
        )
        contact = found.contact
        outbox: list[EmailMessage] = []
        if chosen == "this_person":
            if contact.verification_status != "opted_out":
                outbox += await self._opt_out_one(found, scope="this_person", now=now)
        else:
            assert contact.email_normalized is not None  # noqa: S101 - a live contact has one
            outbox += await self._block_everywhere(
                contact.email_normalized, source_contact_id=contact.id, now=now
            )
        await self._commit_and_send(outbox)
        return OptOutResult(scope=chosen, inviter_name=found.owner_name)

    async def _opt_out_one(
        self, found: PortalContact, *, scope: str, now: datetime
    ) -> list[EmailMessage]:
        contact = found.contact
        contact.verification_status = "opted_out"
        contact.verified_at = None
        contact.status_changed_at = now
        contact.updated_at = now
        await self.portal.invalidate_invitations(contact.id, now=now)
        await self.services.audit.record(
            self.session,
            self._event(
                audit.CONTACT_OPTED_OUT,
                now,
                owner_id=found.owner_id,
                contact_id=contact.id,
                scope=scope,
            ),
        )
        return [
            self._notice(
                EmailTemplate.CONTACT_OPTED_OUT,
                to=found.owner_email,
                contact_name=contact.display_name,
            )
        ]

    async def _block_everywhere(
        self,
        email_normalized: str,
        *,
        source_contact_id: uuid.UUID,
        now: datetime,
        except_contact_id: uuid.UUID | None = None,
    ) -> list[EmailMessage]:
        """Add the address to the global suppression list and opt out every live contact row
        that holds it, whoever owns it. Each affected account holder gets an audit record and a
        notice."""
        await self.suppression.add(
            suppression_hash(self.services.pepper, email_normalized),
            reason="contact_block_all",
            source_contact_id=source_contact_id,
            now=now,
        )
        affected = await self.suppression.opt_out_all_contacts_with_email(
            email_normalized=email_normalized, now=now, except_contact_id=except_contact_id
        )
        outbox: list[EmailMessage] = []
        for row in affected:
            await self._record_opt_out(row, now)
            outbox.append(
                self._notice(
                    EmailTemplate.CONTACT_OPTED_OUT,
                    to=row.owner_email,
                    contact_name=row.contact_name,
                )
            )
        return outbox

    async def _record_opt_out(self, row: OptedOutContact, now: datetime) -> None:
        await self.services.audit.record(
            self.session,
            self._event(
                audit.CONTACT_OPTED_OUT,
                now,
                owner_id=row.owner_id,
                contact_id=row.contact_id,
                scope="everyone",
            ),
        )
