"""Pure functions the game-day scenarios assert with.

No I/O and no import of the application, so ``tests/unit/test_gameday_checks.py`` can pin their
behaviour without a database or a process.
"""

from __future__ import annotations

import json
import re
from collections import Counter
from collections.abc import Callable, Iterable, Mapping, Sequence
from datetime import datetime, timedelta
from typing import Any, Final

DATABASE_NAME_RE: Final = re.compile(r"^afterme_gameday[a-z0-9_]{0,30}$")
# Every database a person may be working in. The harness never touches these, whatever it is
# asked: it drops and recreates the database it works in.
PROTECTED_DATABASES: Final = frozenset(
    {"afterme_dev", "afterme_test", "afterme_it", "postgres", "template0", "template1"}
)
_MAIL_HEADER_RE: Final = re.compile(r"^(To|Subject|X-Template): (.*)$")


def valid_database_name(name: str) -> bool:
    """``afterme_gameday`` and its suffixed variants only, never a protected name."""
    return bool(DATABASE_NAME_RE.fullmatch(name)) and name not in PROTECTED_DATABASES


def extract_json(text: str, key: str = "pages") -> dict[str, Any] | None:
    """The last JSON object in ``text`` that has ``key``.

    The operator CLI prints its answer as indented JSON after any log lines (which are one-line
    JSON objects of their own), so the answer is found by key, not by position.
    """
    decoder = json.JSONDecoder()
    found: dict[str, Any] | None = None
    for index, char in enumerate(text):
        if char != "{" or (index and text[index - 1] != "\n"):
            continue
        try:
            value, _ = decoder.raw_decode(text, index)
        except ValueError:
            continue
        if isinstance(value, dict) and key in value:
            found = value
    return found


def scrub(text: str, secrets: Iterable[str]) -> str:
    """``text`` with every secret replaced, for anything printed or kept."""
    for secret in secrets:
        if secret:
            text = text.replace(secret, "<secret>")
    return text


def expected_shift(started_at: datetime, ended_at: datetime, buffer_minutes: int) -> timedelta:
    """What a Hold's exit adds to every pending stage (ESCALATION_ENGINE §7.3 step 2): the
    length of the window plus the recovery buffer."""
    return (ended_at - started_at) + timedelta(minutes=buffer_minutes)


def seconds_between(earlier: datetime, later: datetime) -> float:
    return (later - earlier).total_seconds()


def close_to(a: datetime, b: datetime, tolerance_seconds: float) -> bool:
    return abs((a - b).total_seconds()) <= tolerance_seconds


def minutes_text(seconds: float) -> str:
    return f"{seconds / 60:.1f} min"


def duplicates(keys: Iterable[str]) -> list[str]:
    """The keys that occur more than once (a dedupe key must never)."""
    return sorted(k for k, n in Counter(keys).items() if n > 1)


def count_mismatches(
    sent: Mapping[tuple[str, str], int], mailed: Mapping[tuple[str, str], int]
) -> list[str]:
    """Where the outbox and the recording of mails disagree about (recipient, template).

    ``sent`` counts outbox rows in status ``sent``; ``mailed`` counts what the provider wrote.
    More mails than rows is a duplicate send; fewer is a message marked sent that never left.
    """
    problems: list[str] = []
    for key in sorted(set(sent) | set(mailed)):
        if sent.get(key, 0) != mailed.get(key, 0):
            recipient, template = key
            problems.append(
                f"{template} to {recipient}: outbox says {sent.get(key, 0)}, "
                f"mail recording says {mailed.get(key, 0)}"
            )
    return problems


def pick_port(start: int, is_free: Callable[[int], bool], *, limit: int = 100) -> int:
    """The first free port from ``start``; ``RuntimeError`` when none of ``limit`` is."""
    for port in range(start, start + limit):
        if is_free(port):
            return port
    msg = f"no free port in {start}..{start + limit - 1}"
    raise RuntimeError(msg)


def parse_mail_file(text: str) -> dict[str, str] | None:
    """A message of the console email provider (headers, a blank line, the body); the same
    shape ``GET /test/mail`` reads. ``None`` when it is not one."""
    head, _, body = text.partition("\n\n")
    fields: dict[str, str] = {}
    for line in head.splitlines():
        found = _MAIL_HEADER_RE.match(line)
        if found:
            fields[found[1]] = found[2]
    if "To" not in fields:
        return None
    return {
        "to": fields["To"].strip().lower(),
        "template": fields.get("X-Template", ""),
        "subject": fields.get("Subject", ""),
        "text": body,
    }


def status_excerpt(document: Mapping[str, Any] | None) -> dict[str, Any]:
    """The part of ``python -m cli.admin status`` / ``hold status`` the runbook is pasted from."""
    if document is None:
        return {}
    keys = (
        "hold_active",
        "hold_reasons",
        "hold_exit_pending",
        "worker_heartbeat_age_seconds",
        "oldest_due_action_age_seconds",
        "oldest_queued_message_age_seconds",
        "held_actions",
        "failed_messages_7d",
        "incidents_open",
        "provider_attempts_15m",
        "provider_errors_15m",
        "fallback_sends_15m",
        "pages",
        "warnings",
    )
    return {k: document[k] for k in keys if k in document}


def format_excerpt(excerpt: Mapping[str, Any]) -> list[str]:
    """One ``name: value`` line per key, ages rounded, for the operator blocks."""
    lines: list[str] = []
    for key, value in excerpt.items():
        shown = round(value) if isinstance(value, float) else value
        lines.append(f"{key}: {json.dumps(shown)}")
    return lines


# --------------------------------------------------------------------------------------------
# what the harness may touch
# --------------------------------------------------------------------------------------------

LOOPBACK_HOSTS: Final = frozenset({"localhost", "127.0.0.1", "::1"})


def is_loopback_host(host: str) -> bool:
    """The only database hosts the harness will run ``DROP DATABASE`` against."""
    return host.strip().lower() in LOOPBACK_HOSTS


def process_matches(recorded: Mapping[str, str], observed: Mapping[str, str]) -> bool:
    """Whether the process now at a PID is the one that was recorded: the start time **and**
    the full command line must be present in the record and equal. A reused PID differs in at
    least one of them."""
    start, command = recorded.get("start"), recorded.get("command")
    return (
        bool(start)
        and bool(command)
        and (observed.get("start") == start and observed.get("command") == command)
    )


# --------------------------------------------------------------------------------------------
# assertions that must be able to fail
# --------------------------------------------------------------------------------------------


def held_back(
    due: Sequence[Mapping[str, Any]], mails: int, messaged_at: object, *, hold_open: bool
) -> list[str]:
    """Why "a contact message was held back by the Hold" is *not* demonstrated (empty = it is).

    ``due`` are the contact messages whose ``send_after`` has passed (with a margin for the
    dispatcher's pass): the claim is only about messages that would have been sent but for the
    Hold, so with none due it proves nothing and is a problem of its own.
    """
    problems: list[str] = []
    if not hold_open:
        problems.append("no Hold is open")
    if not due:
        problems.append("no message is past its send_after: nothing was tested")
    problems.extend(f"a due message is {row['status']}" for row in due if row["status"] != "queued")
    if mails:
        problems.append(f"{mails} contact mails were written")
    if messaged_at is not None:
        problems.append("the incident says contacts were messaged")
    return problems


def count_differences(
    actual: Mapping[tuple[str, str], int], expected: Mapping[tuple[str, str], int]
) -> list[str]:
    """Every (recipient, template) whose count is not the expected one, in both directions."""
    problems: list[str] = []
    for key in sorted(set(actual) | set(expected)):
        if actual.get(key, 0) != expected.get(key, 0):
            recipient, template = key
            problems.append(
                f"{template} to {recipient}: expected {expected.get(key, 0)}, "
                f"got {actual.get(key, 0)}"
            )
    return problems


def reconcile_outbox(
    sent: Sequence[tuple[str, str, str]],
    files: Sequence[tuple[str, str, str]],
    outbox_templates: Iterable[str],
    *,
    minimum: int,
) -> list[str]:
    """Outbox rows in status ``sent`` against the mails the provider wrote, joined by the
    provider's own message id (the console provider's id is the file name).

    ``sent`` and ``files`` are ``(message id, template, recipient)``. Problems: fewer rows than
    ``minimum`` (a vacuous pass), one id recorded by two rows (one send, two rows, or the other
    way round), a row whose mail does not exist or went to another recipient or template, and a
    mail of an outbox template that no row accounts for (a message sent behind the outbox's
    back, or twice).
    """
    problems: list[str] = []
    if len(sent) < minimum:
        problems.append(f"only {len(sent)} sent rows; at least {minimum} expected")
    by_id = Counter(message_id for message_id, _, _ in sent)
    problems.extend(
        f"message id {i} recorded by {n} rows" for i, n in sorted(by_id.items()) if n > 1
    )
    written = {name: (template, to) for name, template, to in files}
    for message_id, template, recipient in sent:
        if message_id not in written:
            problems.append(f"{template} to {recipient}: marked sent, no mail was written")
        elif written[message_id] != (template, recipient.lower()):
            problems.append(
                f"{template} to {recipient}: the mail {message_id} is {written[message_id]}"
            )
    templates = set(outbox_templates)
    problems.extend(
        f"{template} to {to}: a mail no outbox row accounts for"
        for name, (template, to) in sorted(written.items())
        if template in templates and name not in by_id
    )
    return problems


def not_before_full_grace(
    sent_at: datetime, anchor_at: datetime, *, grace_minutes: int, settle_seconds: int
) -> bool:
    """An alert may leave no earlier than the anchor plus the grace period plus the settle
    delay (INV-8)."""
    return sent_at >= anchor_at + timedelta(minutes=grace_minutes, seconds=settle_seconds)
