"""Application configuration (pydantic-settings, environment prefix ``AFTERME_``).

Production safety: :class:`Settings` refuses to load in ``staging``/``prod`` when an insecure value
is present (see :meth:`Settings._check_environment_safety`). Every problem is reported at once,
without echoing secret values.
"""

from __future__ import annotations

import base64
import binascii
import json
import os
import re
from datetime import date
from enum import StrEnum
from functools import cached_property
from pathlib import Path
from typing import Annotated, Literal, Self
from urllib.parse import parse_qs, urlsplit

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

BACKEND_DIR = Path(__file__).resolve().parents[2]
DOTENV_PATH = BACKEND_DIR / ".env"

# OWASP Password Storage Cheat Sheet: Argon2id with at least m=19 MiB, t=2, p=1.
ARGON2_MIN_TIME_COST = 2
ARGON2_MIN_MEMORY_KIB = 19_456
ARGON2_MIN_PARALLELISM = 1
MIN_PEPPER_BYTES = 32
# Fail-safe floors for production-like environments (ESCALATION_ENGINE §13).
_MIN_RELEASE_OFFSET_FLOOR = 1_440
_SETTLE_DELAY_FLOOR_SECONDS = 300
_LATE_SHIFT_FLOOR_MINUTES = 30
# The shortest grace period that may be configured (FR-ESC-01: 1-72 h). The database enforces the
# same floor (CHECK ck_escalation_plans_grace_minutes), so a lower setting would let the plan
# editor accept a value that the insert then refuses with a 500.
_GRACE_MIN_FLOOR_MINUTES = 60
_GRACE_MAX_CEILING_MINUTES = 4_320
_STAGE_OFFSET_CEILING_MINUTES = 43_200
_MIN_API_KEY = 8
# A webhook secret sits on a public URL that anyone can send requests to: 32 characters is
# 192 bits of base64, and no more than a password manager generates anyway (Phase 9, F12).
_MIN_WEBHOOK_SECRET = 32
_LOOPBACK_HOSTS = frozenset({"localhost", "127.0.0.1", "::1"})
_TLS_SSLMODES = frozenset({"require", "verify-ca", "verify-full"})
# Providers that only exist for development and tests; refused in staging/prod. A module-level
# set so the production validators can be exercised end to end in tests (Phase 8 adds the real
# provider and this set then stops being the only gate).
DEV_ONLY_EMAIL_PROVIDERS: frozenset[str] = frozenset({"console", "recording"})

# A Cloud KMS CryptoKey (never a version: the version is chosen by Cloud KMS: SECURITY §6.2).
KMS_KEY_NAME_RE = re.compile(
    r"^projects/[A-Za-z0-9][A-Za-z0-9:._-]{2,98}/locations/[a-z0-9-]{1,63}"
    r"/keyRings/[A-Za-z0-9_-]{1,63}/cryptoKeys/[A-Za-z0-9_-]{1,63}$"
)
_EMAIL_RE = re.compile(r"^[^@\s<>\"'`,;()\[\]\\]{1,64}@[A-Za-z0-9.-]{1,200}\.[A-Za-z0-9-]{2,63}$")

_SEMVER = re.compile(r"^(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})$")
_KID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")

_DEV_DATABASE_URL = "postgresql+psycopg://afterme_api:afterme_api_dev@localhost:5432/afterme_dev"
# A development KEK: base64url of 32 bytes. Anything encrypted with it is disposable by
# definition, and production-like environments refuse the local KMS provider altogether.
_DEV_KMS_LOCAL_KEY = "ZGV2LW9ubHkta2VrLS1kby1ub3QtdXNlLWluLXByb2Q"
_DEV_MIGRATION_URL = (
    "postgresql+psycopg://afterme_owner:afterme_owner_dev@localhost:5432/afterme_dev"
)
_DEV_WORKER_URL = (
    "postgresql+psycopg://afterme_worker:afterme_worker_dev@localhost:5432/afterme_dev"
)


class AppEnv(StrEnum):
    DEV = "dev"
    TEST = "test"
    STAGING = "staging"
    PROD = "prod"


class ConfigurationError(ValueError):
    """Raised when the configuration is unusable or unsafe for the selected environment."""


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="AFTERME_",
        env_file=None,  # the dev-only .env file is passed explicitly by load_settings()
        extra="ignore",
        frozen=True,
        validate_default=True,
        hide_input_in_errors=True,  # validation errors must never echo secrets
    )

    app_env: AppEnv = AppEnv.DEV
    debug: bool = False
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"

    public_base_url: str = "http://localhost:8000"
    api_base_url: str = "http://localhost:8000"

    database_url: SecretStr = SecretStr(_DEV_DATABASE_URL)
    migration_database_url: SecretStr = SecretStr(_DEV_MIGRATION_URL)
    db_pool_size: Annotated[int, Field(ge=1, le=100)] = 10
    db_max_overflow: Annotated[int, Field(ge=0, le=100)] = 5
    db_statement_timeout_ms: Annotated[int, Field(ge=100, le=600_000)] = 15_000
    api_lock_timeout_ms: Annotated[int, Field(ge=100, le=60_000)] = 5_000

    jwt_signing_keys: dict[str, SecretStr] = Field(default_factory=dict)
    jwt_active_kid: str = ""
    jwt_issuer: Annotated[str, Field(min_length=1, max_length=200)] = "afterme-dev"
    jwt_audience: Annotated[str, Field(min_length=1, max_length=200)] = "afterme-app"
    access_token_ttl_seconds: Annotated[int, Field(ge=60, le=3600)] = 900
    session_idle_days: Annotated[int, Field(ge=1, le=365)] = 60
    session_absolute_days: Annotated[int, Field(ge=1, le=730)] = 365

    hmac_pepper: SecretStr | None = None
    hmac_pepper_previous: SecretStr | None = None

    # Envelope encryption of instructions (SECURITY §6.2). ``local`` keeps the key-encryption
    # key in the environment: development and tests only.
    kms_provider: Literal["local", "gcp_kms"] = "local"
    kms_local_key: SecretStr = SecretStr(_DEV_KMS_LOCAL_KEY)
    kms_local_key_previous: SecretStr | None = None
    # ``gcp_kms``: the full resource name of the Cloud KMS CryptoKey (not a version), e.g.
    # ``projects/p/locations/asia-south1/keyRings/afterme/cryptoKeys/instruction-kek``. Not a
    # secret. The identity that calls Cloud KMS is the metadata server's (Workload Identity);
    # ``KMS_CREDENTIALS_JSON`` (a service-account key) is for development and CI only.
    kms_key_name: str | None = None
    kms_credentials_json: SecretStr | None = None

    # ------------------------------------------------------------------ notifications
    # DEPLOYMENT §4. ``console`` and ``recording`` are for development and tests; the others
    # are real providers (ARCHITECTURE §4.7).
    email_provider: Literal["console", "recording", "resend", "postmark", "smtp"] = "console"
    email_from: Annotated[str, Field(min_length=3, max_length=200)] = (
        "AfterMe <no-reply@afterme.invalid>"
    )
    email_api_key: SecretStr | None = None
    # A second provider that takes over when the first cannot be used (FR-NOT-06).
    email_fallback_provider: Literal["resend", "postmark", "smtp"] | None = None
    email_fallback_api_key: SecretStr | None = None
    # What authenticates a provider's delivery/bounce webhook (POST /webhooks/email/{provider}):
    # Resend's signing secret (``whsec_…``), or the password of the Basic-auth URL given to
    # Postmark.
    email_webhook_secret: SecretStr | None = None
    email_fallback_webhook_secret: SecretStr | None = None
    postmark_message_stream: Annotated[str, Field(min_length=1, max_length=64)] = "outbound"
    smtp_host: str | None = None
    smtp_port: Annotated[int, Field(ge=1, le=65_535)] = 587
    smtp_username: str | None = None
    smtp_password: SecretStr | None = None
    smtp_implicit_tls: bool = False
    dev_mail_dir: Path = BACKEND_DIR / ".dev_mail"

    # ``log`` only logs the message type (development); ``noop`` drops silently (tests);
    # ``fcm`` is Firebase Cloud Messaging over HTTP v1. Without ``fcm_credentials_json`` the
    # adapter uses the metadata server (Workload Identity on Google Cloud).
    push_provider: Literal["log", "noop", "fcm"] = "log"
    fcm_project_id: Annotated[str, Field(min_length=1, max_length=64)] | None = None
    fcm_credentials_json: SecretStr | None = None

    # ------------------------------------------------------------------ public pages
    # Support and abuse addresses (shown on /support and in every contact-facing email) and the
    # facts the legal pages need. ``LEGAL_DOCUMENTS_FINAL`` removes the "draft" banner from
    # /legal/*: set it only after counsel has reviewed the texts in app/web/templates.
    support_email: str = "support@afterme.invalid"
    abuse_email: str = "abuse@afterme.invalid"
    legal_documents_final: bool = False
    legal_operator_name: Annotated[str, Field(max_length=200)] | None = None
    legal_contact_email: str | None = None
    legal_postal_address: Annotated[str, Field(max_length=500)] | None = None
    legal_version: Annotated[str, Field(min_length=1, max_length=40)] = "draft-1"
    legal_effective_date: date | None = None
    legal_governing_law: Annotated[str, Field(max_length=500)] | None = None

    trusted_proxy_hops: Annotated[int, Field(ge=0, le=10)] = 0
    min_client_version: str = "0.0.0"

    argon2_time_cost: Annotated[int, Field(ge=1, le=20)] = 3
    argon2_memory_cost_kib: Annotated[int, Field(ge=8, le=4_194_304)] = 65_536
    argon2_parallelism: Annotated[int, Field(ge=1, le=16)] = 4

    rate_limit_enabled: bool = True

    # ------------------------------------------------------------------ test support
    # A movable clock and a mail reader for integration tests (TEST_PLAN §2). Off by default,
    # refused in production, and in any environment but ``test`` it needs a token.
    test_support_enabled: bool = False
    test_support_token: SecretStr | None = None

    # ------------------------------------------------------------------ escalation engine
    # ESCALATION_ENGINE §13. The worker process connects as ``afterme_worker``.
    worker_database_url: SecretStr = SecretStr(_DEV_WORKER_URL)
    # The retention job (Phase 7: account purge). In production it connects as the
    # ``afterme_maintenance`` role; in development that role cannot log in, so the default is
    # the owner URL.
    maintenance_database_url: SecretStr = SecretStr(_DEV_MIGRATION_URL)
    # How long a deleted account's remaining rows are kept before the hard delete.
    account_deletion_days: Annotated[int, Field(ge=1, le=90)] = 30
    # How long an audit record is kept (PRD D10: a year, which counsel must confirm). At least
    # 90 days: the beta review and an investigation after a stolen session read it.
    audit_retention_days: Annotated[int, Field(ge=90, le=3650)] = 365
    tick_seconds: Annotated[int, Field(ge=1, le=300)] = 15
    grace_min_minutes: Annotated[int, Field(ge=1, le=10_080)] = 60
    grace_max_minutes: Annotated[int, Field(ge=1, le=10_080)] = 4_320
    stage_min_gap_minutes: Annotated[int, Field(ge=1, le=10_080)] = 30
    stage_max_offset_minutes: Annotated[int, Field(ge=1, le=525_600)] = 43_200
    min_release_offset_minutes: Annotated[int, Field(ge=1, le=525_600)] = 1_440
    final_warning_lead_minutes: Annotated[int, Field(ge=1, le=1_440)] = 60
    settle_delay_seconds: Annotated[int, Field(ge=0, le=3_600)] = 300
    ingestion_probe_interval_seconds: Annotated[int, Field(ge=1, le=3_600)] = 60
    ingestion_stale_seconds: Annotated[int, Field(ge=1, le=3_600)] = 180
    hold_exit_fresh_seconds: Annotated[int, Field(ge=1, le=7_200)] = 600
    hold_recovery_buffer_minutes: Annotated[int, Field(ge=0, le=1_440)] = 30
    anomaly_floor_per_hour: Annotated[int, Field(ge=1, le=100_000)] = 25
    # A contact-facing stage found more than this late (the worker was down, or the clock
    # jumped) is not run: the person is warned again and the stage is put back (§6.7).
    late_tolerance_seconds: Annotated[int, Field(ge=1, le=3_600)] = 300
    late_shift_minutes: Annotated[int, Field(ge=1, le=1_440)] = 30
    action_max_attempts: Annotated[int, Field(ge=1, le=20)] = 5
    probe_token: SecretStr | None = None

    # ------------------------------------------------------------------ derived values

    @property
    def is_production_like(self) -> bool:
        return self.app_env in (AppEnv.STAGING, AppEnv.PROD)

    @property
    def ingestion_monitoring_enabled(self) -> bool:
        """The ingestion trigger of Hold (§7.2) exists only where an external monitor is
        configured to send probes. Staging and production require a probe token."""
        return self.probe_token is not None

    @property
    def docs_enabled(self) -> bool:
        return self.app_env is not AppEnv.PROD

    @property
    def hsts_enabled(self) -> bool:
        return self.app_env in (AppEnv.STAGING, AppEnv.PROD)

    @cached_property
    def jwt_private_keys(self) -> dict[str, Ed25519PrivateKey]:
        return {
            kid: _load_ed25519(pem.get_secret_value()) for kid, pem in self.jwt_signing_keys.items()
        }

    @property
    def min_client_version_tuple(self) -> tuple[int, int, int]:
        major, minor, patch = (int(p) for p in self.min_client_version.split("."))
        return major, minor, patch

    # ------------------------------------------------------------------ validation

    @model_validator(mode="after")
    def _validate(self) -> Self:
        problems = [
            *self._check_basics(),
            *self._check_secrets(),
            *self._check_hardening(),
            *self._check_environment_safety(),
            *self._check_providers(),
            *self._check_kms(),
            *self._check_public_pages(),
            *self._check_test_support(),
        ]
        if problems:
            raise ConfigurationError(
                f"Invalid AfterMe configuration for APP_ENV={self.app_env.value}: "
                + "; ".join(problems)
            )
        return self

    def _check_basics(self) -> list[str]:
        problems: list[str] = []
        for name in ("public_base_url", "api_base_url"):
            value: str = getattr(self, name)
            parts = urlsplit(value)
            if parts.scheme not in ("http", "https") or not parts.netloc:
                problems.append(f"{name.upper()} must be an absolute http(s) URL")
            elif value.endswith("/") or parts.query or parts.fragment:
                problems.append(f"{name.upper()} must not end with '/' or carry a query/fragment")
        if not _SEMVER.match(self.min_client_version):
            problems.append("MIN_CLIENT_VERSION must look like 1.2.3")
        if self.session_idle_days > self.session_absolute_days:
            problems.append("SESSION_IDLE_DAYS must not exceed SESSION_ABSOLUTE_DAYS")
        return problems

    def _check_secrets(self) -> list[str]:
        problems: list[str] = []
        if not self.jwt_signing_keys:
            problems.append(
                "JWT_SIGNING_KEYS is required (run `uv run python scripts/generate_jwt_key.py`)"
            )
        else:
            for kid, pem in self.jwt_signing_keys.items():
                if not _KID.match(kid):
                    problems.append("JWT_SIGNING_KEYS has an invalid kid")
                    continue
                try:
                    _load_ed25519(pem.get_secret_value())
                except ValueError:
                    problems.append(f"JWT_SIGNING_KEYS[{kid}] is not an Ed25519 private key PEM")
            if self.jwt_active_kid not in self.jwt_signing_keys:
                problems.append("JWT_ACTIVE_KID must name one of JWT_SIGNING_KEYS")

        for name in ("hmac_pepper", "hmac_pepper_previous"):
            secret: SecretStr | None = getattr(self, name)
            if secret is None:
                if name == "hmac_pepper":
                    problems.append("HMAC_PEPPER is required")
                continue
            if len(secret.get_secret_value().encode()) < MIN_PEPPER_BYTES:
                problems.append(f"{name.upper()} must be at least {MIN_PEPPER_BYTES} bytes")

        for name in ("kms_local_key", "kms_local_key_previous"):
            kek: SecretStr | None = getattr(self, name)
            if kek is not None and decode_kek(kek.get_secret_value()) is None:
                problems.append(f"{name.upper()} must be base64url of exactly 32 bytes")
        return problems

    def _check_hardening(self) -> list[str]:
        problems: list[str] = []
        if self.app_env is not AppEnv.TEST and (
            self.argon2_time_cost < ARGON2_MIN_TIME_COST
            or self.argon2_memory_cost_kib < ARGON2_MIN_MEMORY_KIB
            or self.argon2_parallelism < ARGON2_MIN_PARALLELISM
        ):
            problems.append(
                "Argon2 parameters below the OWASP minimum are only allowed with APP_ENV=test"
            )
        if not self.rate_limit_enabled and self.app_env not in (AppEnv.DEV, AppEnv.TEST):
            problems.append("RATE_LIMIT_ENABLED=false is only allowed in dev and test")
        problems.extend(self._check_engine())
        return problems

    def _check_engine(self) -> list[str]:
        """Relations between the engine parameters that the safety argument depends on
        (ESCALATION_ENGINE §6.6, §13): refused at startup, in every environment."""
        problems: list[str] = []
        # Detection takes up to INGESTION_STALE plus one tick to be evaluated and one dispatch
        # pass to notice the Hold: the settle delay must outlast all of it, or a message can
        # leave in the gap between "the outage began" and "the engine knows".
        if self.settle_delay_seconds <= self.ingestion_stale_seconds + 2 * self.tick_seconds:
            problems.append(
                "SETTLE_DELAY_SECONDS must exceed INGESTION_STALE_SECONDS plus two ticks: a "
                "stage that ran during an undetected outage must be rolled back before "
                "anything leaves"
            )
        if self.late_tolerance_seconds < 2 * self.tick_seconds:
            problems.append(
                "LATE_TOLERANCE_SECONDS must be at least two ticks: a worker that is merely "
                "busy must not be mistaken for one that was down"
            )
        if self.grace_min_minutes > self.grace_max_minutes:
            problems.append("GRACE_MIN_MINUTES must not exceed GRACE_MAX_MINUTES")
        if self.stage_max_offset_minutes < self.grace_max_minutes:
            problems.append("STAGE_MAX_OFFSET_MINUTES must not be below GRACE_MAX_MINUTES")
        # The plan tables refuse values outside these bounds (CHECK grace_minutes, offset_minutes):
        # a setting that promises more would turn a plan edit into a 500.
        if self.grace_max_minutes > _GRACE_MAX_CEILING_MINUTES:
            problems.append(f"GRACE_MAX_MINUTES must not exceed {_GRACE_MAX_CEILING_MINUTES}")
        if self.stage_max_offset_minutes > _STAGE_OFFSET_CEILING_MINUTES:
            problems.append(
                f"STAGE_MAX_OFFSET_MINUTES must not exceed {_STAGE_OFFSET_CEILING_MINUTES}"
            )
        if self.ingestion_stale_seconds <= self.ingestion_probe_interval_seconds:
            problems.append("INGESTION_STALE_SECONDS must exceed INGESTION_PROBE_INTERVAL_SECONDS")
        if self.is_production_like:
            if self.min_release_offset_minutes < _MIN_RELEASE_OFFSET_FLOOR:
                problems.append(
                    f"MIN_RELEASE_OFFSET_MINUTES must be at least {_MIN_RELEASE_OFFSET_FLOOR}"
                )
            if self.late_shift_minutes < _LATE_SHIFT_FLOOR_MINUTES:
                problems.append(f"LATE_SHIFT_MINUTES must be at least {_LATE_SHIFT_FLOOR_MINUTES}")
            if self.settle_delay_seconds < _SETTLE_DELAY_FLOOR_SECONDS:
                problems.append(
                    f"SETTLE_DELAY_SECONDS must be at least {_SETTLE_DELAY_FLOOR_SECONDS}"
                )
        if self.grace_min_minutes < _GRACE_MIN_FLOOR_MINUTES:
            problems.append(
                f"GRACE_MIN_MINUTES must be at least {_GRACE_MIN_FLOOR_MINUTES}: a shorter grace "
                "period makes a wrongful alert more likely, and the database refuses it"
            )
        return problems

    def _check_providers(self) -> list[str]:
        problems: list[str] = []
        for role, name, key in (
            ("EMAIL_PROVIDER", self.email_provider, self.email_api_key),
            ("EMAIL_FALLBACK_PROVIDER", self.email_fallback_provider, self.email_fallback_api_key),
        ):
            if name in ("resend", "postmark") and (
                key is None or len(key.get_secret_value()) < _MIN_API_KEY
            ):
                key_name = "EMAIL_API_KEY" if role == "EMAIL_PROVIDER" else "EMAIL_FALLBACK_API_KEY"
                problems.append(f"{key_name} is required for {role}={name}")
        smtp_used = "smtp" in (self.email_provider, self.email_fallback_provider)
        if smtp_used and not self.smtp_host:
            problems.append("SMTP_HOST is required when a provider is smtp")
        if (
            self.email_fallback_provider is not None
            and self.email_fallback_provider == self.email_provider
        ):
            problems.append("EMAIL_FALLBACK_PROVIDER must differ from EMAIL_PROVIDER")
        if self.push_provider == "fcm" and not self.fcm_project_id:
            problems.append("FCM_PROJECT_ID is required for PUSH_PROVIDER=fcm")
        if self.is_production_like:
            if self.push_provider != "fcm":
                problems.append("PUSH_PROVIDER must be fcm")
            for role, name, secret in (
                ("EMAIL_WEBHOOK_SECRET", self.email_provider, self.email_webhook_secret),
                (
                    "EMAIL_FALLBACK_WEBHOOK_SECRET",
                    self.email_fallback_provider,
                    self.email_fallback_webhook_secret,
                ),
            ):
                if name in ("resend", "postmark") and (
                    secret is None or len(secret.get_secret_value()) < _MIN_API_KEY
                ):
                    problems.append(f"{role} is required (the provider's bounces must reach us)")
                elif (
                    name == "postmark"
                    and secret is not None
                    and len(secret.get_secret_value()) < _MIN_WEBHOOK_SECRET
                ):
                    problems.append(
                        f"{role} must be at least {_MIN_WEBHOOK_SECRET} characters: it is a "
                        "password on a public URL"
                    )
                elif (
                    name == "resend"
                    and secret is not None
                    and not _is_svix_secret(secret.get_secret_value())
                ):
                    problems.append(f"{role} must be the whsec_ signing secret from Resend")
            if self.email_from.rstrip(">").endswith(".invalid"):
                problems.append("EMAIL_FROM must be an address on the verified sending domain")
        return problems

    def _check_transport_and_logging(self) -> list[str]:
        problems: list[str] = []
        if self.log_level == "DEBUG":
            # Third-party libraries log request detail at DEBUG, and the access log joins each
            # person to a route and a time: not in an environment with real people in it.
            problems.append("LOG_LEVEL must not be DEBUG")
        for name, url in (
            ("DATABASE_URL", self.database_url),
            ("WORKER_DATABASE_URL", self.worker_database_url),
            ("MAINTENANCE_DATABASE_URL", self.maintenance_database_url),
        ):
            if not _database_url_is_protected(url.get_secret_value()):
                problems.append(
                    f"{name} must require TLS (sslmode=require, verify-ca or verify-full) "
                    "unless it points at a local proxy"
                )
        return problems

    def _check_local_only(self) -> list[str]:
        """``dev`` and ``test`` carry the development key-encryption key, console mail and no
        refusals at all. A process that is still ``dev`` because AFTERME_APP_ENV was forgotten
        must not be able to talk to a database that is not on this machine."""
        problems: list[str] = []
        for name, url in (
            ("DATABASE_URL", self.database_url),
            ("WORKER_DATABASE_URL", self.worker_database_url),
            ("MAINTENANCE_DATABASE_URL", self.maintenance_database_url),
        ):
            host = _database_host(url.get_secret_value())
            if host is not None and host not in _LOOPBACK_HOSTS and not host.startswith("/"):
                problems.append(
                    f"{name} points at a database that is not on this machine, but APP_ENV is "
                    f"{self.app_env.value}: set AFTERME_APP_ENV=staging or prod so that the "
                    "production refusals apply"
                )
        return problems

    def _check_kms(self) -> list[str]:
        problems: list[str] = []
        if self.kms_provider == "gcp_kms":
            if not self.kms_key_name:
                problems.append("KMS_KEY_NAME is required for KMS_PROVIDER=gcp_kms")
            elif not KMS_KEY_NAME_RE.fullmatch(self.kms_key_name):
                problems.append(
                    "KMS_KEY_NAME must be the CryptoKey's full resource name "
                    "(projects/<p>/locations/<l>/keyRings/<r>/cryptoKeys/<k>), not a key version"
                )
            if self.kms_credentials_json is not None and not _is_service_account_json(
                self.kms_credentials_json.get_secret_value()
            ):
                problems.append(
                    "KMS_CREDENTIALS_JSON must be a service-account key (client_email, private_key)"
                )
        elif self.kms_key_name is not None or self.kms_credentials_json is not None:
            problems.append(
                "KMS_KEY_NAME and KMS_CREDENTIALS_JSON are only for KMS_PROVIDER=gcp_kms"
            )
        if self.is_production_like and (
            self.kms_local_key_previous is not None
            or self.kms_local_key.get_secret_value() != _DEV_KMS_LOCAL_KEY
        ):
            # A real key-encryption key must not sit in the environment next to a cloud KMS:
            # it is a second way in, and an invitation to switch the provider back one day.
            problems.append("KMS_LOCAL_KEY and KMS_LOCAL_KEY_PREVIOUS must not be set here")
        return problems

    def _check_public_pages(self) -> list[str]:
        problems: list[str] = []
        for name in ("support_email", "abuse_email", "legal_contact_email"):
            value: str | None = getattr(self, name)
            if value is not None and not _EMAIL_RE.fullmatch(value):
                problems.append(f"{name.upper()} must be a plain email address")
        if self.is_production_like:
            for name in ("support_email", "abuse_email"):
                if getattr(self, name).endswith(".invalid"):
                    problems.append(f"{name.upper()} must be a real address (it is in our emails)")
        if self.legal_documents_final and self.is_production_like:
            for name in (
                "legal_operator_name",
                "legal_contact_email",
                "legal_postal_address",
                "legal_effective_date",
            ):
                value = getattr(self, name)
                if value is None or (isinstance(value, str) and not value.strip()):
                    problems.append(f"{name.upper()} is required when LEGAL_DOCUMENTS_FINAL=true")
        return problems

    def _check_test_support(self) -> list[str]:
        if not self.test_support_enabled:
            return []
        problems: list[str] = []
        if self.app_env is AppEnv.PROD:
            problems.append("TEST_SUPPORT_ENABLED must never be set in production")
        token = self.test_support_token
        if token is None or len(token.get_secret_value()) < MIN_PEPPER_BYTES:
            problems.append(
                f"TEST_SUPPORT_TOKEN is required and must be at least {MIN_PEPPER_BYTES} bytes "
                "when test support is enabled"
            )
        if self.email_provider not in DEV_ONLY_EMAIL_PROVIDERS:
            # Moving the clock opens incidents and alerts contacts for every account in the
            # database: only where no real message can leave.
            problems.append(
                "TEST_SUPPORT_ENABLED needs a development email provider (console or recording)"
            )
        return problems

    def _check_environment_safety(self) -> list[str]:
        if not self.is_production_like:
            return self._check_local_only()
        problems: list[str] = []
        if self.debug:
            problems.append("DEBUG must be false")
        problems.extend(self._check_transport_and_logging())
        if self.email_provider in DEV_ONLY_EMAIL_PROVIDERS:
            problems.append(f"EMAIL_PROVIDER={self.email_provider} is for development and tests")
        for name in ("public_base_url", "api_base_url"):
            if urlsplit(getattr(self, name)).scheme != "https":
                problems.append(f"{name.upper()} must use https")
        explicitly_set = self.model_fields_set
        if "database_url" not in explicitly_set:
            problems.append("DATABASE_URL must be set explicitly")
        if "worker_database_url" not in explicitly_set:
            problems.append("WORKER_DATABASE_URL must be set explicitly")
        if "maintenance_database_url" not in explicitly_set:
            problems.append("MAINTENANCE_DATABASE_URL must be set explicitly")
        if self.probe_token is None or len(self.probe_token.get_secret_value()) < MIN_PEPPER_BYTES:
            problems.append(
                f"PROBE_TOKEN is required and must be at least {MIN_PEPPER_BYTES} bytes"
            )
        if self.kms_provider == "local":
            problems.append(
                "KMS_PROVIDER=local keeps the key-encryption key in the environment: it is for "
                "development and tests (use a cloud KMS)"
            )
        if "jwt_issuer" not in explicitly_set or "jwt_audience" not in explicitly_set:
            problems.append("JWT_ISSUER and JWT_AUDIENCE must be set explicitly")
        if "trusted_proxy_hops" not in explicitly_set:
            problems.append(
                "TRUSTED_PROXY_HOPS must be set explicitly (0 = no proxy, 1 = one load balancer)"
            )
        return problems


def _database_host(url: str) -> str | None:
    try:
        return urlsplit(url).hostname
    except ValueError:
        return None


def _database_url_is_protected(url: str) -> bool:
    """TLS required on the wire, or a loopback host (a local proxy that carries it)."""
    host = _database_host(url)
    if host is None or host in _LOOPBACK_HOSTS or host.startswith("/"):
        return True
    values = parse_qs(urlsplit(url).query).get("sslmode", [])
    return bool(values) and values[-1] in _TLS_SSLMODES


def _is_svix_secret(value: str) -> bool:
    """``whsec_`` followed by base64: what Resend's webhook signing secret looks like. A secret
    that cannot be decoded would make every webhook fail verification, silently."""
    if not value.startswith("whsec_"):
        return False
    try:
        return len(base64.b64decode(value.removeprefix("whsec_"), validate=True)) >= 16  # noqa: PLR2004
    except ValueError:
        return False


def _is_service_account_json(raw: str) -> bool:
    try:
        info = json.loads(raw)
    except ValueError:
        return False
    return (
        isinstance(info, dict)
        and isinstance(info.get("client_email"), str)
        and isinstance(info.get("private_key"), str)
        and bool(info["client_email"])
        and bool(info["private_key"])
    )


def decode_kek(value: str) -> bytes | None:
    """A local key-encryption key: base64url (padding optional) of exactly 32 bytes."""
    try:
        raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except (binascii.Error, ValueError):
        return None
    return raw if len(raw) == 32 else None  # noqa: PLR2004 - AES-256


def _load_ed25519(pem: str) -> Ed25519PrivateKey:
    try:
        key = load_pem_private_key(pem.encode(), password=None)
    except (ValueError, TypeError) as exc:
        raise ValueError("not a PEM private key") from exc
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("not an Ed25519 key")
    return key


def load_settings() -> Settings:
    """Load settings from the environment.

    The ``backend/.env`` file is read only when the process environment selects ``dev`` (or does
    not select anything). A ``.env`` file can never switch the process into another environment.
    """
    configured = os.environ.get("AFTERME_APP_ENV")
    if configured is None and not DOTENV_PATH.is_file():
        # Not a workstation (there is no .env) and the environment was not chosen: running as
        # "dev" would switch off every production refusal without anyone having said so.
        msg = (
            "AFTERME_APP_ENV is not set. Set it to dev, test, staging or prod; staging and prod "
            "enforce the production refusals"
        )
        raise ConfigurationError(msg)
    requested = (configured or AppEnv.DEV.value).strip().lower()
    if requested == AppEnv.DEV.value and DOTENV_PATH.is_file():
        settings = Settings(_env_file=DOTENV_PATH)
        if settings.app_env is not AppEnv.DEV:
            msg = "backend/.env is for local development only; set AFTERME_APP_ENV in the process"
            raise ConfigurationError(msg)
        return settings
    return Settings()


class MigrationSettings(BaseSettings):
    """The only setting Alembic needs (the owner role's URL); no other secrets are required."""

    model_config = SettingsConfigDict(
        env_prefix="AFTERME_", env_file=None, extra="ignore", hide_input_in_errors=True
    )

    app_env: AppEnv = AppEnv.DEV
    migration_database_url: SecretStr = SecretStr(_DEV_MIGRATION_URL)


def load_migration_database_url() -> str:
    requested = os.environ.get("AFTERME_APP_ENV", AppEnv.DEV.value).strip().lower()
    if requested == AppEnv.DEV.value and DOTENV_PATH.is_file():
        settings = MigrationSettings(_env_file=DOTENV_PATH)
    else:
        settings = MigrationSettings()
    if settings.app_env in (AppEnv.STAGING, AppEnv.PROD) and (
        "migration_database_url" not in settings.model_fields_set
    ):
        msg = "MIGRATION_DATABASE_URL must be set explicitly outside dev/test"
        raise ConfigurationError(msg)
    return settings.migration_database_url.get_secret_value()
