"""``GET /v1/activity`` (API_SPEC §11). HTTP only: parse, authenticate, call the service."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Query

from app.activity.schemas import ActivityPage
from app.activity.service import ActivityService
from app.api.deps import CurrentUserDep, DbSession, ServicesDep
from app.core.pagination import LIMIT_DEFAULT, LIMIT_MAX

router = APIRouter(prefix="/v1", tags=["activity"])


def get_activity_service(session: DbSession, services: ServicesDep) -> ActivityService:
    return ActivityService(session=session, services=services)


ActivityServiceDep = Annotated[ActivityService, Depends(get_activity_service)]


@router.get("/activity")
async def list_activity(
    current: CurrentUserDep,
    service: ActivityServiceDep,
    limit: Annotated[int, Query(ge=1, le=LIMIT_MAX)] = LIMIT_DEFAULT,
    cursor: Annotated[str | None, Query(max_length=256)] = None,
) -> ActivityPage:
    return await service.page(current, limit, cursor)
