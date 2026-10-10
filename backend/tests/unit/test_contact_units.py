"""Pure-function tests for Phase 3: tokens, hashing, label rules, limits, email templates."""

from __future__ import annotations

import re
import uuid
from datetime import timedelta
from typing import Any

import pytest
from jinja2 import meta
from pydantic_core import PydanticCustomError

from app.audit import writer as audit
from app.contacts.tokens import (
    CONSENT_TEXT_VERSION,
    INVITATION_TTL,
    hash_invitation_token,
    invitation_link,
    looks_like_invitation_token,
    new_invitation_token,
    new_optout_token,
    optout_link,
    optout_token_contact_id,
    suppression_hash,
    suppression_hash_candidates,
    verify_optout_token,
)
from app.core.validation import clean_relationship_label
from app.notifications.email import RecordingEmailProvider
from app.notifications.mailer import _SUBJECTS, EmailTemplate, Mailer
from app.security.hashing import Pepper
from app.security.rate_limit import (
    CONTACT_CREATE_PER_USER,
    INVITATION_PER_USER,
    INVITATION_RESEND_PER_CONTACT,
    WEB_CONTACT_PER_IP,
)
from app.users.entitlements import TIER_LIMITS, limits_for

pytestmark = pytest.mark.no_db

PEPPER = Pepper("p" * 40)
ADDRESS = "mom@example.com"
GENDERED = re.compile(r"\b(he|she|his|hers|him|himself|herself)\b|\bher\b", re.IGNORECASE)


# --- tokens ------------------------------------------------------------------------------------


def test_invitation_tokens_are_256_bit_and_only_their_hash_is_stable() -> None:
    first, second = new_invitation_token(), new_invitation_token()
    assert first != second
    assert re.fullmatch(r"ci_[A-Za-z0-9_-]{43}", first)  # 43 URL-safe characters = 256 bits
    assert looks_like_invitation_token(first)
    assert len(hash_invitation_token(first)) == 32
    assert hash_invitation_token(first) == hash_invitation_token(first)
    assert hash_invitation_token(first) != hash_invitation_token(second)


@pytest.mark.parametrize(
    "value",
    [
        "",
        "ci_",
        "ci_short",
        "pr_" + "A" * 43,
        "ci_" + "A" * 44,
        "ci_" + "A" * 42 + "!",
        " ci_" + "A" * 43,
    ],
)
def test_malformed_invitation_tokens_are_recognised_before_any_lookup(value: str) -> None:
    assert not looks_like_invitation_token(value)


def test_links_carry_the_token_in_the_fragment() -> None:
    token = new_invitation_token()
    assert invitation_link("https://afterme.test", token) == f"https://afterme.test/c/open#{token}"
    assert optout_link("https://afterme.test", "oo_x") == "https://afterme.test/c/optout#oo_x"


def test_invitations_are_valid_for_fourteen_days_and_consent_text_is_versioned() -> None:
    assert timedelta(days=14) == INVITATION_TTL
    assert CONSENT_TEXT_VERSION == "2026-10-v1"


def test_optout_tokens_round_trip_and_bind_the_contact_id() -> None:
    contact_id = uuid.uuid4()
    token = new_optout_token(PEPPER, contact_id, ADDRESS)
    assert re.fullmatch(r"oo_[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}", token)
    assert token == new_optout_token(PEPPER, contact_id, ADDRESS)  # stateless and stable
    assert verify_optout_token(PEPPER, token, email_normalized=ADDRESS) == contact_id
    assert optout_token_contact_id(token) == contact_id
    other = uuid.uuid4()
    mac = token.split(".")[1]
    assert verify_optout_token(PEPPER, f"oo_{other}.{mac}", email_normalized=ADDRESS) is None


def test_optout_tokens_bind_the_address_they_were_issued_for() -> None:
    """After the account holder corrects an address, the old address's link must not act on the
    contact, which now stands for somebody else."""
    contact_id = uuid.uuid4()
    token = new_optout_token(PEPPER, contact_id, ADDRESS)
    assert verify_optout_token(PEPPER, token, email_normalized="corrected@example.com") is None
    assert new_optout_token(PEPPER, contact_id, "corrected@example.com") != token


def test_optout_token_shape_check_names_no_contact_for_garbage() -> None:
    assert optout_token_contact_id("oo_nonsense") is None
    assert optout_token_contact_id("") is None


@pytest.mark.parametrize(
    "mutate",
    [
        lambda t: t[:-1] + ("A" if t[-1] != "A" else "B"),
        lambda t: t[:-1],
        lambda t: t + "A",
        lambda t: t.upper(),
        lambda t: t.replace("oo_", "ci_"),
        lambda t: t.replace(".", ":"),
        lambda t: "",
        lambda t: "oo_" + "0" * 36 + "." + "A" * 43,
    ],
)
def test_tampered_optout_tokens_are_refused(mutate: Any) -> None:
    token = new_optout_token(PEPPER, uuid.uuid4(), ADDRESS)
    assert verify_optout_token(PEPPER, mutate(token), email_normalized=ADDRESS) is None


def test_only_the_canonical_spelling_of_a_mac_is_accepted() -> None:
    """The last base64 character of a 32-byte MAC carries unused bits, so a second spelling decodes
    to the same bytes. It must not be accepted as a different, valid token."""
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    contact_id = uuid.uuid4()
    token = new_optout_token(PEPPER, contact_id, ADDRESS)
    last = alphabet.index(token[-1])
    alias = token[:-1] + alphabet[last ^ 1]
    assert alias != token
    assert verify_optout_token(PEPPER, token, email_normalized=ADDRESS) == contact_id
    assert verify_optout_token(PEPPER, alias, email_normalized=ADDRESS) is None


def test_optout_tokens_survive_pepper_rotation_in_one_direction() -> None:
    old, new = Pepper("o" * 40), Pepper("n" * 40, previous="o" * 40)
    contact_id = uuid.uuid4()
    issued_before = new_optout_token(old, contact_id, ADDRESS)
    assert verify_optout_token(new, issued_before, email_normalized=ADDRESS) == contact_id
    issued_after = new_optout_token(new, contact_id, ADDRESS)
    assert issued_after != issued_before
    assert verify_optout_token(new, issued_after, email_normalized=ADDRESS) == contact_id
    retired = Pepper("n" * 40)  # the previous pepper is no longer configured
    assert verify_optout_token(retired, issued_before, email_normalized=ADDRESS) is None
    assert verify_optout_token(old, issued_after, email_normalized=ADDRESS) is None


def test_suppression_hashes_are_keyed_and_context_separated() -> None:
    address = "mom@example.com"
    stored = suppression_hash(PEPPER, address)
    assert len(stored) == 32
    assert address.encode() not in stored
    assert stored != suppression_hash(Pepper("q" * 40), address)
    assert stored != PEPPER.hmac("optout", address)  # a hash for one purpose never serves another
    assert stored != PEPPER.ip_hash(address)


def test_suppression_lookup_also_covers_the_previous_pepper() -> None:
    old, new = Pepper("o" * 40), Pepper("n" * 40, previous="o" * 40)
    written_before_rotation = suppression_hash(old, "mom@example.com")
    assert written_before_rotation in suppression_hash_candidates(new, "mom@example.com")
    assert suppression_hash(new, "mom@example.com") in suppression_hash_candidates(
        new, "mom@example.com"
    )
    assert len(suppression_hash_candidates(old, "mom@example.com")) == 1


# --- validation and limits ---------------------------------------------------------------------


def test_relationship_label_rules() -> None:
    assert clean_relationship_label("  Godmother ") == "Godmother"
    assert clean_relationship_label("Café") == "Café"
    assert clean_relationship_label("x" * 40) == "x" * 40
    for bad, code in [
        ("x" * 41, "too_long"),
        ("   ", "too_short"),
        ("a\x07b", "invalid_characters"),
        ("a" + chr(0x202E) + "b", "invalid_characters"),
        ("see example.com", "contains_link"),
        ("ping me@x", "contains_link"),
        (5, "invalid_relationship_label"),
    ]:
        with pytest.raises(PydanticCustomError) as raised:
            clean_relationship_label(bad)
        assert raised.value.type == code


def test_tier_limits() -> None:
    assert limits_for("free") == TIER_LIMITS["free"]
    assert (limits_for("free").contacts, limits_for("premium").contacts) == (1, 25)
    assert (limits_for("free").instructions, limits_for("premium").instructions) == (3, 200)
    assert (limits_for("free").stages, limits_for("premium").stages) == (2, 10)
    assert (limits_for("free").custom_offsets, limits_for("premium").custom_offsets) == (
        False,
        True,
    )
    assert limits_for("something-new") == limits_for("free")  # fail closed


def test_rate_limit_rules() -> None:
    assert (CONTACT_CREATE_PER_USER.limit, CONTACT_CREATE_PER_USER.window) == (
        20,
        timedelta(days=1),
    )
    assert (INVITATION_PER_USER.limit, INVITATION_PER_USER.window) == (10, timedelta(days=1))
    assert (INVITATION_RESEND_PER_CONTACT.limit, INVITATION_RESEND_PER_CONTACT.window) == (
        3,
        timedelta(days=7),
    )
    assert (WEB_CONTACT_PER_IP.limit, WEB_CONTACT_PER_IP.window) == (20, timedelta(hours=1))


def test_audit_actions_and_their_visibility() -> None:
    visible = {
        audit.CONTACT_CREATED,
        audit.CONTACT_DELETED,
        audit.CONTACT_INVITATION_SENT,
        audit.CONTACT_ACCEPTED,
        audit.CONTACT_DECLINED,
        audit.CONTACT_OPTED_OUT,
    }
    assert visible <= audit.USER_VISIBLE_ACTIONS
    assert audit.CONTACT_UPDATED not in audit.USER_VISIBLE_ACTIONS
    assert visible | {audit.CONTACT_UPDATED} == audit.PHASE3_ACTIONS
    assert audit.PHASE3_ACTIONS <= audit.KNOWN_ACTIONS
    assert {a for a in audit.PHASE3_ACTIONS if not a.startswith("contact.")} == set()


# --- emails ------------------------------------------------------------------------------------


def _context(mailer: Mailer, template: EmailTemplate) -> dict[str, Any]:
    source = mailer._env.loader.get_source(mailer._env, f"{template.value}.txt.j2")[0]  # type: ignore[union-attr]
    names = meta.find_undeclared_variables(mailer._env.parse(source))
    names |= set(re.findall(r"{(\w+)}", _SUBJECTS[template]))
    return {name: f"<{name}>" for name in names}


@pytest.mark.parametrize("template", list(EmailTemplate), ids=lambda t: t.value)
def test_every_email_template_renders_calmly_and_is_not_an_emergency_service(
    template: EmailTemplate,
) -> None:
    mailer = Mailer(RecordingEmailProvider(), sender="AfterMe <no-reply@afterme.test>")
    message = mailer.render(template, to="x@example.com", **_context(mailer, template))
    assert "AfterMe is not an emergency service." in message.text
    assert not GENDERED.search(message.text), "pronouns must stay neutral"
    assert not GENDERED.search(message.subject)
    assert message.subject.strip()
    assert "{{" not in message.text
    assert "{%" not in message.text


def test_contact_notices_name_the_contact_and_no_address() -> None:
    mailer = Mailer(RecordingEmailProvider(), sender="x@afterme.test")
    for template, phrase in [
        (EmailTemplate.CONTACT_ACCEPTED, "accepted your invitation"),
        (EmailTemplate.CONTACT_DECLINED, "declined your invitation"),
        (EmailTemplate.CONTACT_OPTED_OUT, "asked us not to contact them"),
    ]:
        message = mailer.render(template, to="owner@example.com", contact_name="Mom")
        assert "Mom" in message.subject
        assert phrase in message.text
        assert "@" not in message.text
        assert "People tab" in message.text


def test_invitation_email_has_what_a_recipient_needs() -> None:
    mailer = Mailer(RecordingEmailProvider(), sender="x@afterme.test")
    message = mailer.render(
        EmailTemplate.CONTACT_INVITATION,
        to="mom@example.com",
        contact_name="Mom",
        inviter_name="Asha",
        inviter_email="asha@example.com",
        accept_link="https://afterme.test/c/open#ci_X",
        optout_link="https://afterme.test/c/optout#oo_Y",
        expires_days=14,
        support_url="https://afterme.test/support",
    )
    assert message.subject == "Asha added you as a trusted contact on AfterMe"
    text = message.text
    for expected in (
        "Hi Mom,",
        "Asha (asha@example.com)",
        "https://afterme.test/c/open#ci_X",
        "https://afterme.test/c/optout#oo_Y",
        "You don't need to install anything",
        "expires in 14 days",
        "Never contact me about AfterMe again",
        "https://afterme.test/support",
        "AfterMe is not an emergency service.",
    ):
        assert expected in text
    assert not GENDERED.search(text)
