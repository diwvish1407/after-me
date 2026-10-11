"""``/v1/me`` (API_SPEC §3)."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse

from app.api.deps import (
    ContextDep,
    CurrentUserDep,
    DbSession,
    FreshReauthUserDep,
    ServicesDep,
)
from app.users.deletion import DeletionService
from app.users.entitlements import EntitlementService
from app.users.export import ExportService
from app.users.schemas import (
    DeleteAccountRequest,
    DeletionResponse,
    EntitlementsResponse,
    MeResponse,
    ProfilePatchRequest,
)
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


@router.post("/me/export")
async def export_account(
    current: FreshReauthUserDep, session: DbSession, services: ServicesDep, ctx: ContextDep
) -> JSONResponse:
    """Everything held about the account, as one downloadable JSON file. Needs a fresh
    password confirmation: the document contains the decrypted instructions."""
    body = await ExportService(session=session, services=services, ctx=ctx).build(current)
    return JSONResponse(
        body,
        headers={
            "Content-Disposition": 'attachment; filename="afterme-export.json"',
            "Cache-Control": "no-store",
        },
    )


@router.delete("/me", status_code=202)
async def delete_account(
    body: DeleteAccountRequest,
    current: FreshReauthUserDep,
    session: DbSession,
    services: ServicesDep,
    ctx: ContextDep,
) -> DeletionResponse:
    """Close the account (DATABASE §4). Needs a fresh password confirmation and the word
    DELETE. Everything that can reach another person stops in the same transaction."""
    del body  # validated: the confirmation word is the whole body
    result = await DeletionService(session=session, services=services, ctx=ctx).request(current)
    return DeletionResponse(status="pending_deletion", purge_after=result.purge_after)
