from __future__ import annotations

from typing import Any

import pytest
from pydantic import ValidationError

from app.auth.schemas import LoginRequest, RegisterStartRequest, RegisterVerifyRequest
from tests.support import DEVICE, PASSWORD

pytestmark = pytest.mark.no_db

BASE: dict[str, Any] = {
    "email": "  Diwakar@Example.com ",
    "password": PASSWORD,
    "display_name": "Diwakar",
    "timezone": "Asia/Kolkata",
}


def _errors(**overrides: Any) -> list[tuple[str, str]]:
    with pytest.raises(ValidationError) as excinfo:
        RegisterStartRequest(**{**BASE, **overrides})
    return [(".".join(str(p) for p in e["loc"]), e["type"]) for e in excinfo.value.errors()]


def test_valid_request_is_normalised() -> None:
    body = RegisterStartRequest(**BASE, locale="EN-in", country_code="in")
    assert body.email == "Diwakar@example.com"  # the domain is case-insensitive; the rest is kept
    assert body.email_normalized == "diwakar@example.com"
    assert body.locale == "en-IN"
    assert body.country_code == "IN"
    assert RegisterStartRequest(**BASE, locale="zh-hant-tw").locale == "zh-Hant-TW"


def test_unknown_fields_are_rejected() -> None:
    assert ("tier", "extra_forbidden") in _errors(tier="premium")
    assert ("user_id", "extra_forbidden") in _errors(user_id="x")


@pytest.mark.parametrize(
    "email", ["not-an-email", "a@b", "x@localhost", "", "a" * 250 + "@example.com", 42]
)
def test_invalid_emails(email: object) -> None:
    assert ("email", "invalid_email") in _errors(email=email)


@pytest.mark.parametrize(
    ("name", "code"),
    [
        ("", "too_short"),
        ("   ", "too_short"),
        ("x" * 81, "too_long"),
        ("Mallory\u202e", "invalid_characters"),
        ("Bad\x00Name", "invalid_characters"),
        ("Visit https://evil.example", "display_name_link"),
        ("www.evil", "display_name_link"),
        ("support.afterme.com", "display_name_link"),
        ("someone@example.com", "display_name_link"),
        ("evil.com", "display_name_link"),
        ("AfterMe Security", "display_name_reserved"),
        ("After Me Team", "display_name_reserved"),
        ("AFT3R-ME", "display_name_reserved"),
        ("\u0410fter\u041ce", "display_name_reserved"),  # Cyrillic A and M
        # Phase 9: spellings that read as the same thing to a person
        ("example.\u0440\u0444", "display_name_link"),  # a Cyrillic top-level domain
        ("evil\u3002com", "display_name_link"),  # ideographic full stop
        ("evil\uff0ecom", "display_name_link"),  # fullwidth full stop
        ("\u00c1fter M\u00e9", "display_name_reserved"),  # accented
        (123, "invalid_display_name"),
    ],
)
def test_display_name_rules(name: object, code: str) -> None:
    assert ("display_name", code) in _errors(display_name=name)


@pytest.mark.parametrize(
    "name",
    ["Diwakar", "José Ñúñez", "李小龍", "Mary-Kate O'Neil", "Dr. Who", "Zoë Renée", "А. Б. Иванов"],
)
def test_display_name_accepts_real_names(name: str) -> None:
    assert RegisterStartRequest(**{**BASE, "display_name": f" {name} "}).display_name == name


def test_display_name_is_nfc() -> None:
    decomposed = "Jose\u0301"
    assert RegisterStartRequest(**{**BASE, "display_name": decomposed}).display_name == "José"


@pytest.mark.parametrize("tz", ["Mars/Base", "../../etc/passwd", "", "x" * 100, 5])
def test_timezone_must_be_iana(tz: object) -> None:
    assert ("timezone", "invalid_timezone") in _errors(timezone=tz)


@pytest.mark.parametrize("locale", ["english", "e", "en_IN", "en-IN-x", 1])
def test_locale_rules(locale: object) -> None:
    assert ("locale", "invalid_locale") in _errors(locale=locale)


@pytest.mark.parametrize("country", ["XX", "IND", "1", 7])
def test_country_code_rules(country: object) -> None:
    assert ("country_code", "invalid_country_code") in _errors(country_code=country)


@pytest.mark.parametrize(
    ("password", "code"),
    [
        ("short", "too_short"),
        ("1234567890", "password_too_common"),
        ("diwakar@example.com", "password_matches_email"),
        ("diwakar", "too_short"),
    ],
)
def test_password_policy_reports_on_password_field(password: str, code: str) -> None:
    assert ("password", code) in _errors(password=password)


def test_verify_code_must_be_six_ascii_digits() -> None:
    for code in ("12345", "1234567", "abcdef", "١٢٣٤٥٦", 123456):
        with pytest.raises(ValidationError):
            RegisterVerifyRequest(
                email="a@example.com", code=code, password="long enough password", device=DEVICE
            )
    RegisterVerifyRequest(
        email="a@example.com", code="012345", password="long enough password", device=DEVICE
    )


def test_device_rules() -> None:
    for bad in (
        {**DEVICE, "platform": "ios"},
        {**DEVICE, "app_version": "latest"},
        {**DEVICE, "os_version": "<script>"},
        {**DEVICE, "extra": True},
        {k: v for k, v in DEVICE.items() if k != "locale"},
    ):
        with pytest.raises(ValidationError):
            LoginRequest(email="a@example.com", password="x", device=bad)
    request = LoginRequest(
        email="a@example.com",
        password="x",
        device={**DEVICE, "id": "6c1e5bd0-7c0c-4b77-9a4a-1d2c3b4a5f60"},
    )
    assert request.device.id is not None


# --- one spelling per mailbox (Phase 9, F6) ------------------------------------------------------


def test_two_spellings_of_one_mailbox_are_one_address() -> None:
    from app.core.validation import clean_email, normalize_email

    # an internationalised domain and its punycode form, composed and decomposed accents
    assert normalize_email("Bob@Bücher.de") == normalize_email("bob@xn--bcher-kva.de")
    assert normalize_email("José@example.com") == normalize_email("José@example.com")
    assert clean_email("  Bob@Bücher.DE ") == "Bob@xn--bcher-kva.de"
    # case: the domain is case-insensitive, and the lookup key lower-cases the rest
    assert normalize_email("A.B@EXAMPLE.com") == "a.b@example.com"
    # a string that is not an address is still keyed, so a form field cannot raise
    assert normalize_email("  Not An Address ") == "not an address"
