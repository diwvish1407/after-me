"""Device registration: the push token of the phone this session runs on (API_SPEC §4).

A token belongs to one device. When the same token is registered by another account's device
(a phone that changed hands, a restored backup), it is detached from the old one first: pushes
for the previous owner must never reach this phone's new owner (SECURITY T21).
"""

from __future__ import annotations

from app.api.deps import CurrentUser
from app.auth.base import AuthServiceBase
from app.core.errors import InvalidState, NotFound
from app.devices.schemas import DeviceResponse, DeviceUpdateRequest


class DeviceService(AuthServiceBase):
    async def update_current(
        self, current: CurrentUser, body: DeviceUpdateRequest
    ) -> DeviceResponse:
        device_id = current.device_id
        if device_id is None:  # a web session has no phone
            raise InvalidState("This session has no device.")
        now = await self._now()
        device = await self.devices.get(owner_id=current.user_id, device_id=device_id)
        if device is None:
            raise NotFound
        fields = body.model_fields_set
        if "push_token" in fields and body.push_token is not None:
            await self.devices.detach_token_elsewhere(
                token=body.push_token, keep=device.id, now=now
            )
        await self.devices.update_info(
            owner_id=current.user_id,
            device_id=device.id,
            app_version=body.app_version,
            os_version=body.os_version,
            locale=body.locale,
            now=now,
        )
        if "push_token" in fields:
            if body.push_token is None:
                await self.devices.clear_push_token(
                    owner_id=current.user_id, device_id=device.id, now=now
                )
            else:
                await self.devices.set_push_token(
                    owner_id=current.user_id, device_id=device.id, token=body.push_token, now=now
                )
        refreshed = await self.devices.get(owner_id=current.user_id, device_id=device.id)
        await self.session.commit()
        return DeviceResponse(
            device_id=device.id,
            push_registered=refreshed is not None and refreshed.push_token is not None,
        )

    async def clear_push_token(self, current: CurrentUser) -> None:
        device_id = current.device_id
        if device_id is None:
            raise InvalidState("This session has no device.")
        now = await self._now()
        await self.devices.clear_push_token(owner_id=current.user_id, device_id=device_id, now=now)
        await self.session.commit()
