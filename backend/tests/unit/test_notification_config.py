"""Provider configuration and the factory (DEPLOYMENT §4)."""

from __future__ import annotations

import json
from typing import Any

import pytest
from pydantic import ValidationError

from app.notifications.providers.chain import FallbackEmailProvider
from app.notifications.providers.factory import build_email_provider, build_push_provider
from app.notifications.providers.fcm import FcmPushProvider
from app.notifications.providers.postmark import PostmarkEmailProvider
from app.notifications.providers.resend import ResendEmailProvider
from app.notifications.providers.smtp import SmtpEmailProvider
from app.notifications.push import LogOnlyPushProvider, NoopPushProvider
from tests.support import make_settings

pytestmark = pytest.mark.no_db

KEY = "k" * 20


def test_development_providers_are_the_default() -> None:
    settings = make_settings()
    assert settings.email_provider == "recording"
    assert settings.push_provider == "log"
    assert isinstance(build_push_provider(settings), LogOnlyPushProvider)
    assert isinstance(build_push_provider(make_settings(push_provider="noop")), NoopPushProvider)


def test_a_real_provider_needs_its_key_and_a_fallback_must_differ() -> None:
    with pytest.raises(ValidationError, match="EMAIL_API_KEY is required"):
        make_settings(email_provider="resend")
    with pytest.raises(ValidationError, match="EMAIL_FALLBACK_API_KEY is required"):
        make_settings(email_provider="smtp", smtp_host="h", email_fallback_provider="postmark")
    with pytest.raises(ValidationError, match="must differ"):
        make_settings(
            email_provider="resend",
            email_api_key=KEY,
            email_fallback_provider="resend",
            email_fallback_api_key=KEY,
        )
    with pytest.raises(ValidationError, match="SMTP_HOST"):
        make_settings(email_provider="smtp")
    with pytest.raises(ValidationError, match="FCM_PROJECT_ID"):
        make_settings(push_provider="fcm")


def test_the_factory_builds_the_configured_chain() -> None:
    resend = make_settings(email_provider="resend", email_api_key=KEY)
    assert isinstance(build_email_provider(resend), ResendEmailProvider)

    chain = build_email_provider(
        make_settings(
            email_provider="postmark",
            email_api_key=KEY,
            email_fallback_provider="smtp",
            smtp_host="smtp.example",
        )
    )
    assert isinstance(chain, FallbackEmailProvider)
    assert chain.name == "postmark"
    assert isinstance(chain._providers[0], PostmarkEmailProvider)
    assert isinstance(chain._providers[1], SmtpEmailProvider)


def test_fcm_uses_a_key_when_given_and_the_metadata_server_otherwise() -> None:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    with_key = build_push_provider(
        make_settings(
            push_provider="fcm",
            fcm_project_id="afterme-dev",
            fcm_credentials_json=json.dumps({"client_email": "a@b", "private_key": pem}),
        )
    )
    assert isinstance(with_key, FcmPushProvider)
    without = build_push_provider(make_settings(push_provider="fcm", fcm_project_id="afterme-dev"))
    assert isinstance(without, FcmPushProvider)


def _prod(**over: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "app_env": "prod",
        "public_base_url": "https://afterme.example",
        "api_base_url": "https://api.afterme.example",
        "argon2_time_cost": 3,
        "argon2_memory_cost_kib": 65536,
        "argon2_parallelism": 4,
        "trusted_proxy_hops": 1,
        "worker_database_url": "postgresql+psycopg://w:secret@db/afterme?sslmode=require",
        "maintenance_database_url": "postgresql+psycopg://m:secret@db/afterme?sslmode=require",
        "probe_token": "p" * 48,
        "kms_provider": "gcp_kms",
        "email_provider": "resend",
        "email_api_key": KEY,
        "email_webhook_secret": "whsec_" + "A" * 32,
        "email_from": "AfterMe <alerts@mail.afterme.example>",
        "push_provider": "fcm",
        "fcm_project_id": "afterme-prod",
    }
    base.update(over)
    return base


def test_production_needs_real_push_a_webhook_secret_and_a_real_sender() -> None:
    assert make_settings(**_prod()).email_provider == "resend"
    with pytest.raises(ValidationError, match="PUSH_PROVIDER must be fcm"):
        make_settings(**_prod(push_provider="log"))
    with pytest.raises(ValidationError, match="EMAIL_WEBHOOK_SECRET"):
        make_settings(**_prod(email_webhook_secret=None))
    with pytest.raises(ValidationError, match="EMAIL_FROM"):
        make_settings(**_prod(email_from="AfterMe <no-reply@afterme.invalid>"))
    with pytest.raises(ValidationError, match="EMAIL_FALLBACK_WEBHOOK_SECRET"):
        make_settings(**_prod(email_fallback_provider="postmark", email_fallback_api_key=KEY))
    # A Postmark webhook is a password on a public URL: short ones are refused (Phase 9, F12).
    with pytest.raises(ValidationError, match="at least 32 characters"):
        make_settings(
            **_prod(
                email_fallback_provider="postmark",
                email_fallback_api_key=KEY,
                email_fallback_webhook_secret="short-pw-123",
            )
        )
    long_secret = "w" * 40
    settings = make_settings(
        **_prod(
            email_fallback_provider="postmark",
            email_fallback_api_key=KEY,
            email_fallback_webhook_secret=long_secret,
        )
    )
    assert settings.email_fallback_provider == "postmark"


def test_a_resend_webhook_secret_that_cannot_verify_anything_is_refused_at_start() -> None:
    for secret in ("not-a-whsec-secret", "whsec_!!!not base64!!!", "whsec_AAAA"):
        with pytest.raises(ValidationError, match="whsec_ signing secret"):
            make_settings(**_prod(email_webhook_secret=secret))


def test_a_service_account_key_for_another_project_is_refused() -> None:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    info = {"client_email": "a@b", "private_key": pem, "project_id": "afterme-staging"}
    settings = make_settings(
        push_provider="fcm", fcm_project_id="afterme-prod", fcm_credentials_json=json.dumps(info)
    )
    with pytest.raises(ValueError, match="different project"):
        build_push_provider(settings)
