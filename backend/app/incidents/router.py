"""``/v1/incidents`` (API_SPEC §9). HTTP only: parse, authenticate, call the service."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from fastapi.responses import JSONResponse

from app.api.deps import (
    ContextDep,
    CurrentUserDep,
    DbSession,
    IdempotencyKeyDep,
    ReauthUserDep,
    ServicesDep,
)
from app.core.pagination import LIMIT_DEFAULT, LIMIT_MAX
from app.incidents.schemas import IncidentCurrent, IncidentOut, IncidentPage, SafeResponse
from app.incidents.service import IncidentService

router = APIRouter(prefix="/v1", tags=["incidents"])


def get_incident_service(
    session: DbSession, services: ServicesDep, ctx: ContextDep
) -> IncidentService:
    return IncidentService(session=session, services=services, ctx=ctx)


IncidentServiceDep = Annotated[IncidentService, Depends(get_incident_service)]


@router.get("/incidents/current")
async def current_incident(current: CurrentUserDep, service: IncidentServiceDep) -> IncidentCurrent:
    return await service.current(current)


@router.get("/incidents")
async def list_incidents(
    current: CurrentUserDep,
    service: IncidentServiceDep,
    limit: Annotated[int, Query(ge=1, le=LIMIT_MAX)] = LIMIT_DEFAULT,
    cursor: Annotated[str | None, Query(max_length=256)] = None,
) -> IncidentPage:
    return await service.history(current, limit, cursor)


@router.get("/incidents/{incident_id}")
async def get_incident(
    incident_id: uuid.UUID, current: CurrentUserDep, service: IncidentServiceDep
) -> IncidentOut:
    return await service.detail(current, incident_id)


@router.post("/incidents/{incident_id}/safe", response_model=SafeResponse)
async def confirm_safe(
    incident_id: uuid.UUID,
    current: ReauthUserDep,
    service: IncidentServiceDep,
    key: IdempotencyKeyDep,
) -> JSONResponse:
    body, replayed = await service.safe(current, incident_id, key)
    headers = {"Idempotent-Replayed": "true"} if replayed else None
    return JSONResponse(body, headers=headers)
