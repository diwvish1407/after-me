"""The pure parts of the operator's per-account commands (``cli.admin user ...``): the audit
writer's rule for the operator's reason, the reason check, and the command line. The commands
themselves, against a real database and the worker role, are in
``tests/engine/test_operator_users.py``.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

import pytest

from app.audit.writer import (
    KNOWN_ACTIONS,
    MAX_OPERATOR_TEXT,
    OPERATOR_SET_TIER,
    OPERATOR_SUSPEND_USER,
    OPERATOR_TEXT_ACTIONS,
    OPERATOR_TEXT_KEY,
    OPERATOR_UNSUSPEND_USER,
    SCHEDULE_UPDATED,
    USER_VISIBLE_ACTIONS,
    AuditEvent,
    AuditMetadataError,
    validate_operator_text,
)
from app.ops.users import UserCommandError, clean_reason
from cli.admin import _parser

pytestmark = pytest.mark.no_db

NOW = datetime(2026, 10, 12, 9, 0, tzinfo=UTC)
USER = uuid.UUID(int=7)
USER_ACTIONS = (OPERATOR_SET_TIER, OPERATOR_SUSPEND_USER, OPERATOR_UNSUSPEND_USER)


def _event(action: str, **metadata: str | int) -> AuditEvent:
    return AuditEvent(
        action=action,
        occurred_at=NOW,
        subject_user_id=USER,
        actor_type="operator",
        resource_type="user",
        resource_id=USER,
        metadata=dict(metadata),
        user_visible=False,
    )


# --- the audit writer ---------------------------------------------------------------------


@pytest.mark.parametrize("action", USER_ACTIONS)
def test_the_three_commands_are_known_operator_text_actions_the_holder_never_sees(
    action: str,
) -> None:
    assert action in KNOWN_ACTIONS
    assert action in OPERATOR_TEXT_ACTIONS
    assert action not in USER_VISIBLE_ACTIONS
    # not visible even when a caller forgets to say so
    row = AuditEvent(action=action, occurred_at=NOW, subject_user_id=USER).to_row()
    assert row.user_visible is False


def test_the_operators_reason_is_kept_as_given_up_to_200_characters() -> None:
    reason = "Abuse report #4412: 3 complaints; see ticket (Priya, 2026-10-12) - beta tester"
    row = _event(OPERATOR_SUSPEND_USER, operator="alex", reason_length=len(reason)).to_row()
    assert row.metadata_ == {"operator": "alex", "reason_length": len(reason)}

    stored = AuditEvent(
        action=OPERATOR_SUSPEND_USER,
        occurred_at=NOW,
        subject_user_id=USER,
        metadata={"operator": "alex", OPERATOR_TEXT_KEY: reason},
    ).to_row()
    assert stored.metadata_[OPERATOR_TEXT_KEY] == reason

    longest = "x" * MAX_OPERATOR_TEXT
    assert validate_operator_text(longest) == longest


@pytest.mark.parametrize(
    "value",
    [
        "",
        "x" * (MAX_OPERATOR_TEXT + 1),
        "two\nlines",
        "tab\tseparated",
        "escape \x1b[31m",
        "null\x00byte",
        "bidi " + chr(0x202E) + " override",
        "zero" + chr(0x200B) + "width",
        "lone " + chr(0xD800) + " surrogate",
        42,
        None,
    ],
)
def test_operator_text_that_is_not_one_printable_line_is_refused(value: object) -> None:
    with pytest.raises(AuditMetadataError):
        validate_operator_text(value)


def test_the_free_text_key_exists_only_for_the_commands_that_take_a_reason() -> None:
    sentence = "a sentence with spaces"
    for action in USER_ACTIONS:
        AuditEvent(
            action=action,
            occurred_at=NOW,
            subject_user_id=USER,
            metadata={OPERATOR_TEXT_KEY: sentence},
        ).to_row()
    # anywhere else it goes through the ordinary rule (identifiers and short codes only)
    with pytest.raises(AuditMetadataError):
        AuditEvent(
            action=SCHEDULE_UPDATED,
            occurred_at=NOW,
            subject_user_id=USER,
            metadata={OPERATOR_TEXT_KEY: sentence},
        ).to_row()


def test_the_other_metadata_of_those_commands_still_follows_the_ordinary_rules() -> None:
    for bad in ({"email": "a"}, {"password": "x"}, {"free_form": "has spaces in it"}):
        with pytest.raises(AuditMetadataError):
            AuditEvent(
                action=OPERATOR_SET_TIER,
                occurred_at=NOW,
                subject_user_id=USER,
                metadata={OPERATOR_TEXT_KEY: "fine", **bad},
            ).to_row()


# --- the reason check ---------------------------------------------------------------------


def test_clean_reason_trims_and_refuses_what_the_audit_row_would_refuse() -> None:
    assert clean_reason("  beta tester, premium until 2026-12-31  ") == (
        "beta tester, premium until 2026-12-31"
    )
    for bad in ("", "   ", "x" * (MAX_OPERATOR_TEXT + 1), "a\nb", "a\x1bb"):
        with pytest.raises(UserCommandError):
            clean_reason(bad)
    assert len(clean_reason("y" * MAX_OPERATOR_TEXT)) == MAX_OPERATOR_TEXT


# --- the command line ---------------------------------------------------------------------


def test_the_command_line_takes_a_user_a_reason_and_a_known_tier() -> None:
    parser = _parser()
    args = parser.parse_args(["user", "set-tier", str(USER), "premium", "--reason", "beta"])
    assert (args.command, args.user_command, args.user_id, args.tier) == (
        "user",
        "set-tier",
        USER,
        "premium",
    )
    for command in ("suspend", "unsuspend"):
        parsed = parser.parse_args(["user", command, str(USER), "--reason", "abuse report"])
        assert (parsed.user_command, parsed.user_id, parsed.reason) == (
            command,
            USER,
            "abuse report",
        )


@pytest.mark.parametrize(
    "argv",
    [
        ["user", "suspend", str(USER)],  # no reason
        ["user", "set-tier", str(USER), "premium"],  # no reason
        ["user", "set-tier", str(USER), "gold", "--reason", "x"],  # unknown tier
        ["user", "suspend", "not-a-uuid", "--reason", "x"],
        ["user"],
    ],
)
def test_the_command_line_refuses_an_incomplete_command(
    argv: list[str], capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(SystemExit) as stopped:
        _parser().parse_args(argv)
    assert stopped.value.code == 2
    capsys.readouterr()
