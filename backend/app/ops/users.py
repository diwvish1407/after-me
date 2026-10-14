"""Operator commands on one account (``python -m cli.admin user ...``).

* ``set-tier``: changes ``users.tier`` and nothing else. Limits are read from the tier when a
  contact, an instruction or a stage is *created* (``app/users/entitlements.py``), so a downgrade
  deletes nothing: the person keeps everything they have and cannot add more (PRD §10).
* ``suspend``: ``users.status = 'suspended'`` and every session, app and web, revoked. From then
  on login, refresh and every bearer token are refused, the dispatcher cancels queued messages
  that are not an undoing one (``account_inactive``) and the engine opens nothing for the person
  (SECURITY §13). It does **not** void an open incident and sends nothing by itself.
* ``unsuspend``: ``suspended`` back to ``active`` and nothing else (the person signs in again).

All three run as the worker role, under the per-user lock and the user's row, and write an audit
row with an operator actor in the same transaction. A command that changes nothing (already
there) is not an event: it writes no audit row and says so. An account that is
``pending_deletion`` is refused: a closing account is not the operator's to reshape.

Logs carry the account's pseudonymous id and the operator name, never the reason; the reason
goes to the audit row only, as the operator's own text (``audit.OPERATOR_TEXT_KEY``).
"""

from __future__ import annotations

import unicodedata
import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Final

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.container import AppServices
from app.audit import writer as audit
from app.audit.writer import MAX_OPERATOR_TEXT, OPERATOR_TEXT_KEY, AuditEvent
from app.auth.models import USER_TIERS, User
from app.auth.repository import SessionRepository
from app.checkins.models import CheckinConfiguration
from app.contacts.repository import ContactRepository
from app.core.logging import get_logger
from app.engine.store import EngineStore
from app.incidents.models import OPEN_STATUSES, EscalationIncident
from app.instructions.repository import InstructionRepository
from app.ops.admin import _safe_operator
from app.plans.repository import PlanRepository
from app.users.entitlements import TIER_LIMITS

_log = get_logger("afterme.admin")

REVOKE_REASON: Final = "operator"  # a value of auth.models.REVOKE_REASONS


class UserCommandError(Exception):
    """The command cannot be applied. The message is for the operator and holds no personal data."""


@dataclass(frozen=True)
class UserChange:
    user_id: uuid.UUID
    command: str  # set_tier | suspend | unsuspend
    before: str
    after: str
    changed: bool
    sessions_revoked: int = 0
    notes: tuple[str, ...] = ()


def clean_reason(reason: str) -> str:
    """The operator's ``--reason``: one printable line of at most 200 characters."""
    text = reason.strip()
    if not text:
        msg = "--reason must say why"
        raise UserCommandError(msg)
    if len(text) > MAX_OPERATOR_TEXT:
        msg = f"--reason is {len(text)} characters; the limit is {MAX_OPERATOR_TEXT}"
        raise UserCommandError(msg)
    if any(unicodedata.category(c).startswith("C") for c in text):
        msg = "--reason must be one line of printable characters"
        raise UserCommandError(msg)
    return text


async def _lock_user(session: AsyncSession, user_id: uuid.UUID) -> User:
    """The per-user lock first (ESCALATION_ENGINE §6.2), then the account row. An unknown
    account and a busy one are different answers; a closing account is refused."""
    known = (await session.execute(select(User.id).where(User.id == user_id))).scalar_one_or_none()
    if known is None:
        msg = "no such user"
        raise UserCommandError(msg)
    has_schedule = (
        await session.execute(
            select(CheckinConfiguration.user_id).where(CheckinConfiguration.user_id == user_id)
        )
    ).scalar_one_or_none() is not None
    if has_schedule and await EngineStore.lock_user(session, user_id) is None:
        msg = "the account is busy (a request or the engine holds it); try again"
        raise UserCommandError(msg)
    user = (
        await session.execute(
            select(User)
            .where(User.id == user_id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    ).scalar_one_or_none()
    if user is None:  # pragma: no cover - purged between the two reads
        msg = "no such user"
        raise UserCommandError(msg)
    if user.status == "pending_deletion":
        msg = "the account is closed (pending deletion); nothing can be changed"
        raise UserCommandError(msg)
    return user


def _event(
    action: str,
    now: datetime,
    user_id: uuid.UUID,
    operator: str,
    reason: str,
    **metadata: str | int,
) -> AuditEvent:
    return AuditEvent(
        action=action,
        occurred_at=now,
        subject_user_id=user_id,
        actor_type="operator",
        resource_type="user",
        resource_id=user_id,
        metadata={
            "operator": operator[:40],
            "reason_length": len(reason),
            OPERATOR_TEXT_KEY: reason,
            **metadata,
        },
        user_visible=False,
    )


async def _over_limits(session: AsyncSession, user_id: uuid.UUID, tier: str) -> tuple[str, ...]:
    """What a person already has beyond a tier's limits, for the operator to read (a downgrade
    deletes none of it)."""
    limits = TIER_LIMITS[tier]
    used = {
        "contacts": (
            await ContactRepository(session).count_live(owner_id=user_id),
            limits.contacts,
        ),
        "instructions": (
            await InstructionRepository(session).count_live(owner_id=user_id),
            limits.instructions,
        ),
        "stages": (await PlanRepository(session).count_steps(owner_id=user_id), limits.stages),
    }
    over = [f"{name} {have} of {limit}" for name, (have, limit) in used.items() if have > limit]
    if not over:
        return ()
    return (
        f"over the {tier} limits ({', '.join(over)}): nothing is deleted; the person keeps what "
        "they have and can edit or delete it, but cannot add more until they are under the limit",
    )


async def set_tier(
    services: AppServices, *, operator: str, user_id: uuid.UUID, tier: str, reason: str
) -> UserChange:
    """``users.tier`` and nothing else."""
    if tier not in USER_TIERS:
        msg = f"tier must be one of: {', '.join(USER_TIERS)}"
        raise UserCommandError(msg)
    text = clean_reason(reason)
    operator = _safe_operator(operator)
    async with services.db.sessionmaker() as session, session.begin():
        now = await services.clock.now(session)
        user = await _lock_user(session, user_id)
        before = user.tier
        if before == tier:
            return UserChange(user_id, "set_tier", before, tier, changed=False)
        user.tier = tier
        user.updated_at = now
        await services.audit.record(
            session,
            _event(
                audit.OPERATOR_SET_TIER,
                now,
                user_id,
                operator,
                text,
                from_tier=before,
                to_tier=tier,
            ),
        )
        notes = await _over_limits(session, user_id, tier)
    _log.warning(
        "operator.user_tier_set",
        user_id=str(user_id),
        from_tier=before,
        to_tier=tier,
        operator=operator,
    )
    return UserChange(user_id, "set_tier", before, tier, changed=True, notes=notes)


async def suspend(
    services: AppServices, *, operator: str, user_id: uuid.UUID, reason: str
) -> UserChange:
    """Suspend the account and end every session. Voids and sends nothing."""
    text = clean_reason(reason)
    operator = _safe_operator(operator)
    async with services.db.sessionmaker() as session, session.begin():
        now = await services.clock.now(session)
        user = await _lock_user(session, user_id)
        before = user.status
        # Also sweeps a session that outlived a suspension made some other way (a row edited
        # by hand): the command is "nobody is signed in as this account", whatever it found.
        revoked = await SessionRepository(session).revoke_all(
            owner_id=user_id, reason=REVOKE_REASON, now=now
        )
        changed = before != "suspended" or revoked > 0
        if before != "suspended":
            user.status = "suspended"
            user.updated_at = now
        if changed:
            await services.audit.record(
                session,
                _event(
                    audit.OPERATOR_SUSPEND_USER,
                    now,
                    user_id,
                    operator,
                    text,
                    from_status=before,
                    sessions_revoked=revoked,
                ),
            )
        incident = (
            await session.execute(
                select(EscalationIncident.id).where(
                    EscalationIncident.user_id == user_id,
                    EscalationIncident.status.in_(OPEN_STATUSES),
                )
            )
        ).scalar_one_or_none()
    if changed:
        _log.warning(
            "operator.user_suspended",
            user_id=str(user_id),
            operator=operator,
            sessions_revoked=revoked,
        )
    notes: tuple[str, ...] = ()
    if incident is not None:
        notes = (
            f"incident {incident} is open and was not touched: while the account is suspended "
            "its pending actions are cancelled as they fall due (gate G5) and nothing brings "
            "them back; the person cannot check in, and unsuspend will refuse until the "
            f"incident is closed. Close it deliberately with `incident void {incident}` "
            "(contacts already messaged then get the withdrawn alert)",
        )
    return UserChange(
        user_id, "suspend", before, "suspended", changed, sessions_revoked=revoked, notes=notes
    )


async def unsuspend(
    services: AppServices, *, operator: str, user_id: uuid.UUID, reason: str
) -> UserChange:
    """``suspended`` back to ``active``; nothing else changes and nothing is sent."""
    text = clean_reason(reason)
    operator = _safe_operator(operator)
    async with services.db.sessionmaker() as session, session.begin():
        now = await services.clock.now(session)
        user = await _lock_user(session, user_id)
        before = user.status
        if before != "suspended":
            return UserChange(user_id, "unsuspend", before, before, changed=False)
        # Gate G5 cancelled this incident's actions as they fell due while the account was not
        # active, and nothing re-creates them; the one-open-incident rule would then also keep
        # every future incident from opening. Unsuspending would leave the person unmonitored
        # and nobody told, silently: so the incident is closed deliberately first.
        open_incident = (
            await session.execute(
                select(EscalationIncident.id).where(
                    EscalationIncident.user_id == user_id,
                    EscalationIncident.status.in_(OPEN_STATUSES),
                )
            )
        ).scalar_one_or_none()
        if open_incident is not None:
            msg = (
                f"incident {open_incident} is still open for this account and its actions were "
                "cancelled while it was suspended; unsuspending would leave it dead and block "
                "every future incident. Void it first with "
                f"`incident void {open_incident}` (contacts already messaged then get the "
                "withdrawn alert, and the schedule restarts), then run unsuspend again"
            )
            raise UserCommandError(msg)
        user.status = "active"
        user.updated_at = now
        await services.audit.record(
            session,
            _event(audit.OPERATOR_UNSUSPEND_USER, now, user_id, operator, text),
        )
        due = (
            await session.execute(
                select(CheckinConfiguration.next_due_at).where(
                    CheckinConfiguration.user_id == user_id,
                    CheckinConfiguration.status == "active",
                    CheckinConfiguration.next_due_at <= now,
                )
            )
        ).scalar_one_or_none()
    _log.warning("operator.user_unsuspended", user_id=str(user_id), operator=operator)
    notes: tuple[str, ...] = ()
    if due is not None:
        notes = (
            f"the check-in deadline ({due.isoformat()}) passed while the account was suspended: "
            "the engine opens an incident on its next tick (a full grace period from then, "
            "reminders first) unless the person checks in before that",
        )
    return UserChange(user_id, "unsuspend", before, "active", changed=True, notes=notes)
