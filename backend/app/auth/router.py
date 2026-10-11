"""``/v1/auth`` routes (API_SPEC §2). HTTP only: parse, authenticate, call the service, map."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, BackgroundTasks, Depends, Response, status

from app.api.deps import (
    ContextDep,
    CurrentUserDep,
    DbSession,
    FreshReauthUserDep,
    ServicesDep,
    ip_rate_limit,
)
from app.auth.account_service import AccountService
from app.auth.schemas import (
    EmailChangeStartRequest,
    EmailChangeStartResponse,
    EmailChangeVerifyRequest,
    ForgotPasswordRequest,
    ForgotPasswordResponse,
    LoginRequest,
    PasswordChangeRequest,
    ReauthRequest,
    RefreshRequest,
    RefreshResponse,
    RegisterResendRequest,
    RegisterStartRequest,
    RegisterStartResponse,
    RegisterVerifyRequest,
    SessionList,
    TokenResponse,
    TokenUser,
)
from app.auth.service import AuthService, IssuedSession
from app.security.rate_limit import (
    DEFAULT_PER_IP,
    FORGOT_PER_IP,
    LOGIN_PER_IP,
    REGISTER_PER_IP,
    VERIFY_PER_IP,
)
from app.users.router import UserServiceDep
from app.users.schemas import MeResponse

router = APIRouter(prefix="/v1/auth", tags=["auth"])

# Per-IP limits for the public routes (API_SPEC §16), counted in one transaction per request.
_register_ip_limit = Depends(ip_rate_limit(DEFAULT_PER_IP, REGISTER_PER_IP))
_verify_ip_limit = Depends(ip_rate_limit(DEFAULT_PER_IP, VERIFY_PER_IP))
_login_ip_limit = Depends(ip_rate_limit(DEFAULT_PER_IP, LOGIN_PER_IP))
_default_ip_limit = Depends(ip_rate_limit(DEFAULT_PER_IP))
_forgot_ip_limit = Depends(ip_rate_limit(DEFAULT_PER_IP, FORGOT_PER_IP))


def get_auth_service(session: DbSession, services: ServicesDep, ctx: ContextDep) -> AuthService:
    return AuthService(session=session, services=services, ctx=ctx)


AuthServiceDep = Annotated[AuthService, Depends(get_auth_service)]


def get_account_service(
    session: DbSession, services: ServicesDep, ctx: ContextDep
) -> AccountService:
    return AccountService(session=session, services=services, ctx=ctx)


AccountServiceDep = Annotated[AccountService, Depends(get_account_service)]


def _token_response(issued: IssuedSession) -> TokenResponse:
    return TokenResponse(
        access_token=issued.access.token,
        access_token_expires_at=issued.access.expires_at,
        refresh_token=issued.refresh_token,
        session_id=issued.session_id,
        device_id=issued.device_id,
        user=TokenUser(id=issued.user_id, email=issued.email, tier=issued.tier),
    )


@router.post(
    "/register/start",
    status_code=status.HTTP_202_ACCEPTED,
    dependencies=[_register_ip_limit],
)
async def register_start(
    body: RegisterStartRequest, service: AuthServiceDep
) -> RegisterStartResponse:
    await service.register_start(body)
    return RegisterStartResponse()


@router.post(
    "/register/verify",
    status_code=status.HTTP_201_CREATED,
    dependencies=[_verify_ip_limit],
)
async def register_verify(body: RegisterVerifyRequest, service: AuthServiceDep) -> TokenResponse:
    return _token_response(await service.register_verify(body))


@router.post(
    "/register/resend",
    status_code=status.HTTP_202_ACCEPTED,
    dependencies=[_register_ip_limit],
)
async def register_resend(
    body: RegisterResendRequest, service: AuthServiceDep
) -> RegisterStartResponse:
    await service.register_resend(body)
    return RegisterStartResponse()


@router.post(
    "/login",
    dependencies=[_login_ip_limit],
)
async def login(body: LoginRequest, service: AuthServiceDep) -> TokenResponse:
    return _token_response(await service.login(body))


@router.post("/refresh", dependencies=[_default_ip_limit])
async def refresh(body: RefreshRequest, service: AuthServiceDep) -> RefreshResponse:
    rotated = await service.refresh(body)
    return RefreshResponse(
        access_token=rotated.access.token,
        access_token_expires_at=rotated.access.expires_at,
        refresh_token=rotated.refresh_token,
    )


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def logout(current: CurrentUserDep, service: AuthServiceDep) -> Response:
    await service.logout(current)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/logout-all", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def logout_all(current: CurrentUserDep, service: AuthServiceDep) -> Response:
    await service.logout_all(current)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/reauth", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def reauth(body: ReauthRequest, current: CurrentUserDep, service: AuthServiceDep) -> Response:
    await service.reauth(current, body)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/sessions")
async def list_sessions(current: CurrentUserDep, service: AuthServiceDep) -> SessionList:
    return await service.list_sessions(current)


@router.delete(
    "/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT, response_class=Response
)
async def revoke_session(
    session_id: uuid.UUID, current: CurrentUserDep, service: AuthServiceDep
) -> Response:
    await service.revoke_session(current, session_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --- passwords and email (API_SPEC §2.4) ---------------------------------------------------------


@router.post(
    "/password/forgot",
    status_code=status.HTTP_202_ACCEPTED,
    dependencies=[_forgot_ip_limit],
)
async def forgot_password(
    body: ForgotPasswordRequest,
    service: AccountServiceDep,
    services: ServicesDep,
    background: BackgroundTasks,
) -> ForgotPasswordResponse:
    outbox = await service.forgot_password(body)
    # Sent after the response in every branch, so delivery time cannot reveal the branch.
    background.add_task(services.mailer.deliver, outbox)
    return ForgotPasswordResponse()


@router.post("/password/change", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def change_password(
    body: PasswordChangeRequest, current: CurrentUserDep, service: AccountServiceDep
) -> Response:
    await service.change_password(current, body)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/email/change/start", status_code=status.HTTP_202_ACCEPTED)
async def email_change_start(
    body: EmailChangeStartRequest,
    current: FreshReauthUserDep,
    service: AccountServiceDep,
    services: ServicesDep,
    background: BackgroundTasks,
) -> EmailChangeStartResponse:
    outbox = await service.email_change_start(current, body)
    background.add_task(services.mailer.deliver, outbox)
    return EmailChangeStartResponse()


@router.post("/email/change/verify")
async def email_change_verify(
    body: EmailChangeVerifyRequest,
    current: CurrentUserDep,
    service: AccountServiceDep,
    users: UserServiceDep,
) -> MeResponse:
    await service.email_change_verify(current, body)
    return await users.get_me(current)
