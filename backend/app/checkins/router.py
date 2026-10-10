"""``/v1/checkin/*`` and ``/v1/checkins`` routes (API_SPEC §6). HTTP only: parse, authenticate,
call the service."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Header, Query, Response
from fastapi.responses import JSONResponse

from app.api.deps import (
    ContextDep,
    CurrentUserDep,
    DbSession,
    IdempotencyKeyDep,
    ReauthUserDep,
    ServicesDep,
)
from app.checkins.schemas import (
    CheckinPage,
    CheckinRequest,
    CheckinResponse,
    ScheduleOut,
    SchedulePutRequest,
)
from app.checkins.service import CheckinService, schedule_etag
from app.core.pagination import LIMIT_DEFAULT, LIMIT_MAX

router = APIRouter(prefix="/v1", tags=["checkin"])


def get_checkin_service(
    session: DbSession, services: ServicesDep, ctx: ContextDep
) -> CheckinService:
    return CheckinService(session=session, services=services, ctx=ctx)


CheckinServiceDep = Annotated[CheckinService, Depends(get_checkin_service)]


def _with_etag(schedule: ScheduleOut, response: Response) -> ScheduleOut:
    response.headers["ETag"] = schedule_etag(schedule.version)
    return schedule


@router.get("/checkin/schedule")
async def get_schedule(
    current: CurrentUserDep, service: CheckinServiceDep, response: Response
) -> ScheduleOut:
    return _with_etag(await service.get_schedule(current), response)


@router.put("/checkin/schedule")
async def put_schedule(
    body: SchedulePutRequest,
    current: CurrentUserDep,
    service: CheckinServiceDep,
    response: Response,
    if_match: Annotated[str | None, Header(alias="If-Match")] = None,
) -> ScheduleOut:
    return _with_etag(await service.put_schedule(current, if_match, body), response)


@router.post("/checkin/activate")
async def activate(
    current: CurrentUserDep, service: CheckinServiceDep, response: Response
) -> ScheduleOut:
    return _with_etag(await service.activate(current), response)


@router.post("/checkin/deactivate")
async def deactivate(
    current: ReauthUserDep, service: CheckinServiceDep, response: Response
) -> ScheduleOut:
    return _with_etag(await service.deactivate(current), response)


@router.post("/checkins", response_model=CheckinResponse)
async def record_checkin(
    current: CurrentUserDep,
    service: CheckinServiceDep,
    key: IdempotencyKeyDep,
    body: CheckinRequest | None = None,
) -> JSONResponse:
    result, replayed = await service.record(current, key, body)
    # A replay is the stored JSON as it was first sent, ``server_time`` included. A client must
    # not use a replayed ``server_time`` to calibrate its clock, hence the marker header.
    headers = {"Idempotent-Replayed": "true"} if replayed else None
    return JSONResponse(result, headers=headers)


@router.get("/checkins")
async def list_checkins(
    current: CurrentUserDep,
    service: CheckinServiceDep,
    limit: Annotated[int, Query(ge=1, le=LIMIT_MAX)] = LIMIT_DEFAULT,
    cursor: Annotated[str | None, Query(max_length=256)] = None,
) -> CheckinPage:
    return await service.history(current, limit, cursor)
