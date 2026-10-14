"""Configuration refusals for the KMS adapter and the public pages (Phase 12)."""

from __future__ import annotations

import json
from typing import Any

import pytest
from pydantic import ValidationError

from app.core.config import Settings
from tests.fake_cloud_kms import KEY_NAME
from tests.support import make_settings
from tests.unit.test_config import SECURE_PROD

pytestmark = pytest.mark.no_db

SERVICE_ACCOUNT = json.dumps({"client_email": "kms@p.iam.gserviceaccount.com", "private_key": "x"})
PROD = {
    **SECURE_PROD,
    "email_provider": "resend",
    "email_api_key": "re_test_key_00000000",
    "email_webhook_secret": "whsec_" + "A" * 32,
}
FINAL = {
    "legal_documents_final": True,
    "legal_operator_name": "Example Labs Pvt Ltd",
    "legal_contact_email": "privacy@afterme.example",
    "legal_postal_address": "1 Example Road, Mumbai",
    "legal_effective_date": "2026-11-01",
}


# --- KMS ---------------------------------------------------------------------------------------


def test_gcp_kms_needs_the_key_name_and_it_must_be_a_cryptokey() -> None:
    assert make_settings(kms_provider="gcp_kms", kms_key_name=KEY_NAME).kms_key_name == KEY_NAME
    with pytest.raises(ValidationError, match="KMS_KEY_NAME is required"):
        make_settings(kms_provider="gcp_kms")
    for bad in (
        KEY_NAME + "/cryptoKeyVersions/3",  # a version: Cloud KMS must pick it
        "instruction-kek",
        "projects/p/locations/l/keyRings/r",
        KEY_NAME + "\n",
        "https://cloudkms.googleapis.com/v1/" + KEY_NAME,
        KEY_NAME.replace("afterme-test", "p;drop"),
    ):
        with pytest.raises(ValidationError, match="KMS_KEY_NAME must be the CryptoKey"):
            make_settings(kms_provider="gcp_kms", kms_key_name=bad)


def test_the_key_name_is_for_gcp_kms_only() -> None:
    with pytest.raises(ValidationError, match="only for KMS_PROVIDER=gcp_kms"):
        make_settings(kms_key_name=KEY_NAME)
    with pytest.raises(ValidationError, match="only for KMS_PROVIDER=gcp_kms"):
        make_settings(kms_credentials_json=SERVICE_ACCOUNT)


def test_credentials_must_be_a_service_account_key_and_are_never_echoed() -> None:
    ok = make_settings(
        kms_provider="gcp_kms", kms_key_name=KEY_NAME, kms_credentials_json=SERVICE_ACCOUNT
    )
    assert ok.kms_credentials_json is not None
    assert "client_email" not in repr(ok)  # a SecretStr
    for bad in ("not json", "[]", json.dumps({"client_email": "a@b"}), "{}"):
        with pytest.raises(ValidationError) as excinfo:
            make_settings(kms_provider="gcp_kms", kms_key_name=KEY_NAME, kms_credentials_json=bad)
        assert "KMS_CREDENTIALS_JSON must be a service-account key" in str(excinfo.value)
        assert "not json" not in str(excinfo.value)


@pytest.mark.parametrize("env", ["prod", "staging"])
def test_production_runs_on_cloud_kms_and_refuses_a_key_in_the_environment(env: str) -> None:
    good = {**PROD, "app_env": env}
    assert make_settings(**good).kms_provider == "gcp_kms"
    with pytest.raises(ValidationError, match="KMS_PROVIDER=local"):
        make_settings(**{**good, "kms_provider": "local", "kms_key_name": None})
    without_name = {k: v for k, v in good.items() if k != "kms_key_name"}
    with pytest.raises(ValidationError, match="KMS_KEY_NAME is required"):
        make_settings(**without_name)
    real_kek = "A" * 43
    for name in ("kms_local_key", "kms_local_key_previous"):
        with pytest.raises(ValidationError, match="KMS_LOCAL_KEY and KMS_LOCAL_KEY_PREVIOUS"):
            make_settings(**{**good, name: real_kek})


# --- public pages: addresses -------------------------------------------------------------------


def test_support_and_abuse_addresses_must_be_real_where_people_are() -> None:
    assert make_settings().abuse_email == "abuse@afterme.invalid"  # fine for dev and tests
    for env in ("prod", "staging"):
        good = {**PROD, "app_env": env}
        for name in ("support_email", "abuse_email"):
            with pytest.raises(ValidationError, match=f"{name.upper()} must be a real address"):
                make_settings(**{**good, name: "x@afterme.invalid"})


@pytest.mark.parametrize(
    "bad",
    [
        "no-at-sign",
        "a@b",
        "<script>@x.example",
        'a"b@x.example',
        "a@x.example, b@y.example",
        "a b@x.example",
        "a@x.example\nBcc: c@y.example",
        "",
    ],
)
def test_addresses_that_end_up_in_html_and_emails_are_plain_addresses(bad: str) -> None:
    for name in ("support_email", "abuse_email", "legal_contact_email"):
        with pytest.raises(ValidationError, match=f"{name.upper()} must be a plain email"):
            make_settings(**{name: bad})


# --- public pages: the legal texts -------------------------------------------------------------


def test_final_legal_documents_need_every_fact_in_production() -> None:
    for env in ("prod", "staging"):
        base: dict[str, Any] = {**PROD, "app_env": env}
        assert make_settings(**base).legal_documents_final is False  # the default: a draft
        assert make_settings(**{**base, **FINAL}).legal_documents_final is True
        for missing in (
            "legal_operator_name",
            "legal_contact_email",
            "legal_postal_address",
            "legal_effective_date",
        ):
            with pytest.raises(
                ValidationError, match=f"{missing.upper()} is required when LEGAL_DOCUMENTS_FINAL"
            ):
                make_settings(**{**base, **FINAL, missing: None})
        with pytest.raises(ValidationError, match="LEGAL_OPERATOR_NAME is required"):
            make_settings(**{**base, **FINAL, "legal_operator_name": "   "})
        # all problems are reported at once
        with pytest.raises(ValidationError) as every:
            make_settings(**{**base, "legal_documents_final": True})
        for name in ("OPERATOR_NAME", "CONTACT_EMAIL", "POSTAL_ADDRESS", "EFFECTIVE_DATE"):
            assert f"LEGAL_{name} is required" in str(every.value)


def test_a_draft_needs_none_of_it_and_outside_production_final_is_just_a_setting() -> None:
    assert make_settings(legal_documents_final=True).legal_documents_final is True
    s = make_settings()
    assert s.legal_version == "draft-1"
    assert s.legal_effective_date is None


def test_the_effective_date_is_read_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("AFTERME_LEGAL_EFFECTIVE_DATE", "2026-11-01")
    monkeypatch.setenv("AFTERME_LEGAL_DOCUMENTS_FINAL", "false")
    values = make_settings().model_dump()
    values.pop("legal_effective_date")
    values.pop("legal_documents_final")
    assert str(Settings(**values).legal_effective_date) == "2026-11-01"
