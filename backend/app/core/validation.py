"""Shared field validators for request models.

Validators raise :class:`pydantic_core.PydanticCustomError` so each failure carries a stable
error ``code`` in ``422 validation_failed`` responses. Messages never echo the input.
"""

from __future__ import annotations

import re
import unicodedata
import zoneinfo
from functools import cache
from typing import Annotated, Final

from email_validator import EmailNotValidError, validate_email
from pydantic import AfterValidator, BeforeValidator
from pydantic_core import PydanticCustomError

MAX_EMAIL_LENGTH: Final = 254
DISPLAY_NAME_MAX: Final = 80
_BRAND_TERM: Final = "afterme"

# Characters that are invisible or reorder text; allowed ZWJ/ZWNJ are needed by many scripts.
_BIDI_AND_INVISIBLE: Final = frozenset(
    "\u200b\u200e\u200f\u202a\u202b\u202c\u202d\u202e\u2060\u2066\u2067\u2068\u2069\ufeff"
)
_URLISH_RE: Final = re.compile(
    r"(?i)(?:[a-z][a-z0-9+.-]*://|www\.|@|"
    r"\b[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.(?:[a-z]{2,24}|xn--[a-z0-9-]{2,59})\b)"
)
# Latin look-alikes from Cyrillic and Greek, folded before the brand check.
_CONFUSABLES: Final = str.maketrans(
    "\u0430\u0435\u043e\u0440\u0441\u0442\u043c\u0445\u043a\u043d\u0432\u0456\u0455\u0458\u0501"
    "\u03b1\u03b5\u03bf\u03c1\u03c4\u03bc\u03ba\u03bd0134",
    "aeopctmxkhbisjdaeoptmkvolea",
)
_LOCALE_RE: Final = re.compile(
    r"^(?P<lang>[A-Za-z]{2,3})(?:-(?P<script>[A-Za-z]{4}))?(?:-(?P<region>[A-Za-z]{2}|\d{3}))?$"
)

# ISO 3166-1 alpha-2 officially assigned codes.
_ISO_COUNTRY_CODES_TEXT: Final = """
    AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR
    BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ
    EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW
    GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY
    KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV
    MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY
    QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG
    TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM
    ZW
    """
ISO_COUNTRY_CODES: Final = frozenset(_ISO_COUNTRY_CODES_TEXT.split())


def _fail(code: str, message: str) -> PydanticCustomError:
    return PydanticCustomError(code, message)


# --- email ----------------------------------------------------------------------------------


def clean_email(value: object) -> str:
    """Trim and validate an email address; returns the trimmed address (original casing)."""
    if not isinstance(value, str):
        raise _fail("invalid_email", "Enter a valid email address.")
    candidate = value.strip()
    if not candidate or len(candidate) > MAX_EMAIL_LENGTH:
        raise _fail("invalid_email", "Enter a valid email address.")
    try:
        validate_email(candidate, check_deliverability=False)
    except EmailNotValidError:
        raise _fail("invalid_email", "Enter a valid email address.") from None
    return candidate


def normalize_email(value: str) -> str:
    """The lookup key: ``lower(trim(email))`` (DATABASE §3.1)."""
    return value.strip().lower()


EmailField = Annotated[str, BeforeValidator(clean_email)]


# --- display name -----------------------------------------------------------------------------


def _brand_skeleton(value: str) -> str:
    folded = unicodedata.normalize("NFKC", value).casefold().translate(_CONFUSABLES)
    return "".join(ch for ch in folded if ch.isalnum())


def clean_display_name(value: object) -> str:
    if not isinstance(value, str):
        raise _fail("invalid_display_name", "Enter your name.")
    name = unicodedata.normalize("NFC", value).strip()
    if not name:
        raise _fail("too_short", "Enter your name.")
    if len(name) > DISPLAY_NAME_MAX:
        raise _fail("too_long", f"Use at most {DISPLAY_NAME_MAX} characters.")
    if any(unicodedata.category(ch) == "Cc" or ch in _BIDI_AND_INVISIBLE for ch in name):
        raise _fail("invalid_characters", "The name contains characters that aren't allowed.")
    if _URLISH_RE.search(name):
        raise _fail("display_name_link", "Names can't contain links, web addresses or emails.")
    if _BRAND_TERM in _brand_skeleton(name):
        raise _fail("display_name_reserved", "Names can't contain the word AfterMe.")
    return name


DisplayName = Annotated[str, BeforeValidator(clean_display_name)]


# --- relationship label ---------------------------------------------------------------------

RELATIONSHIP_LABEL_MAX: Final = 40


def clean_relationship_label(value: object) -> str:
    """Free text that describes ``other`` ("Godmother"): the same character rules as a display
    name (NFC, no control or bidi characters, no links) in at most 40 characters."""
    if not isinstance(value, str):
        raise _fail("invalid_relationship_label", "Describe the relationship in a few words.")
    label = unicodedata.normalize("NFC", value).strip()
    if not label:
        raise _fail("too_short", "Describe the relationship in a few words.")
    if len(label) > RELATIONSHIP_LABEL_MAX:
        raise _fail("too_long", f"Use at most {RELATIONSHIP_LABEL_MAX} characters.")
    if any(unicodedata.category(ch) == "Cc" or ch in _BIDI_AND_INVISIBLE for ch in label):
        raise _fail("invalid_characters", "The text contains characters that aren't allowed.")
    if _URLISH_RE.search(label):
        raise _fail("contains_link", "This can't contain links, web addresses or emails.")
    return label


# --- timezone, locale, country --------------------------------------------------------------


@cache
def _zones() -> frozenset[str]:
    return frozenset(zoneinfo.available_timezones())


def clean_timezone(value: object) -> str:
    if not isinstance(value, str) or len(value) > 64 or value not in _zones():  # noqa: PLR2004
        raise _fail("invalid_timezone", "Choose a timezone from the list.")
    zoneinfo.ZoneInfo(value)  # loads from tzdata; raises if unusable
    return value


TimezoneName = Annotated[str, BeforeValidator(clean_timezone)]


def clean_locale(value: object) -> str:
    if not isinstance(value, str):
        raise _fail("invalid_locale", "Use a language tag such as en or en-IN.")
    match = _LOCALE_RE.match(value.strip())
    if match is None:
        raise _fail("invalid_locale", "Use a language tag such as en or en-IN.")
    parts = [match["lang"].lower()]
    if match["script"]:
        parts.append(match["script"].title())
    if match["region"]:
        parts.append(match["region"].upper())
    return "-".join(parts)


LocaleTag = Annotated[str, BeforeValidator(clean_locale)]


def clean_country_code(value: object) -> str:
    if not isinstance(value, str) or value.strip().upper() not in ISO_COUNTRY_CODES:
        raise _fail("invalid_country_code", "Use a two-letter country code such as IN.")
    return value.strip().upper()


CountryCode = Annotated[str, BeforeValidator(clean_country_code)]


_PHONE_RE: Final = re.compile(r"^\+[1-9][0-9]{6,14}$")


def clean_phone(value: object) -> str:
    """E.164 (``+`` and 7 to 15 digits), the same pattern the database CHECK enforces."""
    if not isinstance(value, str) or _PHONE_RE.fullmatch(value.strip()) is None:
        raise _fail("invalid_phone", "Use international format, for example +919876543210.")
    return value.strip()


PhoneE164 = Annotated[str, BeforeValidator(clean_phone)]


def _six_digits(value: str) -> str:
    if len(value) != 6 or not value.isascii() or not value.isdigit():  # noqa: PLR2004
        raise _fail("invalid_code_format", "Enter the 6-digit code.")
    return value


SixDigitCode = Annotated[str, AfterValidator(_six_digits)]
