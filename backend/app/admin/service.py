"""Administrator operations. Every route needs ``role = 'admin'``; every change also needs a
fresh re-authentication and is written to the audit trail with the admin as the actor (the
operator commands in app/ops record the admin as ``operator``). Admins see each account's
status, schedule, check-in events, contacts (names and status, masked addresses) and
incidents, never instruction content (it is end-to-end sealed for the owner's contacts).
"""

from __future__ import annotations

import uuid
from datetime import timedelta

from sqlalchemy import func, or_, select

from app.admin.schemas import (
    AdminChange,
    AdminContact,
    AdminEvent,
    AdminHoldStatus,
    AdminIncident,
    AdminIncidentPage,
    AdminOverview,
    AdminUserDetail,
    AdminUserPage,
    AdminUserRow,
)
from app.api.deps import CurrentUser, has_fresh_reauth
from app.audit import writer as audit
from app.audit.writer import AuditEvent
from app.auth.base import AuthServiceBase
from app.auth.models import User
from app.checkins.models import CheckinConfiguration, CheckinEvent, CheckinSlot
from app.checkins.schedule import format_hhmm
from app.contacts.models import TrustedContact
from app.core.errors import InvalidState, NotFound, ReauthRequired
from app.incidents.models import OPEN_STATUSES, EscalationIncident
from app.instructions.repository import InstructionRepository
from app.ops import admin as ops_admin
from app.ops import users as ops_users
from app.ops.models import SystemHold
from app.users.models import UserProfile


def _mask(email: str | None) -> str | None:
    if not email or "@" not in email:
        return None
    name, _, domain = email.partition("@")
    return f"{name[:1]}***@{domain}"


class AdminService(AuthServiceBase):
    def _operator(self, admin: CurrentUser) -> str:
        return f"admin-{str(admin.user_id)[:8]}"

    async def _require_fresh(self, admin: CurrentUser) -> None:
        if not has_fresh_reauth(admin, await self._now()):
            raise ReauthRequired

    # ------------------------------------------------------------------ read

    async def overview(self) -> AdminOverview:
        now = await self._now()

        async def count(stmt: object) -> int:
            return int((await self.session.execute(stmt)).scalar_one())  # type: ignore[call-overload]

        by_status: dict[str, int] = {
            str(status): int(n)
            for status, n in (
                await self.session.execute(select(User.status, func.count()).group_by(User.status))
            ).all()
        }
        out = AdminOverview(
            users_total=sum(by_status.values()),
            users_active=by_status.get("active", 0),
            users_suspended=by_status.get("suspended", 0),
            users_pending_deletion=by_status.get("pending_deletion", 0),
            users_premium=await count(
                select(func.count()).select_from(User).where(User.tier == "premium")
            ),
            schedules_active=await count(
                select(func.count())
                .select_from(CheckinConfiguration)
                .where(CheckinConfiguration.status != "inactive")
            ),
            incidents_open=await count(
                select(func.count())
                .select_from(EscalationIncident)
                .where(EscalationIncident.status.in_(OPEN_STATUSES))
            ),
            checkins_24h=await count(
                select(func.count())
                .select_from(CheckinEvent)
                .where(CheckinEvent.received_at > now - timedelta(hours=24))
            ),
            signups_7d=await count(
                select(func.count())
                .select_from(User)
                .where(User.created_at > now - timedelta(days=7))
            ),
            hold_active=await count(
                select(func.count()).select_from(SystemHold).where(SystemHold.ended_at.is_(None))
            )
            > 0,
        )
        await self.session.commit()
        return out

    def _row(
        self, user: User, profile: UserProfile | None, cfg: CheckinConfiguration | None
    ) -> AdminUserRow:
        return AdminUserRow(
            id=user.id,
            email=user.email,
            display_name=profile.display_name if profile is not None else None,
            status=user.status,
            tier=user.tier,
            role=user.role,
            schedule_status=cfg.status if cfg is not None else None,
            next_due_at=cfg.next_due_at if cfg is not None else None,
            last_checkin_at=cfg.last_checkin_at if cfg is not None else None,
            created_at=user.created_at,
        )

    async def list_users(self, query: str | None, limit: int, offset: int) -> AdminUserPage:
        base = (
            select(User, UserProfile, CheckinConfiguration)
            .outerjoin(UserProfile, UserProfile.user_id == User.id)
            .outerjoin(CheckinConfiguration, CheckinConfiguration.user_id == User.id)
        )
        if query:
            like = f"%{query.strip().lower()}%"
            base = base.where(
                or_(
                    User.email_normalized.like(like),
                    func.lower(UserProfile.display_name).like(like),
                )
            )
        total = int(
            (
                await self.session.execute(select(func.count()).select_from(base.subquery()))
            ).scalar_one()
        )
        rows = (
            await self.session.execute(
                base.order_by(User.created_at.desc(), User.id).limit(limit).offset(offset)
            )
        ).all()
        await self.session.commit()
        return AdminUserPage(items=[self._row(u, p, c) for u, p, c in rows], total=total)

    async def _incidents(
        self, user_id: uuid.UUID | None, *, open_only: bool
    ) -> list[AdminIncident]:
        stmt = select(EscalationIncident, User.email).join(
            User, User.id == EscalationIncident.user_id
        )
        if user_id is not None:
            stmt = stmt.where(EscalationIncident.user_id == user_id)
        if open_only:
            stmt = stmt.where(EscalationIncident.status.in_(OPEN_STATUSES))
        stmt = stmt.order_by(EscalationIncident.opened_at.desc()).limit(50)
        return [
            AdminIncident(
                id=i.id,
                user_id=i.user_id,
                email=email,
                status=i.status,
                missed_due_at=i.missed_due_at,
                opened_at=i.opened_at,
                closed_at=i.closed_at,
                closed_by=i.closed_by,
            )
            for i, email in (await self.session.execute(stmt)).all()
        ]

    async def user(self, admin: CurrentUser, user_id: uuid.UUID) -> AdminUserDetail:
        now = await self._now()
        row = (
            await self.session.execute(
                select(User, UserProfile, CheckinConfiguration)
                .outerjoin(UserProfile, UserProfile.user_id == User.id)
                .outerjoin(CheckinConfiguration, CheckinConfiguration.user_id == User.id)
                .where(User.id == user_id)
            )
        ).first()
        if row is None:
            raise NotFound
        user: User = row[0]
        profile: UserProfile | None = row[1]
        cfg: CheckinConfiguration | None = row[2]
        slots = (
            await self.session.execute(
                select(CheckinSlot)
                .where(CheckinSlot.user_id == user_id, CheckinSlot.deleted_at.is_(None))
                .order_by(CheckinSlot.created_at)
            )
        ).scalars()
        contacts = (
            await self.session.execute(
                select(TrustedContact)
                .where(TrustedContact.user_id == user_id, TrustedContact.deleted_at.is_(None))
                .order_by(TrustedContact.priority, TrustedContact.created_at)
            )
        ).scalars()
        detail = AdminUserDetail(
            user=self._row(user, profile, cfg),
            timezone=profile.timezone if profile is not None else None,
            mfa_enabled=user.totp_enabled_at is not None,
            google_linked=user.google_sub is not None,
            interval_days=cfg.interval_days if cfg is not None else None,
            interval_minutes=cfg.interval_minutes if cfg is not None else None,
            due_local_time=format_hhmm(cfg.due_local_time) if cfg is not None else None,
            events=[
                AdminEvent(
                    id=s.id,
                    label=s.label,
                    due_local_time=format_hhmm(s.due_local_time),
                    interval_days=s.interval_days,
                    interval_minutes=s.interval_minutes,
                    next_due_at=s.next_due_at,
                )
                for s in slots
            ],
            contacts=[
                AdminContact(
                    id=c.id,
                    display_name=c.display_name,
                    relationship=c.relationship_label or c.relationship,
                    email_masked=_mask(c.email),
                    verification_status=c.verification_status,
                    is_active=c.is_active,
                )
                for c in contacts
            ],
            instructions_active=await InstructionRepository(self.session).count_active(
                owner_id=user_id
            ),
            incidents=await self._incidents(user_id, open_only=False),
        )
        await self.services.audit.record(
            self.session,
            AuditEvent(
                action=audit.ADMIN_VIEWED_USER,
                occurred_at=now,
                subject_user_id=user_id,
                actor_type="operator",
                actor_id=admin.user_id,
                resource_type="user",
                resource_id=user_id,
                user_visible=False,
            ),
        )
        await self.session.commit()
        return detail

    async def incidents(self, *, open_only: bool) -> AdminIncidentPage:
        items = await self._incidents(None, open_only=open_only)
        await self.session.commit()
        return AdminIncidentPage(items=items)

    async def hold_status(self) -> AdminHoldStatus:
        holds = (
            await self.session.execute(
                select(SystemHold)
                .where(SystemHold.ended_at.is_(None))
                .order_by(SystemHold.started_at)
            )
        ).scalars()
        out: list[dict[str, str | None]] = [
            {"id": str(h.id), "reason": h.reason, "started_at": h.started_at.isoformat()}
            for h in holds
        ]
        await self.session.commit()
        return AdminHoldStatus(active=bool(out), holds=out)

    # ------------------------------------------------------------------ change

    def _change(self, change: ops_users.UserChange) -> AdminChange:
        return AdminChange(
            changed=change.changed,
            before=change.before,
            after=change.after,
            notes=list(change.notes),
        )

    async def _guard(self, admin: CurrentUser, user_id: uuid.UUID) -> None:
        await self._require_fresh(admin)
        await self.session.commit()  # the operator commands use their own transactions
        if user_id == admin.user_id:
            raise InvalidState("You cannot change your own account from the admin screen.")

    async def set_tier(
        self, admin: CurrentUser, user_id: uuid.UUID, tier: str, reason: str
    ) -> AdminChange:
        await self._guard(admin, user_id)
        try:
            change = await ops_users.set_tier(
                self.services,
                operator=self._operator(admin),
                user_id=user_id,
                tier=tier,
                reason=reason,
            )
        except ops_users.UserCommandError as exc:
            raise InvalidState(str(exc)) from exc
        return self._change(change)

    async def suspend(self, admin: CurrentUser, user_id: uuid.UUID, reason: str) -> AdminChange:
        await self._guard(admin, user_id)
        try:
            change = await ops_users.suspend(
                self.services, operator=self._operator(admin), user_id=user_id, reason=reason
            )
        except ops_users.UserCommandError as exc:
            raise InvalidState(str(exc)) from exc
        return self._change(change)

    async def unsuspend(self, admin: CurrentUser, user_id: uuid.UUID, reason: str) -> AdminChange:
        await self._guard(admin, user_id)
        try:
            change = await ops_users.unsuspend(
                self.services, operator=self._operator(admin), user_id=user_id, reason=reason
            )
        except ops_users.UserCommandError as exc:
            raise InvalidState(str(exc)) from exc
        return self._change(change)

    async def set_role(self, admin: CurrentUser, user_id: uuid.UUID, role: str) -> AdminChange:
        await self._guard(admin, user_id)
        now = await self._now()
        user = await self.users.get(user_id, for_update=True)
        if user is None:
            raise NotFound
        before = user.role
        if before != role:
            user.role = role
            user.updated_at = now
            await self.services.audit.record(
                self.session,
                AuditEvent(
                    action=audit.ADMIN_SET_ROLE,
                    occurred_at=now,
                    subject_user_id=user_id,
                    actor_type="operator",
                    actor_id=admin.user_id,
                    resource_type="user",
                    resource_id=user_id,
                    metadata={"from_role": before, "to_role": role},
                    user_visible=False,
                ),
            )
        await self.session.commit()
        return AdminChange(changed=before != role, before=before, after=role, notes=[])

    async def void_incident(self, admin: CurrentUser, incident_id: uuid.UUID) -> bool:
        await self._require_fresh(admin)
        await self.session.commit()
        try:
            return await ops_admin.void_incident(
                self.services, operator=self._operator(admin), incident_id=incident_id
            )
        except RuntimeError as exc:
            raise InvalidState(str(exc)) from exc

    async def hold_enter(self, admin: CurrentUser, reason: str) -> AdminHoldStatus:
        await self._require_fresh(admin)
        await self.session.commit()
        await ops_admin.hold_enter(self.services, operator=self._operator(admin), reason=reason)
        return await self.hold_status()

    async def hold_exit(self, admin: CurrentUser) -> AdminHoldStatus:
        await self._require_fresh(admin)
        await self.session.commit()
        await ops_admin.hold_exit(self.services, operator=self._operator(admin))
        return await self.hold_status()
