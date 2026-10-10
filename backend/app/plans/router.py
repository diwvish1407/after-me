"""``/v1/plan`` (API_SPEC §8). HTTP only: parse, authenticate, call the service."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Header, Response

from app.api.deps import ContextDep, CurrentUserDep, DbSession, ServicesDep
from app.plans.schemas import PlanOut, PlanPutRequest
from app.plans.service import PlanService, plan_etag

router = APIRouter(prefix="/v1", tags=["plan"])


def get_plan_service(session: DbSession, services: ServicesDep, ctx: ContextDep) -> PlanService:
    return PlanService(session=session, services=services, ctx=ctx)


PlanServiceDep = Annotated[PlanService, Depends(get_plan_service)]


@router.get("/plan")
async def get_plan(current: CurrentUserDep, service: PlanServiceDep, response: Response) -> PlanOut:
    plan = await service.get_plan(current)
    response.headers["ETag"] = plan_etag(plan.version)
    return plan


@router.put("/plan")
async def put_plan(
    body: PlanPutRequest,
    current: CurrentUserDep,
    service: PlanServiceDep,
    response: Response,
    if_match: Annotated[str | None, Header(alias="If-Match")] = None,
) -> PlanOut:
    plan = await service.put_plan(current, if_match, body)
    response.headers["ETag"] = plan_etag(plan.version)
    return plan
