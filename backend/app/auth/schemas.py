"""Auth request/response models (API_SPEC §2)."""

from __future__ import annotations

import uuid
from typing import Annotated, Literal

from pydantic import Field, StringConstraints, ValidationInfo, field_validator
from pydantic_core import PydanticCustomError

from app.auth.codes import CODE_RESEND_INTERVAL
from app.core.schemas import RequestModel, ResponseModel, UtcDateTime
from app.core.validation import (
    CountryCode,
    DisplayName,
    EmailField,
    LocaleTag,
    SixDigitCode,
    TimezoneName,
    normalize_email,
)
from app.security.passwords import MAX_RAW_LENGTH, PasswordPolicyError, check_password_policy

AppVersion = Annotated[
    str, StringConstraints(pattern=r"^\d{1,6}\.\d{1,6}\.\d{1,6}(\+\d{1,9})?$", max_length=32)
]
OsVersion = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9 ._()-]{1,32}$")]
PasswordInput = Annotated[str, StringConstraints(min_length=1, max_length=MAX_RAW_LENGTH)]


class _EmailMixin(RequestModel):
    email: EmailField

    @property
    def email_normalized(self) -> str:
        return normalize_email(self.email)


class DeviceInfo(RequestModel):
    platform: Literal["android"]
    app_version: AppVersion
    os_version: OsVersion
    locale: LocaleTag


class LoginDeviceInfo(DeviceInfo):
    id: uuid.UUID | None = None


class RegisterStartRequest(_EmailMixin):
    password: PasswordInput
    display_name: DisplayName
    timezone: TimezoneName
    locale: LocaleTag = "en"
    country_code: CountryCode | None = None

    @field_validator("password")
    @classmethod
    def _password_policy(cls, value: str, info: ValidationInfo) -> str:
        email = info.data.get("email")
        try:
            check_password_policy(value, email=email if isinstance(email, str) else None)
        except PasswordPolicyError as exc:
            raise PydanticCustomError(exc.code, exc.message) from None
        return value


class RegisterStartResponse(ResponseModel):
    status: Literal["code_sent"] = "code_sent"
    resend_after_seconds: int = int(CODE_RESEND_INTERVAL.total_seconds())


class RegisterVerifyRequest(_EmailMixin):
    """The code alone is not enough: anyone can start a signup for someone else's address, and
    then the code mailed to that person would activate an account holding the attacker's
    password. Repeating the password chosen at signup proves the person verifying is the
    person who started *this* signup."""

    code: SixDigitCode
    password: PasswordInput
    device: DeviceInfo


class RegisterResendRequest(_EmailMixin):
    pass


class LoginRequest(_EmailMixin):
    password: PasswordInput
    device: LoginDeviceInfo


class RefreshRequest(RequestModel):
    refresh_token: Annotated[str, StringConstraints(min_length=1, max_length=128)]


class ReauthRequest(RequestModel):
    password: PasswordInput


class ForgotPasswordRequest(_EmailMixin):
    pass


class ForgotPasswordResponse(ResponseModel):
    status: Literal["email_sent"] = "email_sent"


class PasswordChangeRequest(RequestModel):
    """Both passwords are plain input here: the policy needs the account's email, which only
    the service knows, so it runs there and reports the same ``422 validation_failed`` shape."""

    current_password: PasswordInput
    new_password: PasswordInput


class EmailChangeStartRequest(RequestModel):
    new_email: EmailField

    @property
    def email_normalized(self) -> str:
        return normalize_email(self.new_email)


class EmailChangeStartResponse(ResponseModel):
    status: Literal["code_sent"] = "code_sent"


class EmailChangeVerifyRequest(RequestModel):
    code: SixDigitCode


class TokenUser(ResponseModel):
    id: uuid.UUID
    email: str
    tier: str


class TokenResponse(ResponseModel):
    access_token: str
    access_token_expires_at: UtcDateTime
    refresh_token: str
    session_id: uuid.UUID
    device_id: uuid.UUID
    user: TokenUser


class RefreshResponse(ResponseModel):
    access_token: str
    access_token_expires_at: UtcDateTime
    refresh_token: str


class SessionDevice(ResponseModel):
    platform: str
    app_version: str | None


class SessionItem(ResponseModel):
    id: uuid.UUID
    kind: str
    device: SessionDevice | None
    created_at: UtcDateTime
    last_used_at: UtcDateTime
    current: bool


class SessionList(ResponseModel):
    items: list[SessionItem] = Field(default_factory=list)
