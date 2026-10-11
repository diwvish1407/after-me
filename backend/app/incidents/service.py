"""Incident reads and I'M SAFE (API_SPEC §9; ESCALATION_ENGINE §9.2).

Everything here only *observes or stops* (INV-1). No path creates an incident, an action or a
release: those are the worker's, and the database refuses the API role the INSERT.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from zoneinfo import ZoneInfo

from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.api.deps import CurrentUser, RequestContext
from app.auth.base import AuthServiceBase
from app.auth.guards import ensure_owner_active
from app.checkins.models import CheckinConfiguration
from app.checkins.repository import CheckinConfigRepository, CheckinEventRepository
from app.checkins.schedule import compute_next_due
from app.contacts.repository import ContactRepository
from app.core.errors import IdempotencyKeyReused, InvalidState, NotFound, ValidationFailed
from app.core.pagination import InvalidCursorError, decode_cursor, encode_cursor
from app.incidents.closing import close_incident
from app.incidents.models import OPEN_STATUSES, EscalationIncident
from app.incidents.repository import IncidentRepository
from app.incidents.schemas import (
    AllClearTarget,
    IncidentCurrent,
    IncidentOut,
    IncidentPage,
    IncidentSummary,
    ReleaseOut,
    SafeResponse,
)
from app.incidents.snapshot import SnapshotError, parse_snapshot
from app.incidents.view import build_incident
from app.instructions.reader import open_texts
from app.releases.repository import ReleaseRepository
from app.security.rate_limit import SAFE_PER_USER


class IncidentService(AuthServiceBase):
    def __init__(
        self, *, session: AsyncSession, services: AppServices, ctx: RequestContext
    ) -> None:
        super().__init__(session=session, services=services, ctx=ctx)
        self.incidents = IncidentRepository(self.session)
        self.configs = CheckinConfigRepository(self.session)
        self.events = CheckinEventRepository(self.session)

    # ------------------------------------------------------------------ reads

    async def view(
        self, owner_id: uuid.UUID, incident: EscalationIncident, now: datetime
    ) -> IncidentOut:
        actions = await self.incidents.actions(owner_id=owner_id, incident_id=incident.id)
        ids: list[uuid.UUID] = []
        try:
            snapshot = parse_snapshot(incident.plan_snapshot)
            ids = sorted({c for s in snapshot.stages for c in s.notify_contact_ids})
        except SnapshotError:
            ids = []
        names = await ContactRepository(self.session).display_names(
            owner_id=owner_id, contact_ids=ids
        )
        releases = await self._releases(owner_id, incident)
        return build_incident(incident, actions, names, now=now, releases=releases)

    async def _releases(
        self, owner_id: uuid.UUID, incident: EscalationIncident
    ) -> list[ReleaseOut]:
        """What was shared with whom in this incident. Titles are opened for the owner only; a
        title that cannot be opened is ``None`` (the rest of the incident still shows)."""
        rows = await ReleaseRepository(self.session).for_owner_view(
            owner_id=owner_id, incident_id=incident.id
        )
        if not rows:
            return []
        texts = await open_texts(
            self.session,
            self.services.vault,
            owner_id=owner_id,
            instruction_ids={event.instruction_id for event, _, _ in rows},
        )
        out: list[ReleaseOut] = []
        for event, contact_name, position in rows:
            opened = texts.get(event.instruction_id)
            title = opened[0] if opened is not None else None
            out.append(
                ReleaseOut(
                    contact_id=event.contact_id,
                    contact_display_name=contact_name,
                    instruction_id=event.instruction_id,
                    instruction_title=title,
                    stage_position=position,
                    released_at=event.released_at,
                    visible_after=event.visible_after,
                    first_viewed_at=event.first_viewed_at,
                    last_viewed_at=event.last_viewed_at,
                    view_count=event.view_count,
                    revoked_at=event.revoked_at,
                    revoke_reason=event.revoke_reason,
                )
            )
        return out

    async def current(self, current: CurrentUser) -> IncidentCurrent:
        now = await self._now()
        incident = await self.incidents.get_open(owner_id=current.user_id)
        out = await self.view(current.user_id, incident, now) if incident else None
        await self.session.commit()
        return IncidentCurrent(incident=out)

    async def detail(self, current: CurrentUser, incident_id: uuid.UUID) -> IncidentOut:
        now = await self._now()
        incident = await self.incidents.get(owner_id=current.user_id, incident_id=incident_id)
        if incident is None:
            raise NotFound
        out = await self.view(current.user_id, incident, now)
        await self.session.commit()
        return out

    async def history(self, current: CurrentUser, limit: int, cursor: str | None) -> IncidentPage:
        after = None
        if cursor is not None:
            try:
                after = decode_cursor(cursor)
            except InvalidCursorError:
                raise ValidationFailed(
                    [{"field": "cursor", "code": "invalid", "message": "This cursor isn't valid."}]
                ) from None
        rows = await self.incidents.page(owner_id=current.user_id, limit=limit + 1, after=after)
        page = rows[:limit]
        next_cursor = encode_cursor(page[-1].opened_at, page[-1].id) if len(rows) > limit else None
        await self.session.commit()
        return IncidentPage(
            items=[
                IncidentSummary(
                    id=i.id,
                    status=i.status,  # type: ignore[arg-type]
                    missed_due_at=i.missed_due_at,
                    opened_at=i.opened_at,
                    closed_at=i.closed_at,
                    closed_by=i.closed_by,
                    contacts_messaged=i.contacts_messaged_at is not None,
                )
                for i in page
            ],
            next_cursor=next_cursor,
        )

    # ------------------------------------------------------------------ I'M SAFE

    async def safe(
        self, current: CurrentUser, incident_id: uuid.UUID, key: str, *, source: str = "app"
    ) -> tuple[dict[str, object], bool]:
        """§9.2. Re-authentication was enforced by the route. Returns the JSON body and whether
        it is a replay of an earlier answer."""
        replay = await self.events.find_by_key(owner_id=current.user_id, key=key)
        if replay is not None:
            await self.session.commit()
            if replay.kind != "safe" or replay.incident_id != incident_id:
                raise IdempotencyKeyReused  # another operation's result is not this one's
            return replay.response_snapshot, True

        now = await self._now()
        await self._limit(SAFE_PER_USER, str(current.user_id), now)
        config = await self.configs.get(owner_id=current.user_id, for_update=True)
        if config is None:  # pragma: no cover - created at signup verification
            raise NotFound
        await ensure_owner_active(self.session, current.user_id)
        replay = await self.events.find_by_key(owner_id=current.user_id, key=key)
        if replay is not None:
            await self.session.commit()
            if replay.kind != "safe" or replay.incident_id != incident_id:
                raise IdempotencyKeyReused
            return replay.response_snapshot, True

        incident = await self.incidents.get(
            owner_id=current.user_id, incident_id=incident_id, for_update=True
        )
        if incident is None:
            raise NotFound
        if incident.status not in OPEN_STATUSES:
            raise InvalidState("This incident is already closed.")

        profile = await self.profiles.get(owner_id=current.user_id)
        timezone = profile.timezone if profile is not None else "UTC"
        at = _monotonic(now, config)
        next_due = _restart(config, at, timezone)

        outcome = await close_incident(
            self.session,
            audit_writer=self.services.audit,
            incident=incident,
            status="cancelled",
            closed_by="user_safe",
            now=now,
            all_clear=True,
            user_summary={"next_due_at": next_due.isoformat()},
            actor_user_id=current.user_id,
            request_id=self.ctx.request_id,
            ip_hash=self.ctx.ip_hash,
        )
        body = SafeResponse(
            status="cancelled",
            incident_id=incident.id,
            all_clear_sent_to=[
                AllClearTarget(contact_id=c, display_name=n) for c, n in outcome.all_clear_to
            ],
            next_due_at=next_due,
            server_time=now,
        ).model_dump(mode="json")
        await self.events.add(
            event_id=uuid.uuid4(),
            owner_id=current.user_id,
            kind="safe",
            source=source,
            received_at=now,
            client_reported_at=None,
            idempotency_key=key,
            session_id=current.session_id,
            device_id=current.device_id,
            response_snapshot=body,
            incident_id=incident.id,
        )
        await self.session.commit()
        return body, False


def _monotonic(now: datetime, config: CheckinConfiguration) -> datetime:
    return max(now, config.last_checkin_at or now, config.baseline_at or now)


def _restart(config: CheckinConfiguration, at: datetime, timezone: str) -> datetime:
    """The schedule resumes from this confirmation, exactly as after an I'M OK (§9.2)."""
    config.status = "active"
    config.last_checkin_at = at
    config.baseline_at = at
    config.next_due_at = compute_next_due(
        at, config.interval_days, config.due_local_time, ZoneInfo(timezone)
    )
    config.updated_at = at
    return config.next_due_at
