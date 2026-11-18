"""``/v1/admin``: the administrator API. Admins only (``users.role = 'admin'``)."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query

from app.admin.schemas import (
    AdminChange,
    AdminHoldStatus,
    AdminIncidentPage,
    AdminOverview,
    AdminUserDetail,
    AdminUserPage,
    ReasonRequest,
    RoleRequest,
    TierRequest,
)
from app.admin.service import AdminService
from app.api.deps import ContextDep, CurrentUser, CurrentUserDep, DbSession, ServicesDep
from app.core.errors import AdminRequired, NotFound

router = APIRouter(prefix="/v1/admin", tags=["admin"])


def require_admin(current: CurrentUserDep) -> CurrentUser:
    if current.role != "admin":
        raise AdminRequired
    return current


AdminDep = Annotated[CurrentUser, Depends(require_admin)]


def get_admin_service(session: DbSession, services: ServicesDep, ctx: ContextDep) -> AdminService:
    return AdminService(session=session, services=services, ctx=ctx)


AdminServiceDep = Annotated[AdminService, Depends(get_admin_service)]


@router.get("/overview")
async def overview(admin: AdminDep, service: AdminServiceDep) -> AdminOverview:
    return await service.overview()


@router.get("/users")
async def list_users(
    admin: AdminDep,
    service: AdminServiceDep,
    q: Annotated[str | None, Query(max_length=100)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 25,
    offset: Annotated[int, Query(ge=0, le=100_000)] = 0,
) -> AdminUserPage:
    return await service.list_users(q, limit, offset)


@router.get("/users/{user_id}")
async def user_detail(
    user_id: uuid.UUID, admin: AdminDep, service: AdminServiceDep
) -> AdminUserDetail:
    return await service.user(admin, user_id)


@router.post("/users/{user_id}/tier")
async def set_tier(
    user_id: uuid.UUID, body: TierRequest, admin: AdminDep, service: AdminServiceDep
) -> AdminChange:
    return await service.set_tier(admin, user_id, body.tier, body.reason)


@router.post("/users/{user_id}/suspend")
async def suspend(
    user_id: uuid.UUID, body: ReasonRequest, admin: AdminDep, service: AdminServiceDep
) -> AdminChange:
    return await service.suspend(admin, user_id, body.reason)


@router.post("/users/{user_id}/unsuspend")
async def unsuspend(
    user_id: uuid.UUID, body: ReasonRequest, admin: AdminDep, service: AdminServiceDep
) -> AdminChange:
    return await service.unsuspend(admin, user_id, body.reason)


@router.post("/users/{user_id}/role")
async def set_role(
    user_id: uuid.UUID, body: RoleRequest, admin: AdminDep, service: AdminServiceDep
) -> AdminChange:
    return await service.set_role(admin, user_id, body.role)


@router.get("/incidents")
async def incidents(
    admin: AdminDep,
    service: AdminServiceDep,
    open_only: Annotated[bool, Query(alias="open")] = True,
) -> AdminIncidentPage:
    return await service.incidents(open_only=open_only)


@router.post("/incidents/{incident_id}/void")
async def void_incident(
    incident_id: uuid.UUID, admin: AdminDep, service: AdminServiceDep
) -> dict[str, bool]:
    if not await service.void_incident(admin, incident_id):
        raise NotFound
    return {"voided": True}


@router.get("/hold")
async def hold_status(admin: AdminDep, service: AdminServiceDep) -> AdminHoldStatus:
    return await service.hold_status()


@router.post("/hold/enter")
async def hold_enter(
    body: ReasonRequest, admin: AdminDep, service: AdminServiceDep
) -> AdminHoldStatus:
    return await service.hold_enter(admin, body.reason)


@router.post("/hold/exit")
async def hold_exit(admin: AdminDep, service: AdminServiceDep) -> AdminHoldStatus:
    return await service.hold_exit(admin)
