"""Turning an outbox row into a message (USER_FLOWS §13).

Rows hold identifiers and instants only. Names, addresses and times are resolved here, at send
time, so that an edit or an opt-out made after the row was queued is respected, and so that no
personal data ever sits in the outbox. Push text is **generic** (SECURITY T21, FR-NOT-04): the
app fetches the details over the API.
"""

from __future__ import annotations

from collections.abc import Sequence
from datetime import datetime
from typing import Final
from zoneinfo import ZoneInfo

from app.notifications import outbox
from app.notifications.push import (
    CHANNEL_ACCOUNT,
    CHANNEL_INCIDENTS,
    CHANNEL_REMINDERS,
    PushMessage,
)

_NOON: Final = 12

PUSH_COPY: Final[dict[str, tuple[str, str]]] = {
    outbox.USER_PRE_REMINDER: ("Check-in due soon", "Tap to let AfterMe know you're OK."),
    outbox.USER_MISSED: ("You missed your check-in", "Tap I'M OK to stop the reminders."),
    outbox.USER_MIDPOINT: ("Still waiting for your check-in", "Tap to check in."),
    outbox.USER_LAST_CHANCE: (
        "Your contacts will be notified in 15 minutes",
        "Tap to check in now.",
    ),
    outbox.USER_STAGE_DEFERRED: (
        "We gave you more time",
        "We had an interruption. Open AfterMe and check in.",
    ),
    outbox.USER_STAGE_EXECUTED: (
        "Your contacts have been notified",
        "If you're safe, open AfterMe and tap I'M SAFE.",
    ),
    outbox.USER_FINAL_WARNING: (
        "Information will be shared in 1 hour",
        "Tap I'M SAFE to stop it.",
    ),
    outbox.USER_ALL_CLEAR: ("All clear sent", "Your contacts know you're safe."),
    outbox.USER_HOLD_NOTICE: ("We had a service interruption", "Please check in."),
    # No name: a push shows on a locked screen (FR-NOT-04). The app says who.
    outbox.USER_CONTACT_UNREACHABLE: (
        "A contact could not be reached",
        "Open AfterMe to see who and what to do.",
    ),
}


_HOUR: Final = 3_600
# (channel, time to live in seconds) per push type.
PUSH_DELIVERY: Final[dict[str, tuple[str, int]]] = {
    outbox.USER_PRE_REMINDER: (CHANNEL_REMINDERS, _HOUR),
    outbox.USER_MISSED: (CHANNEL_REMINDERS, _HOUR),
    outbox.USER_MIDPOINT: (CHANNEL_REMINDERS, _HOUR),
    outbox.USER_LAST_CHANCE: (CHANNEL_REMINDERS, 15 * 60),  # true for 15 minutes
    outbox.USER_STAGE_DEFERRED: (CHANNEL_REMINDERS, 2 * _HOUR),
    outbox.USER_STAGE_EXECUTED: (CHANNEL_INCIDENTS, 24 * _HOUR),
    outbox.USER_FINAL_WARNING: (CHANNEL_INCIDENTS, _HOUR),
    outbox.USER_ALL_CLEAR: (CHANNEL_INCIDENTS, 24 * _HOUR),
    outbox.USER_HOLD_NOTICE: (CHANNEL_INCIDENTS, 24 * _HOUR),
    outbox.USER_CONTACT_UNREACHABLE: (CHANNEL_ACCOUNT, 24 * _HOUR),
}


def push_message(template_key: str, *, token: str, incident_id: str | None) -> PushMessage | None:
    copy = PUSH_COPY.get(template_key)
    if copy is None:
        return None
    channel, ttl = PUSH_DELIVERY.get(template_key, (CHANNEL_INCIDENTS, 24 * _HOUR))
    return PushMessage(
        token=token,
        type=template_key,
        title=copy[0],
        body=copy[1],
        incident_id=incident_id,
        channel=channel,
        ttl_seconds=ttl,
    )


def join_names(names: Sequence[str]) -> str:
    """``["Mom"]`` -> ``Mom``; two -> ``Mom and Dad``; three -> ``Mom, Dad and Sam``."""
    cleaned = [n for n in names if n]
    if not cleaned:
        return ""
    if len(cleaned) == 1:
        return cleaned[0]
    return f"{', '.join(cleaned[:-1])} and {cleaned[-1]}"


def _zone(timezone: str) -> ZoneInfo:
    try:
        return ZoneInfo(timezone)
    except (KeyError, ValueError):  # an unusable zone must not stop a message
        return ZoneInfo("UTC")


def clock_time(instant: datetime, timezone: str) -> str:
    """``8:00 PM``."""
    local = instant.astimezone(_zone(timezone))
    hour12 = local.hour % _NOON or _NOON
    return f"{hour12}:{local.minute:02d} {'AM' if local.hour < _NOON else 'PM'}"


def day_time(instant: datetime, timezone: str) -> str:
    """``Wednesday 15 Oct, 8:00 PM IST``: a contact must not have to guess the day or zone."""
    local = instant.astimezone(_zone(timezone))
    return (
        f"{local.strftime('%A')} {local.day} {local.strftime('%b')}, "
        f"{clock_time(instant, timezone)} {local.tzname() or ''}"
    ).strip()


def date_text(instant: datetime, timezone: str) -> str:
    """``14 Nov 2026``."""
    local = instant.astimezone(_zone(timezone))
    return f"{local.day} {local.strftime('%b')} {local.year}"


def duration_text(minutes: int) -> str:
    """How long a person had not checked in when something was shared: ``24 hours``,
    ``2 days``. Whole days from two days on; hours otherwise."""
    days, rest = divmod(minutes, 1440)
    if days >= 2 and rest == 0:  # noqa: PLR2004 - "2 days" and over read better in days
        return f"{days} days"
    hours = max(minutes // 60, 1)
    return f"{hours} hour{'s' if hours != 1 else ''}"
