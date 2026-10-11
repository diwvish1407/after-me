"""The check-in schedule and I'M OK (API_SPEC §6; ESCALATION_ENGINE §3 and §9.1).

Every state-changing path takes the per-user lock first: the user's ``checkin_configurations``
row (``SELECT ... FOR UPDATE``). The connection's ``lock_timeout`` turns a long wait into a
retryable ``503`` and the client retries with the same idempotency key. Rate-limit counters live
on an independent connection and are hit *before* the lock is taken, so a request never holds the
lock while waiting for a second connection.

Phase 4 has no incidents yet: the check-in path below is the "no incident" branch of
ESCALATION_ENGINE §9.1. Phase 5 adds the incident branch next to the marked line.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any, Final
from zoneinfo import ZoneInfo

from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.api.deps import CurrentUser, RequestContext, has_fresh_reauth
from app.audit import writer as audit
from app.auth.base import AuthServiceBase
from app.auth.guards import ensure_owner_active
from app.checkins.models import CheckinConfiguration
from app.checkins.repository import CheckinConfigRepository, CheckinEventRepository
from app.checkins.schedule import compute_next_due, format_hhmm, parse_hhmm
from app.checkins.schemas import (
    CheckinItem,
    CheckinPage,
    CheckinRecord,
    CheckinRequest,
    CheckinResponse,
    ScheduleOut,
    SchedulePutRequest,
)
from app.contacts.repository import ContactRepository
from app.core.errors import (
    ActivationRequirementsUnmet,
    IdempotencyKeyReused,
    IncidentOpen,
    NotFound,
    PreconditionFailed,
    PreconditionRequired,
    ReauthRequired,
    SafeRequired,
    ValidationFailed,
)
from app.core.pagination import InvalidCursorError, decode_cursor, encode_cursor
from app.incidents.closing import close_incident
from app.incidents.repository import IncidentRepository
from app.plans.repository import PlanRepository
from app.security.rate_limit import CHECKIN_PER_USER

CHECKIN_SOURCE_APP: Final = "app"


def schedule_etag(version: int) -> str:
    """The ``ETag`` of the schedule singleton (API_SPEC §1): a strong validator."""
    return f'"sched-{version}"'


def schedule_out(cfg: CheckinConfiguration, timezone: str) -> ScheduleOut:
    return ScheduleOut(
        interval_days=cfg.interval_days,
        due_local_time=format_hhmm(cfg.due_local_time),
        reminder_lead_minutes=cfg.reminder_lead_minutes,
        timezone=timezone,
        status=cfg.status,  # type: ignore[arg-type]
        next_due_at=cfg.next_due_at,
        last_checkin_at=cfg.last_checkin_at,
        version=cfg.version,
    )


def restart_clock(cfg: CheckinConfiguration, timezone: str, now: datetime) -> None:
    """Make ``now`` the baseline and compute the deadline from it (ESCALATION_ENGINE §3.4).
    Only for an active schedule; the caller holds the per-user lock.

    ``now`` is the start of this request's transaction, which can be *earlier* than a
    check-in that committed while this request waited for the lock. The baseline never goes
    behind the last check-in or the previous baseline, so ``baseline_at >= received_at`` of
    every recorded check-in (the engine treats the opposite as an inconsistency, §6.3)."""
    at = max(now, cfg.baseline_at or now, cfg.last_checkin_at or now)
    cfg.baseline_at = at
    cfg.next_due_at = compute_next_due(
        at, cfg.interval_days, cfg.due_local_time, ZoneInfo(timezone)
    )


class CheckinService(AuthServiceBase):
    def __init__(
        self, *, session: AsyncSession, services: AppServices, ctx: RequestContext
    ) -> None:
        super().__init__(session=session, services=services, ctx=ctx)
        self.configs = CheckinConfigRepository(self.session)
        self.events = CheckinEventRepository(self.session)

    # ------------------------------------------------------------------ helpers

    async def _config(self, user_id: uuid.UUID, *, lock: bool) -> CheckinConfiguration:
        cfg = await self.configs.get(owner_id=user_id, for_update=lock)
        if cfg is None:  # pragma: no cover - created at signup verification
            raise NotFound
        if lock:
            await ensure_owner_active(self.session, user_id)
        return cfg

    async def _timezone(self, user_id: uuid.UUID) -> str:
        profile = await self.profiles.get(owner_id=user_id)
        if profile is None:  # pragma: no cover - created at signup verification
            raise NotFound
        return profile.timezone

    # ------------------------------------------------------------------ schedule

    async def get_schedule(self, current: CurrentUser) -> ScheduleOut:
        cfg = await self._config(current.user_id, lock=False)
        timezone = await self._timezone(current.user_id)
        await self.session.commit()
        return schedule_out(cfg, timezone)

    async def put_schedule(
        self, current: CurrentUser, if_match: str | None, body: SchedulePutRequest
    ) -> ScheduleOut:
        if if_match is None:
            raise PreconditionRequired
        now = await self._now()
        cfg = await self._config(current.user_id, lock=True)
        if if_match != schedule_etag(cfg.version):
            raise PreconditionFailed
        if cfg.status == "incident_open":
            raise IncidentOpen
        # Step-up: lengthening the interval of a schedule that is protecting someone softens
        # the safety net for as long as it lasts, so it needs the password like deactivating
        # does (SECURITY §7). Shortening it, changing the time, and any change while the
        # schedule is off (nothing to soften yet: onboarding) need nothing more.
        if (
            cfg.status == "active"
            and body.interval_days > cfg.interval_days
            and not has_fresh_reauth(current, now)
        ):
            raise ReauthRequired
        timezone = await self._timezone(current.user_id)

        due = parse_hhmm(body.due_local_time)
        changed = [
            name
            for name, differs in (
                ("interval", cfg.interval_days != body.interval_days),
                ("time", cfg.due_local_time.replace(tzinfo=None) != due),
                ("reminder", cfg.reminder_lead_minutes != body.reminder_lead_minutes),
            )
            if differs
        ]
        if changed:
            cfg.interval_days = body.interval_days
            cfg.due_local_time = due
            cfg.reminder_lead_minutes = body.reminder_lead_minutes
            if cfg.status == "active":
                restart_clock(cfg, timezone, now)
            cfg.version += 1
            cfg.updated_at = now
            await self.services.audit.record(
                self.session,
                self._event(
                    audit.SCHEDULE_UPDATED,
                    now,
                    current.user_id,
                    resource_type="schedule",
                    resource_id=current.user_id,
                    fields=".".join(changed),
                    active=cfg.status == "active",
                ),
            )
        await self.session.commit()
        return schedule_out(cfg, timezone)

    async def activate(self, current: CurrentUser) -> ScheduleOut:
        now = await self._now()
        cfg = await self._config(current.user_id, lock=True)
        if cfg.status == "incident_open":
            raise IncidentOpen
        timezone = await self._timezone(current.user_id)
        if cfg.status == "active":  # already on: nothing to restart
            await self.session.commit()
            return schedule_out(cfg, timezone)

        requirements = await self._activation_requirements(current)
        if requirements:
            raise ActivationRequirementsUnmet(requirements)

        cfg.status = "active"
        cfg.activated_at = now
        restart_clock(cfg, timezone, now)
        cfg.version += 1
        cfg.updated_at = now
        await self.services.audit.record(
            self.session,
            self._event(
                audit.SCHEDULE_ACTIVATED,
                now,
                current.user_id,
                resource_type="schedule",
                resource_id=current.user_id,
            ),
        )
        await self.session.commit()
        return schedule_out(cfg, timezone)

    async def _activation_requirements(self, current: CurrentUser) -> list[str]:
        """What stands between this account and an active schedule (API_SPEC §6.1): a plan with
        at least one stage that notifies at least one contact who is switched on."""
        contacts = await ContactRepository(self.session).list(owner_id=current.user_id)
        active = {c.id for c in contacts if c.is_active}
        requirements: list[str] = []
        if not active:
            requirements.append("no_contacts")
        rows = await PlanRepository(self.session).stage_contacts(owner_id=current.user_id)
        if not rows:
            requirements.append("no_stages")
        elif not any(contact_id in active for _, contact_id in rows if contact_id is not None):
            requirements.append("stage_empty")
        return requirements

    async def deactivate(self, current: CurrentUser) -> ScheduleOut:
        """The caller has re-authenticated (``ReauthUserDep``): turning the safety net off is a
        step-up operation (SECURITY §6)."""
        now = await self._now()
        cfg = await self._config(current.user_id, lock=True)
        if cfg.status == "incident_open":
            raise IncidentOpen
        timezone = await self._timezone(current.user_id)
        if cfg.status == "active":
            cfg.status = "inactive"
            cfg.baseline_at = None
            cfg.next_due_at = None
            cfg.activated_at = None
            cfg.version += 1
            cfg.updated_at = now
            await self.services.audit.record(
                self.session,
                self._event(
                    audit.SCHEDULE_DEACTIVATED,
                    now,
                    current.user_id,
                    resource_type="schedule",
                    resource_id=current.user_id,
                ),
            )
        await self.session.commit()
        return schedule_out(cfg, timezone)

    # ------------------------------------------------------------------ I'M OK

    async def record(
        self,
        current: CurrentUser,
        key: str,
        body: CheckinRequest | None,
        *,
        source: str = CHECKIN_SOURCE_APP,
    ) -> tuple[dict[str, Any], bool]:
        """Record an I'M OK. Returns the JSON body and whether it is a replay of an earlier
        answer (the router marks replays: their ``server_time`` is old).

        A replay returns the stored JSON verbatim, not a re-validated model: a field added,
        renamed or removed by a later release must never turn the retry of a tap that the
        server already recorded into an error."""
        # A retry of an already-recorded tap is answered from the stored result: no lock, and
        # it does not count against the rate limit (a user must always be able to confirm).
        replay = await self.events.find_by_key(owner_id=current.user_id, key=key)
        if replay is not None:
            await self.session.commit()
            if replay.kind != "ok":
                raise IdempotencyKeyReused  # not this operation's result: never present it as one
            return replay.response_snapshot, True

        now = await self._now()
        await self._limit(CHECKIN_PER_USER, str(current.user_id), now)
        cfg = await self._config(current.user_id, lock=True)

        # Same key, committed by a request that held the lock before this one.
        replay = await self.events.find_by_key(owner_id=current.user_id, key=key)
        if replay is not None:
            await self.session.commit()
            if replay.kind != "ok":
                raise IdempotencyKeyReused
            return replay.response_snapshot, True

        # ESCALATION_ENGINE §9.1: the open incident, if any, is locked right after the user row
        # (lock order). If contacts were already messaged, an I'M OK no longer settles it: the
        # person must confirm I'M SAFE, which also tells those contacts.
        incident = await IncidentRepository(self.session).get_open(
            owner_id=current.user_id, for_update=True
        )
        if incident is not None and incident.contacts_messaged_at is not None:
            raise SafeRequired(incident.id)

        timezone = await self._timezone(current.user_id)
        # Never let the last check-in, or the baseline, move backwards when a request that
        # started earlier waited for the lock behind a later one (see restart_clock).
        at = max(now, cfg.last_checkin_at or now, cfg.baseline_at or now)
        cfg.last_checkin_at = at
        next_due_at: datetime | None = None
        if cfg.status != "inactive" or incident is not None:
            cfg.status = "active"
            cfg.baseline_at = at
            cfg.next_due_at = compute_next_due(
                at, cfg.interval_days, cfg.due_local_time, ZoneInfo(timezone)
            )
            next_due_at = cfg.next_due_at
        cfg.updated_at = now

        event_id = uuid.uuid4()
        response = CheckinResponse(
            checkin=CheckinRecord(id=event_id, kind="ok", received_at=now),
            next_due_at=next_due_at,
            incident_resolved=incident is not None,
            server_time=now,
        )
        await self.events.add(
            event_id=event_id,
            owner_id=current.user_id,
            kind="ok",
            source=source,
            received_at=now,
            client_reported_at=body.client_reported_at if body is not None else None,
            idempotency_key=key,
            session_id=current.session_id,
            device_id=current.device_id,
            response_snapshot=response.model_dump(mode="json"),
            incident_id=incident.id if incident is not None else None,
        )
        if incident is not None:
            # Nobody has been told (checked above): the incident is resolved, what is pending
            # is cancelled, and anything queued for contacts is cancelled before it was sent.
            await close_incident(
                self.session,
                audit_writer=self.services.audit,
                incident=incident,
                status="resolved",
                closed_by="user_checkin",
                now=now,
                all_clear=False,
                actor_user_id=current.user_id,
                request_id=self.ctx.request_id,
                ip_hash=self.ctx.ip_hash,
            )
        await self.services.audit.record(
            self.session,
            self._event(
                audit.CHECKIN_RECORDED,
                now,
                current.user_id,
                resource_type="checkin",
                resource_id=event_id,
            ),
        )
        await self.session.commit()
        return response.model_dump(mode="json"), False

    async def history(self, current: CurrentUser, limit: int, cursor: str | None) -> CheckinPage:
        after = None
        if cursor is not None:
            try:
                after = decode_cursor(cursor)
            except InvalidCursorError:
                raise ValidationFailed(
                    [{"field": "cursor", "code": "invalid", "message": "This cursor isn't valid."}]
                ) from None
        rows = await self.events.page(owner_id=current.user_id, limit=limit + 1, after=after)
        page = rows[:limit]
        next_cursor = (
            encode_cursor(page[-1].received_at, page[-1].id) if len(rows) > limit else None
        )
        await self.session.commit()
        return CheckinPage(
            items=[
                CheckinItem(
                    id=e.id,
                    kind=e.kind,  # type: ignore[arg-type]
                    source=e.source,  # type: ignore[arg-type]
                    received_at=e.received_at,
                )
                for e in page
            ],
            next_cursor=next_cursor,
        )
