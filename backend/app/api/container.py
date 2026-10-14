"""Process-wide services, built once per application instance."""

from __future__ import annotations

from dataclasses import dataclass

from sqlalchemy.dialects.postgresql import insert

from app.audit.writer import AuditWriter
from app.auth.tokens import AccessTokenService
from app.core.clock import Clock, DbClock
from app.core.config import Settings, decode_kek
from app.core.db import Database
from app.notifications.email import EmailMessage, EmailProvider, ProviderResult
from app.notifications.mailer import Mailer, ReceiptSink
from app.notifications.models import EmailReceipt
from app.notifications.providers.factory import build_email_provider
from app.security.gcp_kms import build_gcp_kms
from app.security.hashing import Pepper
from app.security.kms import KmsProvider, LocalKms, UnavailableKms
from app.security.passwords import PasswordHasher
from app.security.rate_limit import RateLimiter
from app.security.vault import InstructionVault
from app.testsupport.clock import OffsetDbClock


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
    return build_email_provider(settings)


def _receipt_writer(db: Database) -> ReceiptSink:
    async def write(message: EmailMessage, result: ProviderResult) -> None:
        if message.contact_id is None or message.owner_id is None:
            return
        async with db.independent_session() as session:
            await session.execute(
                insert(EmailReceipt)
                .values(
                    user_id=message.owner_id,
                    contact_id=message.contact_id,
                    template_key=message.template,
                    provider=result.provider,
                    provider_message_id=result.message_id,
                )
                .on_conflict_do_nothing(index_elements=["provider", "provider_message_id"])
            )

    return write


def build_kms(settings: Settings) -> KmsProvider:
    """The configured key-wrapping provider (``KMS_PROVIDER``)."""
    if settings.kms_provider == "gcp_kms":
        return build_gcp_kms(settings)
    active = decode_kek(settings.kms_local_key.get_secret_value())
    previous = (
        decode_kek(settings.kms_local_key_previous.get_secret_value())
        if settings.kms_local_key_previous
        else None
    )
    if active is None:  # pragma: no cover - Settings already refuses this
        msg = "KMS_LOCAL_KEY is invalid"
        raise ValueError(msg)
    return LocalKms(active, previous)


def _vault(settings: Settings, db: Database) -> InstructionVault:
    return InstructionVault(build_kms(settings), independent_session=db.independent_session)


def build_services(
    settings: Settings,
    *,
    clock: Clock | None = None,
    email_provider: EmailProvider | None = None,
    database_url: str | None = None,
    application_name: str = "afterme-api",
    vault: InstructionVault | None = None,
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
        clock=clock or (OffsetDbClock() if settings.test_support_enabled else DbClock()),
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
        mailer=Mailer(
            email_provider or _email_provider(settings),
            sender=settings.email_from,
            receipts=_receipt_writer(db),
            support_url=f"{settings.public_base_url}/support",
            abuse_email=settings.abuse_email,
        ),
        vault=vault if vault is not None else _vault(settings, db),
    )


def build_worker_services(
    settings: Settings,
    *,
    clock: Clock | None = None,
    email_provider: EmailProvider | None = None,
) -> AppServices:
    """The escalation worker's services: the same container, connected as ``afterme_worker``
    (which can create incidents; the API role cannot, INV-1).

    The worker decides releases and never reads content (SECURITY §6.2; BD-5): its database role
    has no privilege on ``user_keys`` or on ``instructions.content_ciphertext``, and its vault is
    :class:`UnavailableKms`: no KMS client, no credentials, no network call to a KMS is ever made
    from this container, whatever ``KMS_PROVIDER`` says."""
    return build_services(
        settings,
        clock=clock,
        email_provider=email_provider,
        database_url=settings.worker_database_url.get_secret_value(),
        application_name="afterme-worker",
        vault=InstructionVault(UnavailableKms()),
    )
