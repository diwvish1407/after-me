"""The Activity feed (API_SPEC §11, SECURITY §9).

Only audit rows marked ``user_visible`` about this account are read. The audit log itself holds
identifiers, reason codes and counts, never names or titles (SECURITY §9); the feed composes what
the owner reads from the owner's own rows at the time of the request:

* a contact's name comes from the contact (kept after a soft delete),
* an instruction's title is opened for the owner only and is ``None`` if it cannot be,
* what a contact saw in a view is reconstructed from the releases that were in force at the time
  of the view.

Each action has an allow-list of parameters, so an unexpected audit field is never sent.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime
from typing import Final

from sqlalchemy import and_, or_, select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.activity.schemas import ActivityEntry, ActivityPage, ParamValue
from app.api.container import AppServices
from app.api.deps import CurrentUser
from app.audit.models import AuditLog
from app.checkins.models import CheckinEvent
from app.contacts.models import TrustedContact
from app.core.errors import ValidationFailed
from app.core.pagination import InvalidCursorError, decode_seq_cursor, encode_seq_cursor
from app.instructions.reader import open_texts
from app.releases.models import PortalAccess, ReleaseEvent

# Parameters copied from the audit row's metadata, per action.
_METADATA_PARAMS: Final[dict[str, tuple[str, ...]]] = {
    "auth.logout_all": ("sessions_revoked",),
    "plan.updated": ("stages", "removed"),
    "incident.opened": ("stages",),
    "incident.resolved": ("closed_by", "all_clear"),
    "incident.cancelled": ("closed_by", "all_clear"),
    "incident.voided": ("closed_by", "all_clear"),
    "escalation.final_warning_sent": ("stage",),
    "escalation.stage_executed": ("stage", "notified", "skipped"),
    "release.created": ("stage", "releases"),
    "release.revoked": ("releases", "reason"),
    "instruction.recipients_changed": ("added", "removed"),
    "contact.invitation_sent": ("send_count",),
}
_CONTACT_ACTIONS: Final = frozenset(
    {
        "contact.created",
        "contact.deleted",
        "contact.invitation_sent",
        "contact.accepted",
        "contact.declined",
        "contact.opted_out",
    }
)
_INCIDENT_ACTIONS: Final = frozenset(
    {
        "incident.opened",
        "incident.resolved",
        "incident.cancelled",
        "incident.voided",
        "escalation.final_warning_sent",
        "escalation.stage_executed",
        "release.created",
        "release.revoked",
    }
)
_MAX_TITLES: Final = 5


@dataclass
class _Lookups:
    contact_names: dict[uuid.UUID, str] = field(default_factory=dict)
    checkins: dict[uuid.UUID, tuple[str, str]] = field(default_factory=dict)
    access: dict[uuid.UUID, tuple[uuid.UUID, uuid.UUID]] = field(default_factory=dict)
    releases: dict[tuple[uuid.UUID, uuid.UUID], list[ReleaseEvent]] = field(default_factory=dict)
    titles: dict[uuid.UUID, str | None] = field(default_factory=dict)


class ActivityService:
    def __init__(self, *, session: AsyncSession, services: AppServices) -> None:
        self.session = session
        self.services = services

    async def page(self, current: CurrentUser, limit: int, cursor: str | None) -> ActivityPage:
        after: tuple[datetime, int] | None = None
        if cursor is not None:
            try:
                after = decode_seq_cursor(cursor)
            except InvalidCursorError:
                raise ValidationFailed(
                    [{"field": "cursor", "code": "invalid", "message": "This cursor isn't valid."}]
                ) from None
        stmt = select(AuditLog).where(
            AuditLog.subject_user_id == current.user_id, AuditLog.user_visible.is_(True)
        )
        if after is not None:
            at, seq = after
            stmt = stmt.where(
                or_(
                    AuditLog.occurred_at < at,
                    and_(AuditLog.occurred_at == at, AuditLog.id < seq),
                )
            )
        stmt = stmt.order_by(AuditLog.occurred_at.desc(), AuditLog.id.desc()).limit(limit + 1)
        rows = list((await self.session.execute(stmt)).scalars())
        shown = rows[:limit]
        look = await self._lookups(current.user_id, shown)
        await self.session.commit()
        items = [
            ActivityEntry(
                id=row.id,
                action=row.action,
                occurred_at=row.occurred_at,
                params=_params(row, look),
            )
            for row in shown
        ]
        more = len(rows) > limit and shown
        next_cursor = encode_seq_cursor(shown[-1].occurred_at, shown[-1].id) if more else None
        return ActivityPage(items=items, next_cursor=next_cursor)

    # ------------------------------------------------------------------ lookups

    async def _lookups(self, owner_id: uuid.UUID, rows: list[AuditLog]) -> _Lookups:
        look = _Lookups()
        contact_ids: set[uuid.UUID] = set()
        checkin_ids: set[uuid.UUID] = set()
        access_ids: set[uuid.UUID] = set()
        instruction_ids: set[uuid.UUID] = set()
        for row in rows:
            if row.action in _CONTACT_ACTIONS and row.resource_id is not None:
                contact_ids.add(row.resource_id)
            elif row.action == "checkin.recorded" and row.resource_id is not None:
                checkin_ids.add(row.resource_id)
            elif row.action == "release.viewed" and row.resource_id is not None:
                access_ids.add(row.resource_id)
            elif row.action == "instruction.recipients_changed" and row.resource_id is not None:
                instruction_ids.add(row.resource_id)

        if access_ids:
            for access in (
                await self.session.execute(
                    select(PortalAccess).where(
                        PortalAccess.user_id == owner_id, PortalAccess.id.in_(access_ids)
                    )
                )
            ).scalars():
                look.access[access.id] = (access.incident_id, access.contact_id)
                contact_ids.add(access.contact_id)
            pairs = set(look.access.values())
            if pairs:
                released = (
                    await self.session.execute(
                        select(ReleaseEvent)
                        .where(
                            ReleaseEvent.user_id == owner_id,
                            tuple_(ReleaseEvent.incident_id, ReleaseEvent.contact_id).in_(pairs),
                        )
                        .order_by(ReleaseEvent.released_at, ReleaseEvent.id)
                    )
                ).scalars()
                for event in released:
                    look.releases.setdefault((event.incident_id, event.contact_id), []).append(
                        event
                    )
                    instruction_ids.add(event.instruction_id)

        if contact_ids:
            named = await self.session.execute(
                select(TrustedContact.id, TrustedContact.display_name).where(
                    TrustedContact.user_id == owner_id, TrustedContact.id.in_(contact_ids)
                )
            )
            look.contact_names = dict(named.all())
        if checkin_ids:
            look.checkins = {
                event_id: (kind, source)
                for event_id, kind, source in (
                    await self.session.execute(
                        select(CheckinEvent.id, CheckinEvent.kind, CheckinEvent.source).where(
                            CheckinEvent.user_id == owner_id, CheckinEvent.id.in_(checkin_ids)
                        )
                    )
                ).all()
            }
        texts = await open_texts(
            self.session,
            self.services.vault,
            owner_id=owner_id,
            instruction_ids=instruction_ids,
        )
        look.titles = {i: (t[0] if t is not None else None) for i, t in texts.items()}
        return look


def _params(row: AuditLog, look: _Lookups) -> dict[str, ParamValue]:
    params: dict[str, ParamValue] = {}
    metadata = row.metadata_ or {}
    for key in _METADATA_PARAMS.get(row.action, ()):
        value = metadata.get(key)
        if isinstance(value, (str, int, bool)):
            params[key] = value

    if row.action in _CONTACT_ACTIONS and row.resource_id is not None:
        params["contact_id"] = str(row.resource_id)
        params["contact_display_name"] = look.contact_names.get(row.resource_id)
    elif row.action == "checkin.recorded" and row.resource_id is not None:
        kind, source = look.checkins.get(row.resource_id, (None, None))
        params["kind"] = kind
        params["source"] = source
    elif row.action in _INCIDENT_ACTIONS and row.resource_id is not None:
        params["incident_id"] = str(row.resource_id)
    elif row.action == "instruction.recipients_changed" and row.resource_id is not None:
        params["instruction_id"] = str(row.resource_id)
        params["instruction_title"] = look.titles.get(row.resource_id)
    elif row.action == "release.viewed":
        _viewed(row, look, params)
    return params


def _viewed(row: AuditLog, look: _Lookups, params: dict[str, ParamValue]) -> None:
    """What the contact could see when they looked: releases of that incident and contact that
    were past their settle delay and not revoked at that moment (a revocation at the very same
    instant counts as after: the feed errs towards showing more than the contact saw)."""
    found = look.access.get(row.resource_id) if row.resource_id is not None else None
    if found is None:
        return
    incident_id, contact_id = found
    params["incident_id"] = str(incident_id)
    params["contact_id"] = str(contact_id)
    params["contact_display_name"] = look.contact_names.get(contact_id)
    seen = [
        event
        for event in look.releases.get(found, [])
        if event.released_at <= row.occurred_at
        and event.visible_after <= row.occurred_at
        and (event.revoked_at is None or event.revoked_at >= row.occurred_at)
    ]
    titles = [t for e in seen if (t := look.titles.get(e.instruction_id)) is not None]
    params["release_count"] = len(seen)
    params["instruction_titles"] = titles[:_MAX_TITLES]
