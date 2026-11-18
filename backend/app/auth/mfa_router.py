"""``/v1/me/2fa``: two-step verification with an authenticator app."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Response, status

from app.api.deps import ContextDep, CurrentUserDep, DbSession, ServicesDep
from app.auth.mfa_service import MfaService
from app.auth.schemas import MfaCodeRequest, MfaEnabledOut, MfaSetupOut, MfaStatusOut

router = APIRouter(prefix="/v1/me/2fa", tags=["two-step verification"])


def get_mfa_service(session: DbSession, services: ServicesDep, ctx: ContextDep) -> MfaService:
    return MfaService(session=session, services=services, ctx=ctx)


MfaServiceDep = Annotated[MfaService, Depends(get_mfa_service)]


@router.get("")
async def mfa_status(current: CurrentUserDep, service: MfaServiceDep) -> MfaStatusOut:
    return await service.status(current)


@router.post("/setup")
async def mfa_setup(current: CurrentUserDep, service: MfaServiceDep) -> MfaSetupOut:
    """Needs a fresh re-authentication (``POST /v1/auth/reauth``)."""
    return await service.setup(current)


@router.post("/enable")
async def mfa_enable(
    body: MfaCodeRequest, current: CurrentUserDep, service: MfaServiceDep
) -> MfaEnabledOut:
    return await service.enable(current, body.code)


@router.post("/disable", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def mfa_disable(
    body: MfaCodeRequest, current: CurrentUserDep, service: MfaServiceDep
) -> Response:
    """Needs a fresh re-authentication and a current code (or a recovery code)."""
    await service.disable(current, body.code)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
