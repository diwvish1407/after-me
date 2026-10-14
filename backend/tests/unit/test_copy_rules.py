"""The wording rules of USER_FLOWS §15 as a test (Phase 10 copy review, TEST_PLAN §8 "Copy review").

Every message a person or a contact can receive passes through one of four places: the email
templates, the web page templates, the push copy and the email subjects. A reviewer reads them
once; this test keeps the next edit honest. It checks the rules that can be checked by a machine:
no vocabulary that the product has promised never to use, no exclamation marks, and the lines
every contact-facing message must carry. Whether a message is *kind* still needs a person
(MANUAL_TEST_SHEET L01/L02).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

import app.notifications as notifications_pkg
import app.web as web_pkg
from app.notifications import outbox
from app.notifications.mailer import _SUBJECTS
from app.notifications.render import PUSH_COPY

pytestmark = pytest.mark.no_db

EMAIL_DIR = Path(notifications_pkg.__file__).parent / "templates" / "email"
WEB_DIR = Path(web_pkg.__file__).parent / "templates"

# USER_FLOWS §15, "Avoid" column. Word boundaries, case-insensitive. ``fire``/``trigger`` as
# product vocabulary are about stages, never about what a person reads.
FORBIDDEN = re.compile(
    r"\b("
    r"death|dead|die|died|dies|dying|deceased|passed away|pass away|late husband|late wife|"
    r"beneficiar\w*|heirs?|next of kin|"
    r"countdown|ticking|time is running out|"
    r"unlock (?:the )?secrets?|reveal\w*|"
    r"triggers?|triggered|payload|"
    r"urgent|immediately|hurry|act now|danger(?:ous)?"
    r")\b",
    re.IGNORECASE,
)
# Phrases that are allowed to contain a forbidden word because the product must say them.
ALLOWED_SENTENCES = (
    # The emergency line: "If you believe someone is in danger, contact your local emergency
    # services." is required in every alert and is the only place "danger" may appear.
    "in danger",
    # The terms of service's limit-of-liability clause: the law's own words for what a
    # limitation can never exclude. It is in /legal/terms only, never in a message.
    "death or personal injury",
)

CONTACT_FACING = (
    "contact_alert",
    "contact_alert_with_release",
    "contact_alert_withdrawn",
    "contact_all_clear",
    "contact_release",
    "contact_invitation",
    "portal_code",
)
# The ones that can reach a stranger who has not asked for them: they must say how to stop.
MUST_OFFER_OPT_OUT = (
    "contact_alert",
    "contact_alert_with_release",
    "contact_alert_withdrawn",
    "contact_all_clear",
    "contact_release",
    "contact_invitation",
)


def _templates() -> list[Path]:
    return sorted(EMAIL_DIR.glob("*.txt.j2"))


def _scrub(text: str) -> str:
    for allowed in ALLOWED_SENTENCES:
        text = text.replace(allowed, "")
    return text


def _plain(text: str) -> str:
    """The words a reader sees: Jinja tags and expressions are not copy."""
    text = re.sub(r"{#.*?#}", "", text, flags=re.DOTALL)
    text = re.sub(r"{%.*?%}", "", text, flags=re.DOTALL)
    return re.sub(r"{{.*?}}", "X", text, flags=re.DOTALL)


def test_the_template_directory_is_what_the_test_thinks_it_is() -> None:
    names = {p.name.removesuffix(".txt.j2") for p in _templates()}
    assert len(names) >= 30
    assert set(CONTACT_FACING) <= names


@pytest.mark.parametrize("path", _templates(), ids=lambda p: p.name)
def test_no_email_uses_a_word_the_product_promised_not_to(path: Path) -> None:
    copy = _scrub(_plain(path.read_text(encoding="utf-8")))
    found = FORBIDDEN.findall(copy)
    assert not found, f"{path.name}: {sorted(set(found))}"


@pytest.mark.parametrize("path", _templates(), ids=lambda p: p.name)
def test_no_email_shouts(path: Path) -> None:
    copy = _plain(path.read_text(encoding="utf-8"))
    assert "!" not in copy, f"{path.name}: exclamation mark"
    # no SHOUTED words of 4+ letters, except the two fixed product names
    shouted = [
        w
        for w in re.findall(r"\b[A-Z]{4,}\b", copy)
        if w not in {"SAFE", "AFTERME", "HTML", "DKIM", "SPF", "DMARC", "URL", "HTTPS"}
    ]
    assert not shouted, f"{path.name}: {shouted}"


def test_the_web_pages_follow_the_same_rules() -> None:
    pages = sorted(WEB_DIR.glob("*.j2"))
    assert len(pages) >= 15
    problems: list[str] = []
    for page in pages:
        copy = _scrub(_plain(page.read_text(encoding="utf-8")))
        # script bodies and attributes are not copy: look only at text between tags
        copy = re.sub(r"<script.*?</script>", "", copy, flags=re.DOTALL | re.IGNORECASE)
        text = " ".join(re.findall(r">([^<>]+)<", copy))
        for word in FORBIDDEN.findall(text):
            problems.append(f"{page.name}: {word}")
        if "!" in text:
            problems.append(f"{page.name}: exclamation mark")
    assert not problems, problems


def test_push_text_follows_the_rules_and_carries_no_name_or_time() -> None:
    assert set(PUSH_COPY) <= set(outbox.USER_CHANNELS)
    for template, (title, body) in PUSH_COPY.items():
        text = _scrub(f"{title} {body}")
        assert not FORBIDDEN.findall(text), (template, text)
        assert "!" not in text, template
        # a push shows on a locked screen: no names, no addresses, no clock times, no digits
        # beyond the fixed durations ("15 minutes", "1 hour")
        assert "@" not in text, template
        assert not re.search(r"\b\d{1,2}[:.]\d{2}\b", text), template


def test_subjects_follow_the_rules() -> None:
    for template, subject in _SUBJECTS.items():
        assert not FORBIDDEN.findall(_scrub(subject)), (template, subject)
        assert "!" not in subject, template
        assert len(subject) <= 90, template


@pytest.mark.parametrize("name", CONTACT_FACING)
def test_every_message_to_a_contact_says_it_is_not_an_emergency_service(name: str) -> None:
    text = (EMAIL_DIR / f"{name}.txt.j2").read_text(encoding="utf-8")
    assert "not an emergency service" in text.lower(), name


@pytest.mark.parametrize("name", MUST_OFFER_OPT_OUT)
def test_every_message_that_can_reach_a_stranger_offers_a_way_to_stop(name: str) -> None:
    text = (EMAIL_DIR / f"{name}.txt.j2").read_text(encoding="utf-8")
    assert "optout_link" in text, name


@pytest.mark.parametrize("name", CONTACT_FACING)
def test_every_message_to_a_contact_says_where_to_report_misuse(name: str) -> None:
    """SECURITY_REVIEW F-09: a stranger who got one of these can tell us. The address and the
    support page come from the settings (``Mailer`` supplies them to every template)."""
    text = (EMAIL_DIR / f"{name}.txt.j2").read_text(encoding="utf-8")
    assert "{{ abuse_email }}" in text, name
    assert "{{ support_url }}" in text or name == "contact_invitation", name


def test_an_alert_says_it_may_not_mean_anything_is_wrong_and_names_a_next_step() -> None:
    alert = (EMAIL_DIR / "contact_alert.txt.j2").read_text(encoding="utf-8")
    assert "doesn't necessarily mean anything is wrong" in alert
    assert "emergency services" in alert
    withdrawn = (EMAIL_DIR / "contact_alert_withdrawn.txt.j2").read_text(encoding="utf-8")
    # a withdrawn alert must never claim that the person is safe: we do not know. Every sentence
    # that mentions "safe" must be one that denies the claim, in both branches of the template.
    for sentence in re.split(r"(?<=[.!?])\s+", _plain(withdrawn)):
        if re.search(r"\bsafe\b", sentence, re.IGNORECASE):
            assert re.search(
                r"\b(not a confirmation|does not tell you|doesn't tell you|not tell)\b",
                sentence,
                re.IGNORECASE,
            ), sentence


@pytest.mark.parametrize(
    "bad",
    [
        "They died last night.",
        "The beneficiary will be told.",
        "A countdown has started.",
        "We will reveal the information.",
        "Act now!",
    ],
)
def test_the_rules_would_catch_what_they_are_meant_to_catch(bad: str) -> None:
    """A control: a check that cannot fail is not a check."""
    assert FORBIDDEN.findall(bad) or "!" in bad
