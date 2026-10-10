"""Deadline computation (ESCALATION_ENGINE §3). Pure functions: no I/O, no clock.

The *baseline* is the server time of the last check-in, or of schedule activation or change.
The next deadline is ``interval_days`` calendar days later in the user's timezone, at the local
due time, but never less than :data:`MIN_WINDOW` after the baseline. Where a local wall time does
not exist (a DST gap) or occurs twice (an overlap), the **later** instant is used: the user gets
more time, never less.
"""

from __future__ import annotations

import re
from datetime import UTC, date, datetime, time, timedelta
from typing import Final
from zoneinfo import ZoneInfo

MIN_WINDOW: Final = timedelta(hours=12)

# Zones can skip a whole local day (Pacific/Apia, 2011-12-30), so the search may have to move on
# by a day or two; a bound turns an impossible infinite loop into a loud failure.
_MAX_DAYS_SEARCHED: Final = 8

_HHMM_RE: Final = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")


def parse_hhmm(value: str) -> time:
    """``"20:00"`` → ``time(20, 0)``. Raises ``ValueError`` for anything but 24 h ``HH:MM``."""
    match = _HHMM_RE.match(value)
    if match is None:
        msg = "expected a 24-hour HH:MM time"
        raise ValueError(msg)
    return time(int(match[1]), int(match[2]))


def format_hhmm(value: time) -> str:
    return f"{value.hour:02d}:{value.minute:02d}"


def resolve_local(day: date, at: time, tz: ZoneInfo) -> datetime:
    """Local wall time → UTC instant. In a DST gap or overlap, return the LATER instant."""
    naive = datetime.combine(day, at.replace(tzinfo=None))
    first = naive.replace(tzinfo=tz, fold=0).astimezone(UTC)
    second = naive.replace(tzinfo=tz, fold=1).astimezone(UTC)
    return max(first, second)


def compute_next_due(
    baseline: datetime, interval_days: int, due_local_time: time, tz: ZoneInfo
) -> datetime:
    """The first deadline at least :data:`MIN_WINDOW` after ``baseline`` that is on or after
    ``interval_days`` calendar days (in ``tz``) from the baseline's local date."""
    if baseline.tzinfo is None:
        msg = "baseline must be timezone-aware"
        raise ValueError(msg)
    day = baseline.astimezone(tz).date() + timedelta(days=interval_days)
    for _ in range(_MAX_DAYS_SEARCHED):
        candidate = resolve_local(day, due_local_time, tz)
        if candidate - baseline >= MIN_WINDOW:
            return candidate
        day += timedelta(days=1)
    msg = "no deadline found"  # pragma: no cover - unreachable for any real zone
    raise RuntimeError(msg)  # pragma: no cover
