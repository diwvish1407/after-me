"""Several check-in events per person (pure deadline bookkeeping plus the queries it needs).

The primary event is the schedule held in ``checkin_configurations`` (``interval_*``,
``due_local_time``); extra events are ``checkin_slots`` rows. Each event has its own deadline:
``primary_due_at`` for the primary one, ``next_due_at`` on each slot. The configuration's
``next_due_at`` is always the **earliest** of them, and ``due_slot_id`` says whose it is
(``None``: the primary event). The engine only ever watches ``next_due_at``, so everything it
guarantees (the per-user lock, the safety gate, Hold, FS-25) applies unchanged.

Rules:

* Every change happens under the per-user lock (the configuration row), held by the caller.
* ``baseline_at`` moves on every check-in exactly as before, so a check-in is always absorbed
  (ESCALATION_ENGINE §6.3, FS-25).
* An I'M OK satisfies the event that is due first, plus any other event due within
  :data:`SATISFY_TOGETHER` of it (two events at 20:00 and 20:30 are answered by one tap). Each
  satisfied event moves to its next occurrence after the check-in; the others keep theirs.
* Activation, I'M SAFE, a void and a timezone change restart **every** event from that moment.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from datetime import datetime, timedelta
from typing import Final
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.checkins.models import CheckinConfiguration, CheckinSlot
from app.checkins.schedule import next_due_for

SATISFY_TOGETHER: Final = timedelta(minutes=60)


async def live_slots(session: AsyncSession, user_id: uuid.UUID) -> list[CheckinSlot]:
    """The person's extra events that have not been removed, oldest first."""
    stmt = (
        select(CheckinSlot)
        .where(CheckinSlot.user_id == user_id, CheckinSlot.deleted_at.is_(None))
        .order_by(CheckinSlot.created_at, CheckinSlot.id)
        .execution_options(populate_existing=True)
    )
    # No autoflush: callers often read the slots half-way through a change to the
    # configuration row (status set, deadline not yet), which must not reach the
    # database before it is consistent (ck_checkin_cfg_active_has_due).
    with session.no_autoflush:
        return list((await session.execute(stmt)).scalars())


def sync_due(cfg: CheckinConfiguration, slots: Sequence[CheckinSlot]) -> None:
    """Set ``next_due_at`` / ``due_slot_id`` to the earliest event deadline. An inactive
    schedule has none."""
    if cfg.status == "inactive":
        cfg.next_due_at = None
        cfg.due_slot_id = None
        return
    best_at = cfg.primary_due_at
    best_slot: uuid.UUID | None = None
    for slot in slots:
        if slot.deleted_at is not None or slot.next_due_at is None:
            continue
        if best_at is None or slot.next_due_at < best_at:
            best_at = slot.next_due_at
            best_slot = slot.id
    cfg.next_due_at = best_at
    cfg.due_slot_id = best_slot


def restart_all(
    cfg: CheckinConfiguration,
    slots: Sequence[CheckinSlot],
    timezone: str,
    at: datetime,
) -> datetime | None:
    """Every event starts over from ``at`` (activation, I'M SAFE, void, timezone change).
    Sets the baseline too. Returns the new earliest deadline."""
    tz = ZoneInfo(timezone)
    cfg.baseline_at = at
    cfg.primary_due_at = next_due_for(cfg, at, tz)
    for slot in slots:
        if slot.deleted_at is None:
            slot.next_due_at = next_due_for(slot, at, tz)
            slot.updated_at = at
    sync_due(cfg, slots)
    return cfg.next_due_at


def restart_primary(
    cfg: CheckinConfiguration,
    slots: Sequence[CheckinSlot],
    timezone: str,
    at: datetime,
) -> None:
    """The primary event's timing changed: only its deadline restarts (from ``at``)."""
    cfg.baseline_at = at
    cfg.primary_due_at = next_due_for(cfg, at, ZoneInfo(timezone))
    sync_due(cfg, slots)


def start_slot(
    cfg: CheckinConfiguration,
    slot: CheckinSlot,
    slots: Sequence[CheckinSlot],
    timezone: str,
    at: datetime,
) -> None:
    """A new or re-timed extra event: its own deadline starts from ``at`` (only while the
    schedule is on; an inactive schedule gets every deadline at activation)."""
    if cfg.status == "inactive":
        slot.next_due_at = None
    else:
        slot.next_due_at = next_due_for(slot, at, ZoneInfo(timezone))
    slot.updated_at = at
    sync_due(cfg, slots)


def satisfy(
    cfg: CheckinConfiguration,
    slots: Sequence[CheckinSlot],
    timezone: str,
    at: datetime,
) -> datetime | None:
    """An I'M OK at ``at``: the first-due event (and any due within :data:`SATISFY_TOGETHER`
    of it) moves to its next occurrence after ``at``. The baseline always moves (the check-in
    is absorbed). Returns the new earliest deadline."""
    tz = ZoneInfo(timezone)
    cfg.baseline_at = at
    live = [s for s in slots if s.deleted_at is None]
    dues: list[datetime] = [d for d in [cfg.primary_due_at, *(s.next_due_at for s in live)] if d]
    if not dues:
        # Nothing scheduled yet (e.g. resumed from an incident on a fresh row): start all.
        return restart_all(cfg, slots, timezone, at)
    first = min(dues)
    limit = first + SATISFY_TOGETHER
    if cfg.primary_due_at is None or cfg.primary_due_at <= limit:
        cfg.primary_due_at = next_due_for(cfg, at, tz)
    for slot in live:
        if slot.next_due_at is None or slot.next_due_at <= limit:
            slot.next_due_at = next_due_for(slot, at, tz)
            slot.updated_at = at
    sync_due(cfg, slots)
    return cfg.next_due_at


def clear_all(cfg: CheckinConfiguration, slots: Sequence[CheckinSlot]) -> None:
    """The schedule is switched off: no event has a deadline."""
    cfg.baseline_at = None
    cfg.primary_due_at = None
    for slot in slots:
        slot.next_due_at = None
    cfg.next_due_at = None
    cfg.due_slot_id = None


async def restart_everything(
    session: AsyncSession, cfg: CheckinConfiguration, timezone: str, at: datetime
) -> datetime | None:
    """:func:`restart_all` for callers that have not loaded the slots."""
    return restart_all(cfg, await live_slots(session, cfg.user_id), timezone, at)
