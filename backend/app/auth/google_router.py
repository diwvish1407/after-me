"""``POST /v1/auth/google``: Sign in with Google."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends

from app.api.deps import ContextDep, DbSession, ServicesDep
from app.auth.google_service import GoogleAuthService
from app.auth.router import _login_ip_limit, _token_response
from app.auth.schemas import GoogleLoginRequest, TokenResponse

router = APIRouter(prefix="/v1/auth", tags=["auth"])


def get_google_service(
    session: DbSession, services: ServicesDep, ctx: ContextDep
) -> GoogleAuthService:
    return GoogleAuthService(session=session, services=services, ctx=ctx)


@router.post("/google", dependencies=[_login_ip_limit])
async def google_login(
    body: GoogleLoginRequest,
    service: Annotated[GoogleAuthService, Depends(get_google_service)],
) -> TokenResponse:
    return _token_response(await service.google_login(body))
