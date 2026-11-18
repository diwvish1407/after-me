"""Extra check-in events (``/v1/checkin/events``): create, change, remove.

Every write takes the per-user lock (the ``checkin_configurations`` row) first, like the
schedule itself, and leaves the configuration's earliest deadline in sync (app/checkins/slots.py).
Removing an event, or giving it a longer interval, while the schedule protects someone softens
the safety net and needs a fresh re-authentication (SECURITY §7), as for the primary schedule.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import select

from app.api.deps import CurrentUser, has_fresh_reauth
from app.audit import writer as audit
from app.checkins.models import MAX_EXTRA_SLOTS, CheckinConfiguration, CheckinSlot
from app.checkins.schedule import format_hhmm, parse_hhmm
from app.checkins.schemas import EventIn, EventList, EventOut
from app.checkins.service import CheckinService
from app.checkins.slots import live_slots, start_slot, sync_due
from app.core.errors import IncidentOpen, NotFound, PlanLimitReached, ReauthRequired
from app.plans.models import EscalationPlan


def _span(interval_days: int, interval_minutes: int | None) -> int:
    return interval_minutes if interval_minutes is not None else interval_days * 1440


class EventService(CheckinService):
    async def _out(self, slots: list[CheckinSlot]) -> list[EventOut]:
        ids = [s.id for s in slots]
        planned: set[uuid.UUID] = set()
        if ids:
            rows = await self.session.execute(
                select(EscalationPlan.slot_id).where(EscalationPlan.slot_id.in_(ids))
            )
            planned = {r[0] for r in rows.all() if r[0] is not None}
        return [
            EventOut(
                id=s.id,
                label=s.label,
                interval_days=s.interval_days,
                interval_minutes=s.interval_minutes,
                due_local_time=format_hhmm(s.due_local_time),
                next_due_at=s.next_due_at,
                has_own_plan=s.id in planned,
            )
            for s in slots
        ]

    async def list_events(self, current: CurrentUser) -> EventList:
        slots = await live_slots(self.session, current.user_id)
        items = await self._out(slots)
        await self.session.commit()
        return EventList(items=items, max_events=MAX_EXTRA_SLOTS)

    async def _locked(
        self, current: CurrentUser
    ) -> tuple[datetime, CheckinConfiguration, list[CheckinSlot], str]:
        now = await self._now()
        cfg = await self._config(current.user_id, lock=True)
        if cfg.status == "incident_open":
            raise IncidentOpen
        slots = await live_slots(self.session, current.user_id)
        return now, cfg, slots, await self._timezone(current.user_id)

    def _changed(self, cfg: CheckinConfiguration, now: datetime) -> None:
        cfg.version += 1  # the schedule representation (its earliest deadline) changed
        cfg.updated_at = now

    async def create_event(self, current: CurrentUser, body: EventIn) -> EventOut:
        now, cfg, slots, timezone = await self._locked(current)
        if len(slots) >= MAX_EXTRA_SLOTS:
            raise PlanLimitReached(resource="events", limit=MAX_EXTRA_SLOTS, current=len(slots))
        slot = CheckinSlot(
            id=uuid.uuid4(),
            user_id=current.user_id,
            label=body.label.strip() or "Check-in",
            interval_days=body.interval_days,
            interval_minutes=body.interval_minutes,
            due_local_time=parse_hhmm(body.due_local_time),
            created_at=now,
            updated_at=now,
        )
        self.session.add(slot)
        slots.append(slot)
        start_slot(cfg, slot, slots, timezone, max(now, cfg.baseline_at or now))
        self._changed(cfg, now)
        await self.session.flush()
        await self.services.audit.record(
            self.session,
            self._event(
                audit.SCHEDULE_UPDATED,
                now,
                current.user_id,
                resource_type="schedule",
                resource_id=current.user_id,
                fields="event.added",
                active=cfg.status == "active",
            ),
        )
        (out,) = await self._out([slot])
        await self.session.commit()
        return out

    def _find(self, slots: list[CheckinSlot], event_id: uuid.UUID) -> CheckinSlot:
        for slot in slots:
            if slot.id == event_id:
                return slot
        raise NotFound

    async def update_event(
        self, current: CurrentUser, event_id: uuid.UUID, body: EventIn
    ) -> EventOut:
        now, cfg, slots, timezone = await self._locked(current)
        slot = self._find(slots, event_id)
        longer = _span(body.interval_days, body.interval_minutes) > _span(
            slot.interval_days, slot.interval_minutes
        )
        if cfg.status == "active" and longer and not has_fresh_reauth(current, now):
            raise ReauthRequired
        due = parse_hhmm(body.due_local_time)
        timing_changed = (
            slot.interval_days != body.interval_days
            or slot.interval_minutes != body.interval_minutes
            or slot.due_local_time.replace(tzinfo=None) != due
        )
        slot.label = body.label.strip() or slot.label
        slot.interval_days = body.interval_days
        slot.interval_minutes = body.interval_minutes
        slot.due_local_time = due
        slot.updated_at = now
        if timing_changed:
            start_slot(cfg, slot, slots, timezone, max(now, cfg.baseline_at or now))
            self._changed(cfg, now)
            await self.services.audit.record(
                self.session,
                self._event(
                    audit.SCHEDULE_UPDATED,
                    now,
                    current.user_id,
                    resource_type="schedule",
                    resource_id=current.user_id,
                    fields="event.changed",
                    active=cfg.status == "active",
                ),
            )
        (out,) = await self._out([slot])
        await self.session.commit()
        return out

    async def delete_event(self, current: CurrentUser, event_id: uuid.UUID) -> None:
        now, cfg, slots, _ = await self._locked(current)
        slot = self._find(slots, event_id)
        if cfg.status == "active" and not has_fresh_reauth(current, now):
            raise ReauthRequired
        slot.deleted_at = now
        slot.next_due_at = None
        slot.updated_at = now
        sync_due(cfg, [s for s in slots if s.id != slot.id])
        self._changed(cfg, now)
        await self.services.audit.record(
            self.session,
            self._event(
                audit.SCHEDULE_UPDATED,
                now,
                current.user_id,
                resource_type="schedule",
                resource_id=current.user_id,
                fields="event.removed",
                active=cfg.status == "active",
            ),
        )
        await self.session.commit()
