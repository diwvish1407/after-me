"""A contact the person depends on cannot be reached (ESCALATION_ENGINE §8.5; USER_FLOWS §13).

One routine for the four ways it happens, shared by the dispatcher (a provider refused the
address, or a message could not be delivered for a day) and the webhooks (the mailbox bounced,
complained, or the provider reports it could not deliver):

* ``bounced``: a provider **reported** a hard bounce: the address does not exist. It joins the
  global suppression list and every contact row holding it, in every account, becomes
  ``bounced``; each owner is told.
* ``refused``: every provider **refused** the address at send time. Only this contact becomes
  ``bounced`` (and its queued messages are cancelled); the address is *not* suppressed
  globally, because a refusal is one provider's list, not a fact about the mailbox.
* ``complaint``: the recipient marked a message as unwanted. Treated as "never contact me
  again": suppressed everywhere, every contact row with that address is ``opted_out`` and its
  releases are taken back, each owner is told.
* ``undeliverable``: the message was given up on, or the provider reported it could not be
  delivered after its own retries. Nothing about the contact changes (it may have been our
  provider, or a full mailbox); the person is told, because a plan that silently cannot reach
  someone is exactly what this product must not do.

An event about a message that went to an address the contact **no longer has** (the owner fixed
a typo) changes nothing: ``expected_address`` is what the message was sent to.

The person gets a push and an email (``contact_unreachable``); neither names the contact in the
push (a push shows on a locked screen).
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Final

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.audit import writer as audit
from app.audit.writer import AuditEvent
from app.auth.models import Device
from app.contacts.models import TrustedContact
from app.contacts.repository import SuppressionRepository
from app.contacts.tokens import suppression_hash
from app.notifications import outbox
from app.releases.repository import ReleaseRepository

BOUNCED: Final = "bounced"
REFUSED: Final = "refused"
COMPLAINT: Final = "complaint"
UNDELIVERABLE: Final = "undeliverable"


async def contact_unreachable(
    session: AsyncSession,
    services: AppServices,
    *,
    owner_id: uuid.UUID,
    contact_id: uuid.UUID,
    reason: str,
    now: datetime,
    expected_address: str | None = None,
) -> bool:
    """Apply the consequences and queue the notice(s). Returns ``False`` when there was
    nothing to do (the contact is gone, or no longer has the address the message went to)."""
    contact = (
        await session.execute(
            select(TrustedContact).where(
                TrustedContact.id == contact_id,
                TrustedContact.user_id == owner_id,
                TrustedContact.deleted_at.is_(None),
            )
        )
    ).scalar_one_or_none()
    if contact is None:
        return False
    address = contact.email_normalized
    if expected_address is not None and address != expected_address:
        return False  # the owner changed the address since: this is about the old one

    drafts: list[outbox.Draft] = []
    if reason == COMPLAINT and address:
        suppressions = SuppressionRepository(session)
        digest = suppression_hash(services.pepper, address)
        await suppressions.lock_address(digest)
        await suppressions.add(digest, reason="complaint", source_contact_id=contact.id, now=now)
        for item in await suppressions.opt_out_all_contacts_with_email(
            email_normalized=address, now=now
        ):
            await outbox.cancel_for_contact(
                session,
                owner_id=item.owner_id,
                contact_id=item.contact_id,
                reason="contact_unreachable",
                now=now,
            )
            await ReleaseRepository(session).revoke_for_contact(
                owner_id=item.owner_id,
                contact_id=item.contact_id,
                reason="contact_opted_out",
                now=now,
            )
            await _audit(
                services,
                session,
                audit.CONTACT_OPTED_OUT,
                item.owner_id,
                item.contact_id,
                now,
                {"reason": "complaint"},
            )
            drafts += await _notice(session, item.owner_id, item.contact_id, reason, now)
    elif reason == BOUNCED and address:
        suppressions = SuppressionRepository(session)
        digest = suppression_hash(services.pepper, address)
        await suppressions.lock_address(digest)
        await suppressions.add(digest, reason="hard_bounce", source_contact_id=contact.id, now=now)
        for affected_contact, affected_owner in await suppressions.mark_bounced_with_email(
            email_normalized=address, now=now
        ):
            drafts += await _bounced(
                session, services, affected_owner, affected_contact, reason, now
            )
    elif reason == REFUSED:
        changed = await session.execute(
            update(TrustedContact)
            .where(
                TrustedContact.id == contact.id,
                TrustedContact.verification_status.in_(("pending", "verified")),
            )
            .values(verification_status="bounced", status_changed_at=now, updated_at=now)
            .returning(TrustedContact.id)
        )
        if changed.first() is not None:
            drafts += await _bounced(session, services, owner_id, contact.id, reason, now)
    elif reason == UNDELIVERABLE:
        drafts += await _notice(session, owner_id, contact.id, reason, now)
    if drafts:
        await outbox.enqueue(session, drafts, now=now)
    return True


async def _bounced(
    session: AsyncSession,
    services: AppServices,
    owner_id: uuid.UUID,
    contact_id: uuid.UUID,
    reason: str,
    now: datetime,
) -> list[outbox.Draft]:
    await outbox.cancel_for_contact(
        session, owner_id=owner_id, contact_id=contact_id, reason="contact_unreachable", now=now
    )
    await _audit(
        services,
        session,
        audit.CONTACT_BOUNCED,
        owner_id,
        contact_id,
        now,
        {"reason": "hard_bounce" if reason == BOUNCED else "refused"},
    )
    return await _notice(session, owner_id, contact_id, reason, now)


async def _audit(
    services: AppServices,
    session: AsyncSession,
    action: str,
    owner_id: uuid.UUID,
    contact_id: uuid.UUID,
    now: datetime,
    metadata: dict[str, str],
) -> None:
    await services.audit.record(
        session,
        AuditEvent(
            action=action,
            occurred_at=now,
            subject_user_id=owner_id,
            actor_type="system",
            resource_type="contact",
            resource_id=contact_id,
            metadata=dict(metadata),
            user_visible=True,
        ),
    )


async def _notice(
    session: AsyncSession,
    owner_id: uuid.UUID,
    contact_id: uuid.UUID,
    reason: str,
    now: datetime,
) -> list[outbox.Draft]:
    """The push (per device) and the email, once per contact, reason and day."""
    day = now.strftime("%Y%m%d")
    base = f"unreachable:{contact_id}:{reason}:{day}"
    params = {"contact_id": str(contact_id), "reason": reason}
    drafts: list[outbox.Draft] = []
    for channel in outbox.USER_CHANNELS[outbox.USER_CONTACT_UNREACHABLE]:
        if channel == "push":
            for device_id in await _push_devices(session, owner_id):
                drafts.append(
                    outbox.Draft(
                        user_id=owner_id,
                        audience="user",
                        category=outbox.CATEGORY_USER,
                        channel="push",
                        template_key=outbox.USER_CONTACT_UNREACHABLE,
                        send_after=now,
                        dedupe_key=f"{base}:push:{device_id}",
                        device_id=device_id,
                        params=params,
                    )
                )
        else:
            drafts.append(
                outbox.Draft(
                    user_id=owner_id,
                    audience="user",
                    category=outbox.CATEGORY_USER,
                    channel=channel,
                    template_key=outbox.USER_CONTACT_UNREACHABLE,
                    send_after=now,
                    dedupe_key=f"{base}:{channel}",
                    params=params,
                )
            )
    return drafts


async def _push_devices(session: AsyncSession, user_id: uuid.UUID) -> list[uuid.UUID]:
    """The person's phones that can be pushed to. (Not ``EngineStore``: this module runs in the
    API process too, which must never import the engine.)"""
    result = await session.execute(
        select(Device.id)
        .where(
            Device.user_id == user_id,
            Device.revoked_at.is_(None),
            Device.push_token.is_not(None),
        )
        .order_by(Device.id)
    )
    return [row[0] for row in result.all()]
