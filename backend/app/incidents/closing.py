"""Closing an incident: the one routine behind I'M OK, I'M SAFE and voiding
(ESCALATION_ENGINE §4.1, §9, §10).

Called inside the caller's transaction, which already holds the per-user lock and the incident
row. It only *stops* things (INV-1): it cancels what is pending and queued, and, when contacts
were messaged, queues an all-clear. Everything it writes is within what the API role may do.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.audit import writer as audit
from app.audit.writer import AuditEvent, AuditWriter
from app.checkins.repository import CheckinConfigRepository
from app.checkins.schedule import compute_next_due
from app.contacts.repository import ContactRepository
from app.incidents.models import EscalationIncident
from app.incidents.repository import IncidentRepository
from app.notifications import outbox
from app.notifications.outbox import Draft
from app.releases.repository import ReleaseRepository
from app.users.models import UserProfile

# Why a release is taken back, by who closed the incident (DATABASE §3.7 ``revoke_reason``).
_REVOKE_REASON: dict[str, str] = {
    "user_checkin": "user_checkin",
    "user_safe": "user_safe",
    "operator_void": "operator",
    "account_deleted": "account_deleted",
}


@dataclass(frozen=True)
class ClosingOutcome:
    cancelled_actions: int
    cancelled_messages: int
    all_clear_to: list[tuple[uuid.UUID, str]]  # (contact id, display name)


async def close_incident(
    session: AsyncSession,
    *,
    audit_writer: AuditWriter,
    incident: EscalationIncident,
    status: str,
    closed_by: str,
    now: datetime,
    all_clear: bool,
    user_summary: dict[str, Any] | None = None,
    actor_user_id: uuid.UUID | None = None,
    request_id: str | None = None,
    ip_hash: bytes | None = None,
) -> ClosingOutcome:
    """``status`` is ``resolved``, ``cancelled`` or ``voided``. ``all_clear`` queues an all-clear
    to every contact that was actually messaged (never to anyone else). ``user_summary`` is
    included in the confirmation sent to the user (``next_due_at``)."""
    owner = incident.user_id
    incidents = IncidentRepository(session)
    messaged = await incidents.messaged_contact_ids(owner_id=owner, incident_id=incident.id)

    cancelled_actions = await incidents.cancel_pending_actions(
        owner_id=owner, incident_id=incident.id, now=now
    )
    cancelled_messages = await outbox.cancel_queued(
        session,
        incident_id=incident.id,
        categories=(outbox.CATEGORY_ESCALATION,),
        reason=f"incident_{status}",
        now=now,
    )
    await incidents.close(
        owner_id=owner,
        incident_id=incident.id,
        status=status,
        closed_by=closed_by,
        now=now,
    )
    incident.status = status
    incident.closed_at = now
    incident.closed_by = closed_by
    revoked_releases = await ReleaseRepository(session).revoke_for_incident(
        owner_id=owner,
        incident_id=incident.id,
        reason=_REVOKE_REASON.get(closed_by, "operator"),
        now=now,
    )
    if revoked_releases:
        await audit_writer.record(
            session,
            AuditEvent(
                action=audit.RELEASE_REVOKED,
                occurred_at=now,
                subject_user_id=owner,
                actor_type="user" if actor_user_id is not None else "system",
                actor_id=actor_user_id,
                resource_type="incident",
                resource_id=incident.id,
                request_id=request_id,
                ip_hash=ip_hash,
                metadata={
                    "releases": revoked_releases,
                    "reason": _REVOKE_REASON.get(closed_by, "operator"),
                },
            ),
        )

    recipients: list[tuple[uuid.UUID, str]] = []
    if all_clear and messaged:
        contacts = {c.id: c for c in await ContactRepository(session).list(owner_id=owner)}
        drafts: list[Draft] = []
        for contact_id in messaged:
            contact = contacts.get(contact_id)
            if contact is None:  # deleted since: the user's own act, no all-clear (§10)
                continue
            recipients.append((contact_id, contact.display_name))
            drafts.append(
                Draft(
                    user_id=owner,
                    audience="contact",
                    category=outbox.CATEGORY_CONTACT_OTHER,
                    channel="email",
                    template_key=outbox.CONTACT_ALL_CLEAR,
                    send_after=now,
                    dedupe_key=f"allclear:{incident.id}:{contact_id}",
                    contact_id=contact_id,
                    incident_id=incident.id,
                    params={"checked_in_at": now.isoformat()},
                )
            )
        if recipients:
            drafts.extend(_user_confirmation(owner, incident.id, recipients, now, user_summary))
        await outbox.enqueue(session, drafts, now=now)

    action = {
        "resolved": audit.INCIDENT_RESOLVED,
        "cancelled": audit.INCIDENT_CANCELLED,
        "voided": audit.INCIDENT_VOIDED,
    }[status]
    await audit_writer.record(
        session,
        AuditEvent(
            action=action,
            occurred_at=now,
            subject_user_id=owner,
            actor_type="user" if actor_user_id is not None else "system",
            actor_id=actor_user_id,
            resource_type="incident",
            resource_id=incident.id,
            request_id=request_id,
            ip_hash=ip_hash,
            metadata={
                "closed_by": closed_by,
                "cancelled_actions": cancelled_actions,
                "cancelled_messages": cancelled_messages,
                "all_clear": len(recipients),
            },
        ),
    )
    return ClosingOutcome(cancelled_actions, cancelled_messages, recipients)


def _user_confirmation(
    owner: uuid.UUID,
    incident_id: uuid.UUID,
    recipients: list[tuple[uuid.UUID, str]],
    now: datetime,
    summary: dict[str, Any] | None,
) -> list[Draft]:
    params: dict[str, Any] = {
        "incident_id": str(incident_id),
        "contact_ids": [str(c) for c, _ in recipients],
        **(summary or {}),
    }
    return [
        Draft(
            user_id=owner,
            audience="user",
            category=outbox.CATEGORY_USER,
            channel=channel,
            template_key=outbox.USER_ALL_CLEAR,
            send_after=now,
            dedupe_key=f"allclear-user:{incident_id}:{channel}",
            incident_id=incident_id,
            params=params,
        )
        for channel in outbox.USER_CHANNELS[outbox.USER_ALL_CLEAR]
        if channel == "email"  # push needs a device row; the email always reaches the owner
    ]


async def void_open_incident(
    session: AsyncSession,
    *,
    audit_writer: AuditWriter,
    owner_id: uuid.UUID,
    closed_by: str,
    now: datetime,
) -> ClosingOutcome | None:
    """Close the user's open incident as ``voided`` (account deletion, or an operator after a
    confirmed fault, ESCALATION_ENGINE §10): all-clear to the contacts already messaged, and
    nothing contact-facing remains pending. The caller holds the per-user lock. Returns ``None``
    when there is no open incident."""
    incident = await IncidentRepository(session).get_open(owner_id=owner_id, for_update=True)
    if incident is None:
        return None
    outcome = await close_incident(
        session,
        audit_writer=audit_writer,
        incident=incident,
        status="voided",
        closed_by=closed_by,
        now=now,
        all_clear=True,
    )
    await _resume_schedule(session, owner_id=owner_id, incident=incident, now=now)
    return outcome


async def _resume_schedule(
    session: AsyncSession,
    *,
    owner_id: uuid.UUID,
    incident: EscalationIncident,
    now: datetime,
) -> None:
    """A voided incident must not leave the schedule suspended: ``incident_open`` with no
    incident is never picked up again by the engine, so the person would be silently unmonitored.

    The schedule restarts from now, a full interval ahead. It is **not** a check-in (no
    ``last_checkin_at``, no event): the person did not confirm anything, and a void must never
    count as the evidence that settles a later incident. When nobody was told anything, the
    person gets the service-interruption notice (it says nobody was contacted) so that they know
    to check in; when contacts were messaged, the all-clear confirmation already reaches them
    (and that notice would be false)."""
    config = await CheckinConfigRepository(session).get(owner_id=owner_id, for_update=True)
    if config is None or config.status != "incident_open":
        return
    timezone = (
        await session.execute(select(UserProfile.timezone).where(UserProfile.user_id == owner_id))
    ).scalar_one_or_none() or "UTC"
    at = max(now, config.baseline_at or now, config.last_checkin_at or now)
    config.status = "active"
    config.baseline_at = at
    config.next_due_at = compute_next_due(
        at, config.interval_days, config.due_local_time, ZoneInfo(timezone)
    )
    config.updated_at = now
    if incident.contacts_messaged_at is not None:
        return  # the all-clear confirmation covers it, and "nobody was contacted" would be false
    await outbox.enqueue(
        session,
        [
            Draft(
                user_id=owner_id,
                audience="user",
                category=outbox.CATEGORY_USER,
                channel="email",
                template_key=outbox.USER_HOLD_NOTICE,
                send_after=now,
                dedupe_key=f"voidnotice:{incident.id}:email",
                incident_id=incident.id,
                params={"incident_id": str(incident.id)},
            )
        ],
        now=now,
    )
