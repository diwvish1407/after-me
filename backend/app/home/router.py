"""``GET /v1/home`` (API_SPEC §5)."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends

from app.api.deps import ContextDep, CurrentUserDep, DbSession, ServicesDep
from app.home.schemas import HomeResponse
from app.home.service import HomeService

router = APIRouter(prefix="/v1", tags=["home"])


def get_home_service(session: DbSession, services: ServicesDep, ctx: ContextDep) -> HomeService:
    return HomeService(session=session, services=services, ctx=ctx)


HomeServiceDep = Annotated[HomeService, Depends(get_home_service)]


@router.get("/home")
async def get_home(current: CurrentUserDep, service: HomeServiceDep) -> HomeResponse:
    return await service.home(current)
