"""Pure-function tests for the Phase 2 building blocks."""

from __future__ import annotations

import re
from datetime import UTC, datetime
from typing import Any

import pytest
from pydantic import ValidationError

from app.audit.writer import (
    KNOWN_ACTIONS,
    PHASE1_ACTIONS,
    PHASE2_ACTIONS,
    PHASE3_ACTIONS,
    PHASE4_ACTIONS,
    PHASE5_ACTIONS,
    PHASE6_ACTIONS,
    USER_VISIBLE_ACTIONS,
    AuditEvent,
    AuditMetadataError,
)
from app.auth.links import (
    hash_link_token,
    looks_like_reset_token,
    new_reset_token,
    reset_link,
)
from app.core.validation import clean_phone
from app.notifications.email import RecordingEmailProvider
from app.notifications.mailer import EmailTemplate, Mailer, mask_email
from app.users.schemas import ProfilePatchRequest
from app.web import security

pytestmark = pytest.mark.no_db


def test_reset_tokens_are_prefixed_unique_and_256_bit() -> None:
    tokens = {new_reset_token() for _ in range(50)}
    assert len(tokens) == 50
    for token in tokens:
        assert re.fullmatch(r"pr_[A-Za-z0-9_-]{43}", token)  # 32 bytes, base64url, no padding
        assert looks_like_reset_token(token)
    assert hash_link_token("pr_x") == hash_link_token("pr_x")
    assert len(hash_link_token("pr_x")) == 32
    assert hash_link_token("pr_x") != hash_link_token("pr_y")


@pytest.mark.parametrize(
    "token",
    [
        "",
        "pr_",
        "pr_short",
        "rt_" + "A" * 43,
        "pr_" + "A" * 44,
        "pr_" + "A" * 42 + "!",
        " pr_" + "A" * 43,
        "pr_" + "A" * 43 + "\n",
    ],
)
def test_malformed_reset_tokens_are_recognised_before_any_lookup(token: str) -> None:
    assert not looks_like_reset_token(token)


def test_reset_link_keeps_the_token_in_the_fragment() -> None:
    link = reset_link("https://afterme.example", "pr_abc")
    assert link == "https://afterme.example/a/reset#pr_abc"
    assert "?" not in link


@pytest.mark.parametrize("phone", ["+919876543210", "+14155552671", "+1234567", "+123456789012345"])
def test_phone_accepts_e164(phone: str) -> None:
    assert clean_phone(f"  {phone} ") == phone


@pytest.mark.parametrize(
    "phone",
    [
        "",
        "919876543210",
        "+0123456",
        "+123456",
        "+1234567890123456",
        "+91 9876543210",
        "+91-98765",
        5,
        None,
        "+12345678a",
    ],
)
def test_phone_rejects_everything_else(phone: object) -> None:
    from pydantic_core import PydanticCustomError

    with pytest.raises(PydanticCustomError):
        clean_phone(phone)


def test_profile_patch_distinguishes_absent_from_null() -> None:
    patch = ProfilePatchRequest(phone_e164=None)
    assert patch.changes() == {"phone_e164": None}
    assert ProfilePatchRequest(display_name="Ann", locale="EN").changes() == {
        "display_name": "Ann",
        "locale": "en",
    }
    with pytest.raises(ValidationError):
        ProfilePatchRequest()


@pytest.mark.parametrize(
    ("address", "masked"),
    [("alice@example.com", "a***@example.com"), ("x@y.io", "x***@y.io"), ("broken", "***")],
)
def test_mask_email(address: str, masked: str) -> None:
    assert mask_email(address) == masked


SAMPLE_CONTEXT: dict[EmailTemplate, dict[str, Any]] = {
    EmailTemplate.SIGNUP_CODE: {"display_name": "Asha", "code": "482913", "expires_minutes": 15},
    EmailTemplate.ACCOUNT_EXISTS: {},
    EmailTemplate.ACCOUNT_LOCKED: {"lock_minutes": 15},
    EmailTemplate.REFRESH_REUSE_DETECTED: {},
    EmailTemplate.SESSIONS_REVOKED: {"sessions_revoked": 3},
    EmailTemplate.NEW_DEVICE_LOGIN: {"platform": "android", "app_version": "1.0.0+12"},
    EmailTemplate.PASSWORD_RESET_LINK: {
        "link": "https://afterme.test/a/reset#pr_example",
        "expires_minutes": 30,
    },
    EmailTemplate.PASSWORD_RESET_COMPLETED: {},
    EmailTemplate.PASSWORD_CHANGED: {},
    EmailTemplate.EMAIL_CHANGE_CODE: {
        "code": "135790",
        "expires_minutes": 15,
    },
    EmailTemplate.EMAIL_CHANGE_REQUESTED: {"new_email_masked": "n***@example.com"},
    EmailTemplate.EMAIL_CHANGED: {"new_email_masked": "n***@example.com"},
    # Phase 3 (the contact emails have their own tests in test_contact_units.py).
    EmailTemplate.CONTACT_INVITATION: {
        "contact_name": "Asha",
        "inviter_name": "Diwakar",
        "inviter_email": "diwakar@example.com",
        "accept_link": "https://afterme.test/c/open#ci_example",
        "optout_link": "https://afterme.test/c/optout#oo_example",
        "expires_days": 14,
        "support_url": "https://afterme.test/support",
    },
    EmailTemplate.CONTACT_ACCEPTED: {"contact_name": "Asha"},
    EmailTemplate.CONTACT_DECLINED: {"contact_name": "Asha"},
    EmailTemplate.CONTACT_OPTED_OUT: {"contact_name": "Asha"},
    # Phase 5 (the engine's messages; their delivery has its own tests in tests/engine).
    EmailTemplate.CHECKIN_PRE_REMINDER: {"user_name": "Asha", "due_at": "8:00 PM"},
    EmailTemplate.INCIDENT_MISSED: {
        "user_name": "Asha",
        "due_time": "8:00 PM",
        "who": "Mom",
        "first_stage_at": "11:00 PM",
    },
    EmailTemplate.INCIDENT_MIDPOINT: {
        "user_name": "Asha",
        "who": "Mom",
        "first_stage_at": "11:00 PM",
    },
    EmailTemplate.INCIDENT_LAST_CHANCE: {"user_name": "Asha", "who": "Mom"},
    EmailTemplate.INCIDENT_DELAYED: {
        "user_name": "Asha",
        "who": "Mom",
        "first_stage_at": "11:30 PM",
    },
    EmailTemplate.STAGE_EXECUTED: {"user_name": "Asha", "notified_phrase": "Mom has been notified"},
    EmailTemplate.RELEASE_FINAL_WARNING: {
        "user_name": "Asha",
        "release_count": 1,
        "names": "Brother",
    },
    EmailTemplate.ALL_CLEAR_CONFIRMATION: {
        "user_name": "Asha",
        "names": "Mom",
        "count": 1,
        "next_due_at": "tomorrow at 8:00 PM",
    },
    EmailTemplate.SERVICE_INTERRUPTION: {"user_name": "Asha"},
    EmailTemplate.CONTACT_ALERT: {
        "contact_name": "Asha",
        "user_name": "Diwakar",
        "user_email": "diwakar@example.com",
        "last_checkin": "Tuesday 14 Oct, 7:30 PM IST",
        "due_at": "Wednesday 15 Oct, 8:00 PM IST",
        "optout_link": "https://afterme.test/c/optout#oo_example",
    },
    EmailTemplate.CONTACT_ALERT_WITH_RELEASE: {
        "contact_name": "Asha",
        "user_name": "Diwakar",
        "user_email": "diwakar@example.com",
        "last_checkin": "Tuesday 14 Oct, 7:30 PM IST",
        "due_at": "Wednesday 15 Oct, 8:00 PM IST",
        "release_link": "https://afterme.test/c/release#rt_example",
        "expires_on": "14 Nov 2026",
        "optout_link": "https://afterme.test/c/optout#oo_example",
    },
    EmailTemplate.CONTACT_RELEASE: {
        "contact_name": "Asha",
        "user_name": "Diwakar",
        "user_email": "diwakar@example.com",
        "after_text": "24 hours",
        "release_link": "https://afterme.test/c/release#rt_example",
        "expires_on": "14 Nov 2026",
        "optout_link": "https://afterme.test/c/optout#oo_example",
    },
    EmailTemplate.PORTAL_CODE: {
        "contact_name": "Asha",
        "user_name": "Diwakar",
        "user_email": "diwakar@example.com",
        "code": "482913",
        "optout_link": "https://afterme.test/c/optout#oo_example",
    },
    EmailTemplate.CONTACT_ALL_CLEAR: {
        "contact_name": "Asha",
        "user_name": "Diwakar",
        "checked_in_at": "9:01 PM IST",
        "optout_link": "https://afterme.test/c/optout#oo_example",
    },
}


def test_every_email_template_has_sample_context() -> None:
    assert set(SAMPLE_CONTEXT) == set(EmailTemplate)


@pytest.mark.parametrize("template", list(EmailTemplate), ids=lambda t: t.value)
def test_every_email_template_renders(template: EmailTemplate) -> None:
    mailer = Mailer(RecordingEmailProvider(), sender="AfterMe <no-reply@afterme.test>")
    message = mailer.render(template, to="user@example.com", **SAMPLE_CONTEXT[template])
    assert message.template == template.value
    assert message.to == "user@example.com"
    assert message.subject.strip()
    assert "{" not in message.subject
    assert "{{" not in message.text
    assert message.text.startswith(("Hello,", "Hi Asha,"))
    assert "AfterMe is not an emergency service." in message.text
    assert len(message.text) < 1500  # short enough to read on a lock screen preview
    for value in SAMPLE_CONTEXT[template].values():
        if isinstance(value, str):
            assert value in message.text


def test_security_emails_say_what_to_do_when_it_was_not_you() -> None:
    mailer = Mailer(RecordingEmailProvider(), sender="x@afterme.test")
    for template in (
        EmailTemplate.PASSWORD_CHANGED,
        EmailTemplate.PASSWORD_RESET_COMPLETED,
        EmailTemplate.EMAIL_CHANGED,
        EmailTemplate.EMAIL_CHANGE_REQUESTED,
    ):
        text = mailer.render(template, to="u@example.com", **SAMPLE_CONTEXT[template]).text
        assert re.search(r"(did|was) not", text), template


def test_audit_action_catalogue() -> None:
    assert PHASE1_ACTIONS.isdisjoint(PHASE2_ACTIONS)
    assert PHASE3_ACTIONS.isdisjoint(PHASE1_ACTIONS | PHASE2_ACTIONS)
    assert PHASE4_ACTIONS.isdisjoint(PHASE1_ACTIONS | PHASE2_ACTIONS | PHASE3_ACTIONS)
    assert PHASE5_ACTIONS.isdisjoint(
        PHASE1_ACTIONS | PHASE2_ACTIONS | PHASE3_ACTIONS | PHASE4_ACTIONS
    )
    assert PHASE6_ACTIONS.isdisjoint(
        PHASE1_ACTIONS | PHASE2_ACTIONS | PHASE3_ACTIONS | PHASE4_ACTIONS | PHASE5_ACTIONS
    )
    assert KNOWN_ACTIONS == (
        PHASE1_ACTIONS
        | PHASE2_ACTIONS
        | PHASE3_ACTIONS
        | PHASE4_ACTIONS
        | PHASE5_ACTIONS
        | PHASE6_ACTIONS
    )
    # SECURITY §9 marks these Phase 6 events as shown in the Activity feed.
    assert {
        "instruction.recipients_changed",
        "release.created",
        "release.revoked",
        "release.viewed",
    } <= USER_VISIBLE_ACTIONS
    assert {"instruction.created", "instruction.updated", "instruction.deleted"}.isdisjoint(
        USER_VISIBLE_ACTIONS
    )
    assert not {a for a in PHASE6_ACTIONS if a.startswith("portal.")} & USER_VISIBLE_ACTIONS
    # SECURITY §9 marks these Phase 5 events as shown in the Activity feed.
    assert {
        "plan.updated",
        "incident.opened",
        "incident.resolved",
        "incident.cancelled",
        "incident.voided",
        "escalation.final_warning_sent",
        "escalation.stage_executed",
    } <= USER_VISIBLE_ACTIONS
    assert "escalation.action_held" not in USER_VISIBLE_ACTIONS  # operator-facing only
    assert {
        "checkin.recorded",
        "schedule.updated",
        "schedule.activated",
        "schedule.deactivated",
    } == PHASE4_ACTIONS
    assert PHASE4_ACTIONS <= USER_VISIBLE_ACTIONS  # SECURITY §9: all four are in the feed
    assert {
        "auth.password_changed",
        "auth.password_reset_requested",
        "auth.password_reset_completed",
        "auth.email_change_requested",
        "auth.email_changed",
        "profile.updated",
        "profile.timezone_changed",
    } == PHASE2_ACTIONS
    # SECURITY §9 marks these as shown in the Activity feed.
    assert {
        "auth.password_changed",
        "auth.password_reset_completed",
        "auth.email_changed",
        "profile.timezone_changed",
    } <= USER_VISIBLE_ACTIONS
    assert "auth.password_reset_requested" not in USER_VISIBLE_ACTIONS
    event = AuditEvent(
        action="auth.email_changed", occurred_at=datetime.now(UTC), subject_user_id=None
    )
    assert event.to_row().user_visible is True
    with pytest.raises(AuditMetadataError):
        AuditEvent(action="auth.nope", occurred_at=datetime.now(UTC), subject_user_id=None).to_row()


def test_csrf_values_and_comparison() -> None:
    value = security.new_csrf_value()
    assert security.well_formed_csrf(value) == value
    assert security.csrf_matches(value, value)
    assert not security.csrf_matches(value, value[:-1] + ("A" if value[-1] != "A" else "B"))
    assert not security.csrf_matches(value, None)
    assert not security.csrf_matches(None, value)
    assert not security.csrf_matches(None, None)
    assert not security.csrf_matches("", "")
    assert not security.csrf_matches("short", "short")  # not a value this server would issue
    assert security.well_formed_csrf("has space " * 5) is None


def test_content_security_policy_is_strict() -> None:
    policy = security.content_security_policy("NONCE123")
    directives = dict(part.strip().split(" ", 1) for part in policy.split(";") if part.strip())
    assert directives["default-src"] == "'none'"
    assert directives["script-src"] == "'nonce-NONCE123'"
    assert directives["style-src"] == "'self'"
    assert directives["frame-ancestors"] == "'none'"
    assert directives["base-uri"] == "'none'"
    assert directives["form-action"] == "'self'"
    assert "unsafe" not in policy
    assert security.new_nonce() != security.new_nonce()
