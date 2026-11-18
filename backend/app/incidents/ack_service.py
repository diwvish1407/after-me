"""A trusted contact acknowledges an alert ("I'm checking on them").

Informational only: the engine never reads acknowledgements, and an acknowledgement never stops,
delays or changes an escalation (only the person's own I'M SAFE does). It is shown to the person
on the incident timeline and in the Activity feed.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert

from app.audit import writer as audit
from app.audit.writer import AuditEvent
from app.auth.base import AuthServiceBase
from app.contacts.models import TrustedContact
from app.contacts.tokens import parse_ack_token
from app.incidents.models import EscalationIncident, IncidentAcknowledgement
from app.users.models import UserProfile


class AckInvalidError(Exception):
    pass


@dataclass(frozen=True, slots=True)
class AckView:
    person_name: str
    contact_name: str
    already: bool
    open: bool


class AckService(AuthServiceBase):
    async def _load(self, token: str) -> tuple[EscalationIncident, TrustedContact, str, uuid.UUID]:
        parsed = parse_ack_token(self.services.pepper, token)
        if parsed is None:
            raise AckInvalidError
        incident_id, contact_id = parsed
        incident = (
            await self.session.execute(
                select(EscalationIncident).where(EscalationIncident.id == incident_id)
            )
        ).scalar_one_or_none()
        if incident is None:
            raise AckInvalidError
        contact = (
            await self.session.execute(
                select(TrustedContact).where(
                    TrustedContact.id == contact_id,
                    TrustedContact.user_id == incident.user_id,
                    TrustedContact.deleted_at.is_(None),
                )
            )
        ).scalar_one_or_none()
        if contact is None:
            raise AckInvalidError
        name = (
            await self.session.execute(
                select(UserProfile.display_name).where(UserProfile.user_id == incident.user_id)
            )
        ).scalar_one_or_none() or "Your contact"
        return incident, contact, name, incident.user_id

    async def _already(self, incident_id: uuid.UUID, contact_id: uuid.UUID) -> bool:
        return (
            await self.session.execute(
                select(IncidentAcknowledgement.id).where(
                    IncidentAcknowledgement.incident_id == incident_id,
                    IncidentAcknowledgement.contact_id == contact_id,
                )
            )
        ).first() is not None

    async def preview(self, token: str) -> AckView:
        incident, contact, name, _ = await self._load(token)
        view = AckView(
            person_name=name,
            contact_name=contact.display_name,
            already=await self._already(incident.id, contact.id),
            open=incident.closed_at is None,
        )
        await self.session.commit()
        return view

    async def acknowledge(self, token: str) -> AckView:
        now = await self._now()
        incident, contact, name, owner = await self._load(token)
        if incident.closed_at is None:
            inserted = (
                await self.session.execute(
                    insert(IncidentAcknowledgement)
                    .values(
                        incident_id=incident.id,
                        user_id=owner,
                        contact_id=contact.id,
                        acknowledged_at=now,
                    )
                    .on_conflict_do_nothing(constraint="uq_incident_ack_contact")
                    .returning(IncidentAcknowledgement.id)
                )
            ).scalar_one_or_none()
            if inserted is not None:
                await self.services.audit.record(
                    self.session,
                    AuditEvent(
                        action=audit.CONTACT_ACKNOWLEDGED,
                        occurred_at=now,
                        subject_user_id=owner,
                        actor_type="contact",
                        resource_type="incident",
                        resource_id=incident.id,
                        metadata={"contact_id": contact.id},
                    ),
                )
        view = AckView(
            person_name=name,
            contact_name=contact.display_name,
            already=True,
            open=incident.closed_at is None,
        )
        await self.session.commit()
        return view
