from __future__ import annotations

import json
from pathlib import Path

import pytest
from pydantic import SecretStr, ValidationError

from app.core import config as config_module
from app.core.config import (
    AppEnv,
    ConfigurationError,
    Settings,
    load_migration_database_url,
    load_settings,
)
from tests.support import TEST_PEPPER, make_settings

pytestmark = pytest.mark.no_db

SECURE_PROD = {
    "app_env": "prod",
    "public_base_url": "https://afterme.example",
    "api_base_url": "https://api.afterme.example",
    "argon2_time_cost": 3,
    "argon2_memory_cost_kib": 65536,
    "argon2_parallelism": 4,
    "trusted_proxy_hops": 1,
    "worker_database_url": "postgresql+psycopg://afterme_worker:secret@db/afterme?sslmode=verify-full",
    "maintenance_database_url": (
        "postgresql+psycopg://afterme_maintenance:secret@db/afterme?sslmode=verify-full"
    ),
    "probe_token": "p" * 48,
    "kms_provider": "gcp_kms",  # the local KMS keeps the KEK in the environment: dev/test only
    "kms_key_name": (
        "projects/afterme-prod/locations/asia-south1/keyRings/afterme/cryptoKeys/instruction-kek"
    ),
    "support_email": "support@afterme.example",
    "abuse_email": "abuse@afterme.example",
    "push_provider": "fcm",
    "fcm_project_id": "afterme-prod",
    "email_from": "AfterMe <alerts@mail.afterme.example>",
}


def _problems(exc: ValidationError) -> str:
    return str(exc)


def test_test_settings_are_valid() -> None:
    settings = make_settings()
    assert settings.app_env is AppEnv.TEST
    assert settings.docs_enabled
    assert not settings.hsts_enabled
    assert settings.min_client_version_tuple == (0, 0, 0)
    assert set(settings.jwt_private_keys) == {settings.jwt_active_kid}


@pytest.mark.parametrize("env", ["prod", "staging"])
def test_production_refuses_insecure_settings(env: str) -> None:
    with pytest.raises(ValidationError) as excinfo:
        make_settings(
            app_env=env,
            debug=True,
            email_provider="console",
            public_base_url="http://afterme.example",
            api_base_url="http://api.afterme.example",
            rate_limit_enabled=False,
            argon2_time_cost=1,
            argon2_memory_cost_kib=1024,
            argon2_parallelism=1,
        )
    message = _problems(excinfo.value)
    for expected in (
        "DEBUG must be false",
        "EMAIL_PROVIDER=console",
        "PUBLIC_BASE_URL must use https",
        "API_BASE_URL must use https",
        "RATE_LIMIT_ENABLED=false",
        "Argon2 parameters below the OWASP minimum",
    ):
        assert expected in message


def test_production_refuses_development_email_providers_even_when_otherwise_secure() -> None:
    for provider in ("console", "recording"):
        with pytest.raises(ValidationError) as excinfo:
            make_settings(**SECURE_PROD, email_provider=provider)
        message = _problems(excinfo.value)
        assert f"EMAIL_PROVIDER={provider}" in message
        assert "must use https" not in message
        assert "DEBUG" not in message
        assert "set explicitly" not in message


def test_production_requires_explicit_database_and_jwt_identity() -> None:
    values = make_settings().model_dump()
    for name in ("database_url", "jwt_issuer", "jwt_audience"):
        values.pop(name)
    values.update(SECURE_PROD)
    values.pop("trusted_proxy_hops")
    with pytest.raises(ValidationError) as excinfo:
        Settings(**values)
    message = _problems(excinfo.value)
    assert "DATABASE_URL must be set explicitly" in message
    assert "JWT_ISSUER and JWT_AUDIENCE must be set explicitly" in message
    assert "TRUSTED_PROXY_HOPS must be set explicitly" in message


@pytest.mark.parametrize("env", ["prod", "staging"])
@pytest.mark.parametrize("hops", [0, 1, 2])
def test_trusted_proxy_hops_must_be_explicit_but_zero_is_valid(
    env: str, hops: int, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(config_module, "DEV_ONLY_EMAIL_PROVIDERS", frozenset())
    values = make_settings().model_dump()
    values.update({**SECURE_PROD, "app_env": env})
    values.pop("trusted_proxy_hops")
    with pytest.raises(ValidationError, match="TRUSTED_PROXY_HOPS must be set explicitly"):
        Settings(**values)
    settings = Settings(**values, trusted_proxy_hops=hops)
    assert settings.trusted_proxy_hops == hops


@pytest.mark.parametrize("env", ["prod", "staging"])
def test_secure_production_configuration_loads_when_email_check_is_isolated(
    env: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The positive case: a correct configuration must not be rejected by any other validator."""
    monkeypatch.setattr(config_module, "DEV_ONLY_EMAIL_PROVIDERS", frozenset())
    settings = make_settings(**{**SECURE_PROD, "app_env": env})
    assert settings.is_production_like
    assert settings.hsts_enabled
    assert settings.docs_enabled is (env != "prod")
    assert settings.rate_limit_enabled
    assert not settings.debug


@pytest.mark.parametrize("env", ["prod", "staging"])
def test_secure_production_configuration_reports_exactly_the_email_problem(env: str) -> None:
    with pytest.raises(ValidationError) as excinfo:
        make_settings(**{**SECURE_PROD, "app_env": env})
    message = _problems(excinfo.value)
    assert "EMAIL_PROVIDER=recording is for development and tests" in message
    assert message.count(";") == 0  # the only problem; problems are joined with "; "


@pytest.mark.parametrize(
    ("overrides", "expected"),
    [
        ({"hmac_pepper": None}, "HMAC_PEPPER is required"),
        ({"hmac_pepper": "short"}, "HMAC_PEPPER must be at least 32 bytes"),
        ({"hmac_pepper_previous": "short"}, "HMAC_PEPPER_PREVIOUS must be at least 32 bytes"),
        ({"kms_local_key": "short"}, "KMS_LOCAL_KEY must be base64url of exactly 32 bytes"),
        (
            {"kms_local_key_previous": "!!!not base64!!!"},
            "KMS_LOCAL_KEY_PREVIOUS must be base64url of exactly 32 bytes",
        ),
        ({"jwt_signing_keys": {}}, "JWT_SIGNING_KEYS is required"),
        ({"jwt_active_kid": "other"}, "JWT_ACTIVE_KID must name one of JWT_SIGNING_KEYS"),
        ({"jwt_signing_keys": {"bad kid!": "x"}}, "invalid kid"),
        ({"jwt_signing_keys": {"test-kid-1": "not a pem"}}, "not an Ed25519 private key"),
        ({"min_client_version": "1.2"}, "MIN_CLIENT_VERSION"),
        ({"public_base_url": "https://afterme.test/"}, "must not end with '/'"),
        ({"api_base_url": "ftp://x"}, "absolute http(s) URL"),
        ({"session_idle_days": 200, "session_absolute_days": 100}, "SESSION_IDLE_DAYS"),
    ],
)
def test_invalid_values_are_reported(overrides: dict[str, object], expected: str) -> None:
    with pytest.raises(ValidationError) as excinfo:
        make_settings(**overrides)
    assert expected in _problems(excinfo.value)


def test_rsa_key_is_not_accepted() -> None:
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import (
        Encoding,
        NoEncryption,
        PrivateFormat,
    )

    pem = (
        rsa.generate_private_key(public_exponent=65537, key_size=2048)
        .private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
        .decode()
    )
    with pytest.raises(ValidationError) as excinfo:
        make_settings(jwt_signing_keys={"test-kid-1": pem})
    assert "not an Ed25519 private key" in _problems(excinfo.value)


def test_weak_argon2_only_in_test_env() -> None:
    make_settings(argon2_time_cost=1, argon2_memory_cost_kib=1024)
    with pytest.raises(ValidationError, match="Argon2"):
        make_settings(app_env="dev", argon2_time_cost=1, argon2_memory_cost_kib=1024)


def test_the_grace_period_floor_matches_the_database_in_every_environment() -> None:
    """The plan table refuses a grace period under 60 minutes (CHECK), so the configured minimum
    may not promise less: it would turn a plan edit into a 500."""
    with pytest.raises(ValidationError) as excinfo:
        make_settings(grace_min_minutes=59)
    assert "GRACE_MIN_MINUTES must be at least 60" in _problems(excinfo.value)
    assert make_settings(grace_min_minutes=60).grace_min_minutes == 60


def test_the_other_plan_bounds_also_match_the_database() -> None:
    with pytest.raises(ValidationError) as excinfo:
        make_settings(grace_max_minutes=4_321)
    assert "GRACE_MAX_MINUTES must not exceed 4320" in _problems(excinfo.value)
    with pytest.raises(ValidationError) as excinfo:
        make_settings(stage_max_offset_minutes=43_201)
    assert "STAGE_MAX_OFFSET_MINUTES must not exceed 43200" in _problems(excinfo.value)
    settings = make_settings(grace_max_minutes=4_320, stage_max_offset_minutes=43_200)
    assert settings.grace_max_minutes == 4_320


def test_rate_limit_toggle_allowed_in_dev_and_test_only() -> None:
    make_settings(rate_limit_enabled=False)
    make_settings(
        app_env="dev", rate_limit_enabled=False, argon2_time_cost=2, argon2_memory_cost_kib=19456
    )


def test_errors_never_echo_secret_values() -> None:
    secret = "s3cr3t-" * 2
    with pytest.raises(ValidationError) as excinfo:
        make_settings(hmac_pepper=secret, app_env="prod")
    assert secret not in str(excinfo.value)
    assert TEST_PEPPER not in str(excinfo.value)
    assert "BEGIN PRIVATE KEY" not in str(excinfo.value)


def test_secrets_are_masked_in_repr() -> None:
    settings = make_settings()
    text = repr(settings)
    assert TEST_PEPPER not in text
    assert "BEGIN PRIVATE KEY" not in text
    assert isinstance(settings.hmac_pepper, SecretStr)


def test_dotenv_is_read_only_in_dev(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    env_file = tmp_path / ".env"
    base = make_settings()
    pem = base.jwt_signing_keys["test-kid-1"].get_secret_value().replace("\n", "\\n")
    env_file.write_text(
        "\n".join(
            [
                "AFTERME_APP_ENV=dev",
                f"AFTERME_HMAC_PEPPER={TEST_PEPPER}",
                f'AFTERME_JWT_SIGNING_KEYS=\'{{"k1": "{pem}"}}\'',
                "AFTERME_JWT_ACTIVE_KID=k1",
                "AFTERME_TRUSTED_PROXY_HOPS=2",
                "AFTERME_MIGRATION_DATABASE_URL=postgresql+psycopg://o:p@db/from_dotenv",
            ]
        )
    )
    monkeypatch.setattr(config_module, "DOTENV_PATH", env_file)

    monkeypatch.delenv("AFTERME_APP_ENV", raising=False)
    loaded = load_settings()
    assert loaded.app_env is AppEnv.DEV
    assert loaded.trusted_proxy_hops == 2
    assert load_migration_database_url().endswith("/from_dotenv")

    monkeypatch.setenv("AFTERME_APP_ENV", "test")
    with pytest.raises(ValidationError, match="HMAC_PEPPER is required"):
        load_settings()  # .env ignored outside dev
    assert not load_migration_database_url().endswith("/from_dotenv")


def test_dotenv_cannot_switch_environment(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text("AFTERME_APP_ENV=test\n")
    monkeypatch.setattr(config_module, "DOTENV_PATH", env_file)
    monkeypatch.delenv("AFTERME_APP_ENV", raising=False)
    monkeypatch.setenv("AFTERME_HMAC_PEPPER", TEST_PEPPER)
    base = make_settings()
    monkeypatch.setenv(
        "AFTERME_JWT_SIGNING_KEYS",
        json.dumps({"k1": base.jwt_signing_keys["test-kid-1"].get_secret_value()}),
    )
    monkeypatch.setenv("AFTERME_JWT_ACTIVE_KID", "k1")
    with pytest.raises(ConfigurationError, match="local development only"):
        load_settings()


def test_migration_url_must_be_explicit_in_production(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("AFTERME_APP_ENV", "prod")
    monkeypatch.delenv("AFTERME_MIGRATION_DATABASE_URL", raising=False)
    with pytest.raises(ConfigurationError):
        load_migration_database_url()
    monkeypatch.setenv("AFTERME_MIGRATION_DATABASE_URL", "postgresql+psycopg://o:p@db/prod")
    assert load_migration_database_url() == "postgresql+psycopg://o:p@db/prod"


# --- escalation engine parameters (ESCALATION_ENGINE §13) -------------------------------------


@pytest.mark.parametrize(
    ("overrides", "expected"),
    [
        (
            {"settle_delay_seconds": 180, "ingestion_stale_seconds": 180},
            "SETTLE_DELAY_SECONDS must exceed INGESTION_STALE_SECONDS",
        ),
        (
            {"settle_delay_seconds": 60},
            "SETTLE_DELAY_SECONDS must exceed INGESTION_STALE_SECONDS",
        ),
        (  # 180 s to detect + two 15 s ticks to notice it = 210 s: 200 s is not enough
            {"settle_delay_seconds": 200, "ingestion_stale_seconds": 180},
            "SETTLE_DELAY_SECONDS must exceed INGESTION_STALE_SECONDS plus two ticks",
        ),
        (
            {"ingestion_stale_seconds": 60, "ingestion_probe_interval_seconds": 60},
            "INGESTION_STALE_SECONDS must exceed INGESTION_PROBE_INTERVAL_SECONDS",
        ),
        (
            {"grace_min_minutes": 500, "grace_max_minutes": 400},
            "GRACE_MIN_MINUTES must not exceed GRACE_MAX_MINUTES",
        ),
        (
            {"stage_max_offset_minutes": 100, "grace_max_minutes": 4320},
            "STAGE_MAX_OFFSET_MINUTES must not be below GRACE_MAX_MINUTES",
        ),
    ],
)
def test_engine_parameters_must_keep_their_safety_relations(
    overrides: dict[str, int], expected: str
) -> None:
    with pytest.raises(ValidationError) as excinfo:
        make_settings(**overrides)
    assert expected in _problems(excinfo.value)


def test_engine_defaults_match_the_specification() -> None:
    settings = make_settings()
    assert settings.tick_seconds == 15
    assert settings.settle_delay_seconds == 300
    assert settings.ingestion_stale_seconds == 180
    assert settings.min_release_offset_minutes == 1440
    assert settings.hold_exit_fresh_seconds == 600
    assert settings.hold_recovery_buffer_minutes == 30
    assert settings.anomaly_floor_per_hour == 25
    assert settings.action_max_attempts == 5
    assert settings.stage_min_gap_minutes == 30
    assert settings.stage_max_offset_minutes == 43200


@pytest.mark.parametrize("env", ["prod", "staging"])
def test_production_keeps_the_fail_safe_floors(env: str) -> None:
    values = {**SECURE_PROD, "app_env": env}
    with pytest.raises(ValidationError) as excinfo:
        make_settings(
            **values,
            email_provider="recording",
            min_release_offset_minutes=600,
            settle_delay_seconds=250,
        )
    message = _problems(excinfo.value)
    assert "MIN_RELEASE_OFFSET_MINUTES must be at least 1440" in message
    assert "SETTLE_DELAY_SECONDS must be at least 300" in message


@pytest.mark.parametrize("env", ["prod", "staging"])
def test_production_needs_a_worker_url_and_a_probe_token(env: str) -> None:
    values = make_settings().model_dump()
    names = ("worker_database_url", "maintenance_database_url", "probe_token")
    for name in names:
        values.pop(name, None)
    values.update({**SECURE_PROD, "app_env": env, "email_provider": "recording"})
    for name in names:
        values.pop(name)
    with pytest.raises(ValidationError) as excinfo:
        Settings(**values)
    message = _problems(excinfo.value)
    assert "WORKER_DATABASE_URL must be set explicitly" in message
    assert "MAINTENANCE_DATABASE_URL must be set explicitly" in message
    assert "PROBE_TOKEN is required" in message


@pytest.mark.parametrize("env", ["prod", "staging"])
def test_production_refuses_the_local_kms(env: str) -> None:
    """SEC-24: a key-encryption key in the environment is for development and tests."""
    with pytest.raises(ValidationError) as excinfo:
        make_settings(**{**SECURE_PROD, "app_env": env, "kms_provider": "local"})
    assert "KMS_PROVIDER=local" in _problems(excinfo.value)


# --- Phase 9: refusals that fail closed ---------------------------------------------------------


@pytest.mark.parametrize("env", ["prod", "staging"])
def test_production_refuses_debug_logging_and_an_unprotected_database_link(
    env: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(config_module, "DEV_ONLY_EMAIL_PROVIDERS", frozenset())
    values = make_settings().model_dump()
    values.update({**SECURE_PROD, "app_env": env})
    assert Settings(**values).log_level == "INFO"

    with pytest.raises(ValidationError, match="LOG_LEVEL must not be DEBUG"):
        Settings(**{**values, "log_level": "DEBUG"})
    plain = "postgresql+psycopg://afterme_worker:secret@db.internal/afterme"
    with pytest.raises(ValidationError, match="WORKER_DATABASE_URL must require TLS"):
        Settings(**{**values, "worker_database_url": plain})
    with pytest.raises(ValidationError, match="WORKER_DATABASE_URL must require TLS"):
        Settings(**{**values, "worker_database_url": plain + "?sslmode=disable"})
    # a proxy on this machine carries the TLS: loopback is fine
    local = "postgresql+psycopg://afterme_worker:secret@127.0.0.1/afterme"
    assert Settings(**{**values, "worker_database_url": local}).app_env.value == env


def test_a_development_process_will_not_use_a_database_elsewhere() -> None:
    """A process that is "dev" only because AFTERME_APP_ENV was forgotten would carry the
    development key-encryption key and console mail to a real database."""
    remote = "postgresql+psycopg://afterme_api:secret@db.internal/afterme"
    with pytest.raises(ValidationError, match="not on this machine"):
        make_settings(database_url=remote)
    assert make_settings(database_url=remote.replace("db.internal", "localhost"))


def test_the_environment_must_be_chosen_unless_this_is_a_workstation(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("AFTERME_APP_ENV", raising=False)
    monkeypatch.setattr(config_module, "DOTENV_PATH", tmp_path / "no.env")
    with pytest.raises(config_module.ConfigurationError, match="AFTERME_APP_ENV is not set"):
        config_module.load_settings()
