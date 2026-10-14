"""Everything the Home screen needs in one call (API_SPEC §5).

Read-only. The incident object and the plan counters are placeholders until Phase 5 and 6 add
the plan, incidents and instructions; the contact and schedule parts are real.
"""

from __future__ import annotations

import uuid
from typing import Final

from app.api.deps import CurrentUser
from app.auth.base import AuthServiceBase
from app.checkins.repository import CheckinConfigRepository
from app.checkins.schedule import format_hhmm
from app.contacts.models import TrustedContact
from app.contacts.repository import ContactRepository
from app.core.errors import NotFound
from app.home.repository import ActivityRepository, service_interruption
from app.home.schemas import (
    ActivityItem,
    HomeCheckin,
    HomeResponse,
    HomeSchedule,
    HomeUser,
    PlanSummary,
    Readiness,
    ReadinessCode,
    ReadinessIssue,
    ServiceStatus,
)
from app.incidents.repository import IncidentRepository
from app.incidents.service import IncidentService
from app.instructions.repository import InstructionRepository
from app.plans.repository import PlanRepository

RECENT_ACTIVITY_LIMIT: Final = 5

_CONTACT_ISSUE: Final[dict[str, ReadinessCode]] = {
    "pending": "contact_pending",
    "declined": "contact_declined",
    "bounced": "contact_bounced",
    "opted_out": "contact_opted_out",
}


def readiness_issues(
    schedule_status: str,
    contacts: list[TrustedContact],
    stage_rows: list[tuple[uuid.UUID, uuid.UUID | None]] | None = None,
) -> list[ReadinessIssue]:
    """What stands between this account and a working safety net. Only contacts that are switched
    on are judged; a verified one raises nothing."""
    issues: list[ReadinessIssue] = []
    if schedule_status == "inactive":
        issues.append(ReadinessIssue(code="schedule_inactive", contact_id=None))
    active = [c for c in contacts if c.is_active]
    if not active:
        issues.append(ReadinessIssue(code="no_contacts", contact_id=None))
    for contact in active:
        code = _CONTACT_ISSUE.get(contact.verification_status)
        if code is not None:
            issues.append(ReadinessIssue(code=code, contact_id=contact.id))
    rows = stage_rows or []
    if not rows:
        issues.append(ReadinessIssue(code="no_stages", contact_id=None))
    else:
        active_ids = {c.id for c in active}
        stages: dict[uuid.UUID, bool] = {}
        for step_id, contact_id in rows:
            stages[step_id] = stages.get(step_id, False) or contact_id in active_ids
        if not all(stages.values()):
            issues.append(ReadinessIssue(code="stage_empty", contact_id=None))
    return issues


class HomeService(AuthServiceBase):
    async def home(self, current: CurrentUser) -> HomeResponse:
        now = await self._now()
        cfg = await CheckinConfigRepository(self.session).get(owner_id=current.user_id)
        profile = await self.profiles.get(owner_id=current.user_id)
        if cfg is None or profile is None:  # pragma: no cover - created at signup verification
            raise NotFound
        contacts = await ContactRepository(self.session).list(owner_id=current.user_id)
        stage_rows = await PlanRepository(self.session).stage_contacts(owner_id=current.user_id)
        activity = await ActivityRepository(self.session).recent_visible(
            owner_id=current.user_id, limit=RECENT_ACTIVITY_LIMIT
        )
        instructions_active = await InstructionRepository(self.session).count_active(
            owner_id=current.user_id
        )
        open_incident = await IncidentRepository(self.session).get_open(owner_id=current.user_id)
        incident_view = None
        if open_incident is not None:
            incidents = IncidentService(session=self.session, services=self.services, ctx=self.ctx)
            incident_view = (await incidents.view(current.user_id, open_incident, now)).model_dump(
                mode="json"
            )
        interruption = await service_interruption(self.session)
        await self.session.commit()

        issues = readiness_issues(cfg.status, contacts, stage_rows)
        return HomeResponse(
            server_time=now,
            user=HomeUser(
                display_name=profile.display_name, tier=current.tier, timezone=profile.timezone
            ),
            checkin=HomeCheckin(
                status=cfg.status,  # type: ignore[arg-type]
                next_due_at=cfg.next_due_at,
                last_checkin_at=cfg.last_checkin_at,
                schedule=HomeSchedule(
                    interval_days=cfg.interval_days,
                    due_local_time=format_hhmm(cfg.due_local_time),
                    reminder_lead_minutes=cfg.reminder_lead_minutes,  # type: ignore[arg-type]
                ),
            ),
            incident=incident_view,
            plan_summary=PlanSummary(
                stages=len({step_id for step_id, _ in stage_rows}),
                contacts_total=len(contacts),
                contacts_verified=sum(1 for c in contacts if c.verification_status == "verified"),
                instructions_active=instructions_active,
            ),
            readiness=Readiness(ready=not issues, issues=issues),
            recent_activity=[
                ActivityItem(action=a.action, occurred_at=a.occurred_at) for a in activity
            ],
            service=ServiceStatus(interruption=interruption),
        )
