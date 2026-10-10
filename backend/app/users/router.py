"""``/v1/me`` (API_SPEC §3)."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends

from app.api.deps import ContextDep, CurrentUserDep, DbSession, ServicesDep
from app.users.entitlements import EntitlementService
from app.users.schemas import EntitlementsResponse, MeResponse, ProfilePatchRequest
from app.users.service import UserService

router = APIRouter(prefix="/v1", tags=["me"])


def get_user_service(session: DbSession, services: ServicesDep, ctx: ContextDep) -> UserService:
    return UserService(session=session, services=services, ctx=ctx)


UserServiceDep = Annotated[UserService, Depends(get_user_service)]


@router.get("/me")
async def get_me(current: CurrentUserDep, service: UserServiceDep) -> MeResponse:
    return await service.get_me(current)


@router.patch("/me/profile")
async def patch_profile(
    body: ProfilePatchRequest, current: CurrentUserDep, service: UserServiceDep
) -> MeResponse:
    return await service.update_profile(current, body)


@router.get("/me/entitlements")
async def get_entitlements(
    current: CurrentUserDep, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> EntitlementsResponse:
    return await EntitlementService(session=session, services=services, ctx=ctx).entitlements(
        current
    )
