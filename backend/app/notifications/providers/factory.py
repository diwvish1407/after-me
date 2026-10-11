"""Building the configured providers (DEPLOYMENT §4)."""

from __future__ import annotations

import httpx

from app.core.config import Settings
from app.notifications.email import (
    ConsoleEmailProvider,
    EmailProvider,
    RecordingEmailProvider,
)
from app.notifications.providers.chain import FallbackEmailProvider
from app.notifications.providers.fcm import (
    FcmPushProvider,
    MetadataServerTokens,
    ServiceAccountTokens,
    load_service_account,
)
from app.notifications.providers.http import new_client
from app.notifications.providers.postmark import PostmarkEmailProvider
from app.notifications.providers.resend import ResendEmailProvider
from app.notifications.providers.smtp import SmtpEmailProvider
from app.notifications.push import LogOnlyPushProvider, NoopPushProvider, PushProvider


def _one_email_provider(
    name: str, api_key: str | None, settings: Settings, client: httpx.AsyncClient
) -> EmailProvider:
    if name == "resend":
        return ResendEmailProvider(api_key=api_key or "", client=client)
    if name == "postmark":
        return PostmarkEmailProvider(
            api_key=api_key or "", message_stream=settings.postmark_message_stream, client=client
        )
    if name == "smtp":
        return SmtpEmailProvider(
            host=settings.smtp_host or "",
            port=settings.smtp_port,
            username=settings.smtp_username,
            password=settings.smtp_password.get_secret_value() if settings.smtp_password else None,
            implicit_tls=settings.smtp_implicit_tls,
        )
    msg = f"unknown email provider {name!r}"
    raise ValueError(msg)


def build_email_provider(
    settings: Settings, *, client: httpx.AsyncClient | None = None
) -> EmailProvider:
    if settings.email_provider == "recording":
        return RecordingEmailProvider()
    if settings.email_provider == "console":
        return ConsoleEmailProvider(settings.dev_mail_dir)
    http = client or new_client()
    primary = _one_email_provider(
        settings.email_provider,
        settings.email_api_key.get_secret_value() if settings.email_api_key else None,
        settings,
        http,
    )
    if settings.email_fallback_provider is None:
        return primary
    fallback = _one_email_provider(
        settings.email_fallback_provider,
        settings.email_fallback_api_key.get_secret_value()
        if settings.email_fallback_api_key
        else None,
        settings,
        http,
    )
    return FallbackEmailProvider(primary, fallback)


def build_push_provider(
    settings: Settings, *, client: httpx.AsyncClient | None = None
) -> PushProvider:
    if settings.push_provider == "noop":
        return NoopPushProvider()
    if settings.push_provider == "log":
        return LogOnlyPushProvider()
    http = client or new_client()
    if settings.fcm_credentials_json is not None:
        info = load_service_account(settings.fcm_credentials_json.get_secret_value())
        key_project = info.get("project_id")
        if key_project and key_project != settings.fcm_project_id:
            # A key for one project used with another's id answers "not found" for everything.
            msg = "FCM_CREDENTIALS_JSON belongs to a different project than FCM_PROJECT_ID"
            raise ValueError(msg)
        tokens: ServiceAccountTokens | MetadataServerTokens = ServiceAccountTokens(info, http)
    else:
        tokens = MetadataServerTokens(http)
    return FcmPushProvider(project_id=settings.fcm_project_id or "", tokens=tokens, client=http)
