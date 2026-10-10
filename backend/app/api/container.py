"""Process-wide services, built once per application instance."""

from __future__ import annotations

from dataclasses import dataclass

from app.audit.writer import AuditWriter
from app.auth.tokens import AccessTokenService
from app.core.clock import Clock, DbClock
from app.core.config import Settings, decode_kek
from app.core.db import Database
from app.notifications.email import ConsoleEmailProvider, EmailProvider, RecordingEmailProvider
from app.notifications.mailer import Mailer
from app.security.hashing import Pepper
from app.security.kms import LocalKms
from app.security.passwords import PasswordHasher
from app.security.rate_limit import RateLimiter
from app.security.vault import InstructionVault


@dataclass(frozen=True)
class AppServices:
    settings: Settings
    db: Database
    clock: Clock
    pepper: Pepper
    passwords: PasswordHasher
    tokens: AccessTokenService
    limiter: RateLimiter
    audit: AuditWriter
    mailer: Mailer
    vault: InstructionVault


def _email_provider(settings: Settings) -> EmailProvider:
    if settings.email_provider == "recording":
        return RecordingEmailProvider()
    return ConsoleEmailProvider(settings.dev_mail_dir)


def _vault(settings: Settings, db: Database) -> InstructionVault:
    if settings.kms_provider != "local":
        msg = f"KMS provider {settings.kms_provider!r} is not available in this build"
        raise ValueError(msg)
    active = decode_kek(settings.kms_local_key.get_secret_value())
    previous = (
        decode_kek(settings.kms_local_key_previous.get_secret_value())
        if settings.kms_local_key_previous
        else None
    )
    if active is None:  # pragma: no cover - Settings already refuses this
        msg = "KMS_LOCAL_KEY is invalid"
        raise ValueError(msg)
    return InstructionVault(LocalKms(active, previous), independent_session=db.independent_session)


def build_services(
    settings: Settings,
    *,
    clock: Clock | None = None,
    email_provider: EmailProvider | None = None,
    database_url: str | None = None,
    application_name: str = "afterme-api",
) -> AppServices:
    if settings.hmac_pepper is None:  # pragma: no cover - Settings already refuses this
        msg = "HMAC_PEPPER is required"
        raise ValueError(msg)
    db = Database.from_settings(settings, application_name=application_name, url=database_url)
    pepper = Pepper(
        settings.hmac_pepper.get_secret_value(),
        settings.hmac_pepper_previous.get_secret_value() if settings.hmac_pepper_previous else None,
    )
    return AppServices(
        settings=settings,
        db=db,
        clock=clock or DbClock(),
        pepper=pepper,
        passwords=PasswordHasher(
            time_cost=settings.argon2_time_cost,
            memory_cost_kib=settings.argon2_memory_cost_kib,
            parallelism=settings.argon2_parallelism,
        ),
        tokens=AccessTokenService(
            signing_keys=settings.jwt_private_keys,
            active_kid=settings.jwt_active_kid,
            issuer=settings.jwt_issuer,
            audience=settings.jwt_audience,
            ttl_seconds=settings.access_token_ttl_seconds,
        ),
        limiter=RateLimiter(db=db, pepper=pepper, enabled=settings.rate_limit_enabled),
        audit=AuditWriter(db),
        mailer=Mailer(email_provider or _email_provider(settings), sender=settings.email_from),
        vault=_vault(settings, db),
    )


def build_worker_services(
    settings: Settings,
    *,
    clock: Clock | None = None,
    email_provider: EmailProvider | None = None,
) -> AppServices:
    """The escalation worker's services: the same container, connected as ``afterme_worker``
    (which can create incidents; the API role cannot, INV-1)."""
    return build_services(
        settings,
        clock=clock,
        email_provider=email_provider,
        database_url=settings.worker_database_url.get_secret_value(),
        application_name="afterme-worker",
    )
