"""Application configuration (pydantic-settings, environment prefix ``AFTERME_``).

Production safety: :class:`Settings` refuses to load in ``staging``/``prod`` when an insecure value
is present (see :meth:`Settings._check_environment_safety`). Every problem is reported at once,
without echoing secret values.
"""

from __future__ import annotations

import base64
import binascii
import os
import re
from enum import StrEnum
from functools import cached_property
from pathlib import Path
from typing import Annotated, Literal, Self
from urllib.parse import urlsplit

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
# Providers that only exist for development and tests; refused in staging/prod. A module-level
# set so the production validators can be exercised end to end in tests (Phase 8 adds the real
# provider and this set then stops being the only gate).
DEV_ONLY_EMAIL_PROVIDERS: frozenset[str] = frozenset({"console", "recording"})

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

    email_provider: Literal["console", "recording"] = "console"
    email_from: Annotated[str, Field(min_length=3, max_length=200)] = (
        "AfterMe <no-reply@afterme.invalid>"
    )
    dev_mail_dir: Path = BACKEND_DIR / ".dev_mail"

    trusted_proxy_hops: Annotated[int, Field(ge=0, le=10)] = 0
    min_client_version: str = "0.0.0"

    argon2_time_cost: Annotated[int, Field(ge=1, le=20)] = 3
    argon2_memory_cost_kib: Annotated[int, Field(ge=8, le=4_194_304)] = 65_536
    argon2_parallelism: Annotated[int, Field(ge=1, le=16)] = 4

    rate_limit_enabled: bool = True

    # ------------------------------------------------------------------ escalation engine
    # ESCALATION_ENGINE §13. The worker process connects as ``afterme_worker``.
    worker_database_url: SecretStr = SecretStr(_DEV_WORKER_URL)
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
        return problems

    def _check_environment_safety(self) -> list[str]:
        if not self.is_production_like:
            return []
        problems: list[str] = []
        if self.debug:
            problems.append("DEBUG must be false")
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
    requested = os.environ.get("AFTERME_APP_ENV", AppEnv.DEV.value).strip().lower()
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
