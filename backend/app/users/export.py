"""``POST /v1/me/export``: everything AfterMe holds about the account, in one JSON document
(API_SPEC §3, SECURITY §10).

The caller has just proved their password (re-auth). Instruction text is opened for the owner
only; a text that cannot be opened is listed with an error instead of being left out, so an
export never looks complete when it is not. Nothing about other people's *accounts* is in it:
contacts appear as the owner entered them. The export is audited (``account.exported``), is
rate-limited, and the response is never cached.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Final

from app.activity.service import ActivityService
from app.api.deps import CurrentUser
from app.audit import writer as audit
from app.auth.base import AuthServiceBase
from app.checkins.repository import CheckinEventRepository
from app.checkins.service import CheckinService
from app.contacts.service import ContactService
from app.incidents.repository import IncidentRepository
from app.incidents.service import IncidentService
from app.instructions.reader import open_texts
from app.instructions.repository import InstructionRepository
from app.instructions.service import recipient_out
from app.plans.service import PlanService
from app.security.rate_limit import EXPORT_PER_USER
from app.users.service import UserService

FORMAT_VERSION: Final = 1
_PAGE: Final = 100
_MAX_PAGES: Final = 100  # 10,000 rows of any one list; beyond that the export says so


class ExportService(AuthServiceBase):
    async def build(self, current: CurrentUser) -> dict[str, Any]:
        now = await self._now()
        await self._limit(EXPORT_PER_USER, str(current.user_id), now)

        s, v, c = self.session, self.services, self.ctx
        me = await UserService(session=s, services=v, ctx=c).get_me(current)
        contacts = await ContactService(session=s, services=v, ctx=c).list_contacts(current)
        schedule = await CheckinService(session=s, services=v, ctx=c).get_schedule(current)
        plan = await PlanService(session=s, services=v, ctx=c).get_plan(current)
        instructions = await self._instructions(current)
        checkins, checkins_truncated = await self._checkins(current)
        incidents, incidents_truncated = await self._incidents(current, now)
        activity, activity_truncated = await self._activity(current)

        await self.services.audit.record(
            self.session,
            self._event(audit.ACCOUNT_EXPORTED, now, current.user_id, resource_type="account"),
        )
        # The confirmation is spent: a second export asks for the password again.
        await self.sessions.clear_reauthenticated(
            owner_id=current.user_id, session_id=current.session_id
        )
        await self.session.commit()
        return {
            "format_version": FORMAT_VERSION,
            "exported_at": _utc(now),
            "account": me.model_dump(mode="json"),
            "contacts": contacts.model_dump(mode="json")["items"],
            "schedule": schedule.model_dump(mode="json"),
            "plan": plan.model_dump(mode="json"),
            "instructions": instructions,
            "checkins": checkins,
            "incidents": incidents,
            "activity": activity,
            "truncated": {
                "checkins": checkins_truncated,
                "incidents": incidents_truncated,
                "activity": activity_truncated,
            },
        }

    # ------------------------------------------------------------------ parts

    async def _instructions(self, current: CurrentUser) -> list[dict[str, Any]]:
        items = InstructionRepository(self.session)
        rows = await items.list_live(owner_id=current.user_id, category=None)
        recipients = await items.recipients(
            owner_id=current.user_id, instruction_ids=[r.id for r in rows]
        )
        texts = await open_texts(
            self.session,
            self.services.vault,
            owner_id=current.user_id,
            instruction_ids=[r.id for r in rows],
        )
        out: list[dict[str, Any]] = []
        for row in rows:
            opened = texts.get(row.id)
            entry: dict[str, Any] = {
                "id": str(row.id),
                "category": row.category_id,
                "status": row.status,
                "created_at": _utc(row.created_at),
                "updated_at": _utc(row.updated_at),
                "recipients": [
                    recipient_out(r).model_dump(mode="json")
                    for r in recipients
                    if r.instruction_id == row.id
                ],
            }
            if opened is None:
                entry["error"] = "content_unavailable"
            else:
                entry["title"], entry["body"] = opened
            out.append(entry)
        return out

    async def _checkins(self, current: CurrentUser) -> tuple[list[dict[str, Any]], bool]:
        events = CheckinEventRepository(self.session)
        out: list[dict[str, Any]] = []
        after = None
        for _ in range(_MAX_PAGES):
            rows = await events.page(owner_id=current.user_id, limit=_PAGE + 1, after=after)
            page = rows[:_PAGE]
            out.extend(
                {
                    "id": str(e.id),
                    "kind": e.kind,
                    "source": e.source,
                    "received_at": _utc(e.received_at),
                }
                for e in page
            )
            if len(rows) <= _PAGE:
                return out, False
            after = (page[-1].received_at, page[-1].id)
        return out, True

    async def _incidents(
        self, current: CurrentUser, now: datetime
    ) -> tuple[list[dict[str, Any]], bool]:
        repo = IncidentRepository(self.session)
        service = IncidentService(session=self.session, services=self.services, ctx=self.ctx)
        out: list[dict[str, Any]] = []
        after = None
        for _ in range(_MAX_PAGES):
            rows = await repo.page(owner_id=current.user_id, limit=_PAGE + 1, after=after)
            page = rows[:_PAGE]
            for incident in page:
                view = await service.view(current.user_id, incident, now)
                out.append(view.model_dump(mode="json"))
            if len(rows) <= _PAGE:
                return out, False
            after = (page[-1].opened_at, page[-1].id)
        return out, True

    async def _activity(self, current: CurrentUser) -> tuple[list[dict[str, Any]], bool]:
        service = ActivityService(session=self.session, services=self.services)
        out: list[dict[str, Any]] = []
        cursor: str | None = None
        for _ in range(_MAX_PAGES):
            page = await service.page(current, _PAGE, cursor)
            out.extend(item.model_dump(mode="json") for item in page.items)
            if page.next_cursor is None:
                return out, False
            cursor = page.next_cursor
        return out, True


def _utc(value: datetime) -> str:
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")
