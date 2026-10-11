"""``/v1/devices`` (API_SPEC §4). HTTP only: parse, authenticate, call the service."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Response, status

from app.api.deps import ContextDep, CurrentUserDep, DbSession, ServicesDep
from app.devices.schemas import DeviceResponse, DeviceUpdateRequest
from app.devices.service import DeviceService

router = APIRouter(prefix="/v1", tags=["devices"])


def get_device_service(session: DbSession, services: ServicesDep, ctx: ContextDep) -> DeviceService:
    return DeviceService(session=session, services=services, ctx=ctx)


DeviceServiceDep = Annotated[DeviceService, Depends(get_device_service)]


@router.put("/devices/current")
async def update_current_device(
    body: DeviceUpdateRequest, current: CurrentUserDep, service: DeviceServiceDep
) -> DeviceResponse:
    return await service.update_current(current, body)


@router.delete(
    "/devices/current/push-token",
    status_code=status.HTTP_204_NO_CONTENT,
    response_class=Response,
)
async def delete_push_token(current: CurrentUserDep, service: DeviceServiceDep) -> Response:
    await service.clear_push_token(current)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
