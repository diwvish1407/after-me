"""``/v1/devices`` request and response models (API_SPEC §4)."""

from __future__ import annotations

import uuid
from typing import Annotated, Literal

from pydantic import StringConstraints

from app.auth.schemas import AppVersion, OsVersion
from app.core.schemas import RequestModel, ResponseModel
from app.core.validation import LocaleTag

# An FCM registration token: printable ASCII without spaces (they are about 160 characters).
PushToken = Annotated[str, StringConstraints(pattern=r"^[\x21-\x7e]{20,4096}$")]


class DeviceUpdateRequest(RequestModel):
    """``PUT /v1/devices/current``: what the phone says about itself. ``push_token`` is
    optional: leaving it out keeps the registered token, ``null`` removes it."""

    platform: Literal["android"]
    app_version: AppVersion
    os_version: OsVersion
    locale: LocaleTag
    push_token: PushToken | None = None


class DeviceResponse(ResponseModel):
    device_id: uuid.UUID
    push_registered: bool
