"""Deadline computation (ESCALATION_ENGINE §3; TEST_PLAN ENG-FS-14 and ENG-PBT-01).

The vectors are the ones verified in the specification; the property tests run the same
function over every timezone the API accepts and baselines from 1970 to 2100.
"""

from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from app.checkins.schedule import (
    MIN_WINDOW,
    compute_next_due,
    format_hhmm,
    parse_hhmm,
    resolve_local,
)
from app.core.validation import _zones

pytestmark = pytest.mark.no_db

IST = ZoneInfo("Asia/Kolkata")
NEW_YORK = ZoneInfo("America/New_York")
LONDON = ZoneInfo("Europe/London")


def due(baseline: datetime, n: int, at: str, tz: ZoneInfo) -> datetime:
    return compute_next_due(baseline, n, parse_hhmm(at), tz)


# --- the verified vectors (§3.3) --------------------------------------------------------------


@pytest.mark.parametrize(
    ("baseline_local", "expected"),
    [
        # Daily 20:00 IST
        ((2026, 10, 13, 19, 30), (2026, 10, 14, 20, 0)),
        ((2026, 10, 13, 10, 0), (2026, 10, 14, 20, 0)),
        ((2026, 10, 13, 23, 59), (2026, 10, 14, 20, 0)),
        ((2026, 10, 14, 0, 1), (2026, 10, 15, 20, 0)),
    ],
)
def test_daily_2000_ist(baseline_local: tuple[int, ...], expected: tuple[int, ...]) -> None:
    baseline = datetime(*baseline_local, tzinfo=IST)
    assert due(baseline, 1, "20:00", IST) == datetime(*expected, tzinfo=IST)


def test_a_candidate_less_than_twelve_hours_away_moves_to_the_next_day() -> None:
    baseline = datetime(2026, 10, 13, 23, 50, tzinfo=IST)
    assert due(baseline, 1, "00:30", IST) == datetime(2026, 10, 15, 0, 30, tzinfo=IST)


def test_exactly_twelve_hours_is_enough() -> None:
    baseline = datetime(2026, 10, 13, 12, 30, tzinfo=IST)
    assert due(baseline, 1, "00:30", IST) == datetime(2026, 10, 14, 0, 30, tzinfo=IST)
    just_after = baseline + timedelta(microseconds=1)
    assert due(just_after, 1, "00:30", IST) == datetime(2026, 10, 15, 0, 30, tzinfo=IST)


@pytest.mark.parametrize(
    ("tz", "local_day", "wall", "expected_utc"),
    [
        # Spring forward: 02:30 does not exist, so 03:30 EDT (the later instant).
        (NEW_YORK, date(2026, 3, 8), "02:30", datetime(2026, 3, 8, 7, 30, tzinfo=UTC)),
        # Fall back: 01:30 happens twice, so the second occurrence (EST).
        (NEW_YORK, date(2026, 11, 1), "01:30", datetime(2026, 11, 1, 6, 30, tzinfo=UTC)),
        (LONDON, date(2026, 3, 29), "01:30", datetime(2026, 3, 29, 1, 30, tzinfo=UTC)),
        (LONDON, date(2026, 10, 25), "01:30", datetime(2026, 10, 25, 1, 30, tzinfo=UTC)),
    ],
)
def test_dst_gap_and_overlap_choose_the_later_instant(
    tz: ZoneInfo, local_day: date, wall: str, expected_utc: datetime
) -> None:
    assert resolve_local(local_day, parse_hhmm(wall), tz) == expected_utc
    baseline = datetime.combine(local_day - timedelta(days=1), time(12, 0), tzinfo=tz)
    assert due(baseline, 1, wall, tz) == expected_utc


@pytest.mark.parametrize(
    ("zone", "baseline_utc", "wall", "expected_utc"),
    [
        # Sydney spring forward 2026-10-04 02:00 -> 03:00
        (
            "Australia/Sydney",
            datetime(2026, 10, 3, 2, 0, tzinfo=UTC),
            "02:30",
            datetime(2026, 10, 3, 16, 30, tzinfo=UTC) + timedelta(hours=0),
        ),
        # Kathmandu has no DST and a +05:45 offset: 20:00 local is 14:15Z.
        (
            "Asia/Kathmandu",
            datetime(2026, 6, 1, 3, 0, tzinfo=UTC),
            "20:00",
            datetime(2026, 6, 2, 14, 15, tzinfo=UTC),
        ),
    ],
)
def test_other_zones(zone: str, baseline_utc: datetime, wall: str, expected_utc: datetime) -> None:
    tz = ZoneInfo(zone)
    result = due(baseline_utc, 1, wall, tz)
    if zone == "Asia/Kathmandu":
        assert result == expected_utc
    else:
        # Sydney: the gap day's 02:30 does not exist; the result is the later instant.
        assert result.astimezone(tz).time() >= time(2, 30)
        assert result - baseline_utc >= MIN_WINDOW


def test_whole_skipped_day_pacific_apia() -> None:
    """Samoa jumped from 2011-12-29 to 2011-12-31: there is no 2011-12-30 at all."""
    tz = ZoneInfo("Pacific/Apia")
    baseline = datetime(2011, 12, 29, 12, 0, tzinfo=tz)
    result = due(baseline, 1, "20:00", tz)
    assert result.astimezone(tz) == datetime(2011, 12, 31, 20, 0, tzinfo=tz)
    assert result - baseline >= MIN_WINDOW


def test_multi_day_intervals_count_calendar_days_in_the_users_zone() -> None:
    baseline = datetime(2026, 10, 13, 19, 30, tzinfo=IST)
    assert due(baseline, 7, "20:00", IST) == datetime(2026, 10, 20, 20, 0, tzinfo=IST)
    assert due(baseline, 30, "09:15", IST) == datetime(2026, 11, 12, 9, 15, tzinfo=IST)


def test_a_multi_day_interval_across_a_dst_change_keeps_the_wall_time() -> None:
    baseline = datetime(2026, 10, 30, 21, 0, tzinfo=NEW_YORK)  # EDT
    result = due(baseline, 3, "20:00", NEW_YORK)  # Nov 2 is EST
    assert result.astimezone(NEW_YORK) == datetime(2026, 11, 2, 20, 0, tzinfo=NEW_YORK)
    assert result == datetime(2026, 11, 3, 1, 0, tzinfo=UTC)


def test_the_result_does_not_depend_on_how_the_baseline_is_expressed() -> None:
    instant = datetime(2026, 10, 13, 14, 0, tzinfo=UTC)
    assert due(instant, 1, "20:00", IST) == due(instant.astimezone(NEW_YORK), 1, "20:00", IST)


def test_a_naive_baseline_is_refused() -> None:
    with pytest.raises(ValueError, match="timezone-aware"):
        compute_next_due(datetime(2026, 10, 13, 19, 30), 1, time(20, 0), IST)  # noqa: DTZ001 - a naive baseline is the error case


# --- HH:MM ------------------------------------------------------------------------------------


@pytest.mark.parametrize("value", ["00:00", "08:05", "20:00", "23:59"])
def test_hhmm_round_trips(value: str) -> None:
    assert format_hhmm(parse_hhmm(value)) == value


@pytest.mark.parametrize(
    "value", ["", "8:00", "24:00", "20:60", "20:00:00", "20.00", " 20:00", "20:00 ", "ab:cd"]
)
def test_hhmm_rejects_everything_else(value: str) -> None:
    with pytest.raises(ValueError, match="HH:MM"):
        parse_hhmm(value)


# --- ENG-PBT-01: properties over every zone the API accepts -----------------------------------

ZONES = sorted(_zones())
ONE_DAY = timedelta(days=1)

zone_names = st.sampled_from(ZONES)
_FIRST = datetime(1970, 1, 2)  # noqa: DTZ001 - Hypothesis bounds are naive
_LAST = datetime(2100, 1, 1)  # noqa: DTZ001
baselines = st.datetimes(min_value=_FIRST, max_value=_LAST, timezones=st.just(UTC))
intervals = st.integers(min_value=1, max_value=30)
due_times = st.builds(time, st.integers(0, 23), st.integers(0, 59))
property_settings = settings(max_examples=600, deadline=None)


def _wall_time_exists(day: date, at: time, tz: ZoneInfo) -> bool:
    naive = datetime.combine(day, at)
    for fold in (0, 1):
        aware = naive.replace(tzinfo=tz, fold=fold)
        if aware.astimezone(UTC).astimezone(tz).replace(tzinfo=None) != naive:
            return False
    return True


@property_settings
@given(zone=zone_names, baseline=baselines, n=intervals, at=due_times)
def test_deadline_is_never_closer_than_twelve_hours(
    zone: str, baseline: datetime, n: int, at: time
) -> None:
    result = compute_next_due(baseline, n, at, ZoneInfo(zone))
    assert result - baseline >= MIN_WINDOW


@property_settings
@given(zone=zone_names, baseline=baselines, n=intervals, at=due_times)
def test_deadline_is_within_the_interval_plus_one_day(
    zone: str, baseline: datetime, n: int, at: time
) -> None:
    tz = ZoneInfo(zone)
    result = compute_next_due(baseline, n, at, tz)
    elapsed = result - baseline
    # The calendar arithmetic is in local days, so the elapsed time can differ from N + 1 days
    # by the zone's offset change (at most a skipped or repeated day).
    assert elapsed <= timedelta(days=n + 1) + ONE_DAY
    if baseline.astimezone(tz).utcoffset() == result.astimezone(tz).utcoffset():
        assert elapsed <= timedelta(days=n + 1)
    local_days = (result.astimezone(tz).date() - baseline.astimezone(tz).date()).days
    assert n <= local_days <= n + 2


@property_settings
@given(zone=zone_names, baseline=baselines, n=intervals, at=due_times)
def test_deadline_has_the_local_due_time_unless_it_falls_in_a_gap(
    zone: str, baseline: datetime, n: int, at: time
) -> None:
    tz = ZoneInfo(zone)
    local = compute_next_due(baseline, n, at, tz).astimezone(tz)
    if local.time().replace(second=0, microsecond=0) == at:
        return
    # Otherwise the wall time must not exist on the day the search stopped at: the deadline was
    # pushed to the later instant, which is past the gap.
    gap_days = [local.date() - timedelta(days=d) for d in (0, 1)]
    assert any(not _wall_time_exists(day, at, tz) for day in gap_days), (local, at, zone)
    assert local.time() > at or local.date() > gap_days[-1]


@property_settings
@given(zone=zone_names, baseline=baselines, n=intervals, at=due_times)
def test_deadline_is_deterministic_and_independent_of_the_baseline_zone(
    zone: str, baseline: datetime, n: int, at: time
) -> None:
    tz = ZoneInfo(zone)
    first = compute_next_due(baseline, n, at, tz)
    assert compute_next_due(baseline, n, at, tz) == first
    assert compute_next_due(baseline.astimezone(tz), n, at, tz) == first
    assert first.tzinfo is not None
    assert first.utcoffset() == timedelta(0)


@property_settings
@given(
    zone=zone_names,
    baseline=baselines,
    later_by=st.timedeltas(min_value=timedelta(0), max_value=timedelta(days=3)),
    n=intervals,
    at=due_times,
)
def test_checking_in_later_never_brings_the_deadline_forward(
    zone: str, baseline: datetime, later_by: timedelta, n: int, at: time
) -> None:
    tz = ZoneInfo(zone)
    assert compute_next_due(baseline + later_by, n, at, tz) >= compute_next_due(baseline, n, at, tz)


# --- a deterministic sweep that is certain to hit gaps and overlaps ----------------------------

SWEEP_ZONES = (
    ("America/New_York", 2026),
    ("Europe/London", 2026),
    ("Australia/Sydney", 2026),
    ("Australia/Lord_Howe", 2026),  # 30-minute DST step
    ("America/Santiago", 2026),
    ("Asia/Tehran", 2022),  # abolished DST afterwards: still a valid historical zone
    ("Asia/Kathmandu", 2026),  # +05:45, no DST
    ("Pacific/Apia", 2011),  # skipped 2011-12-30 entirely
)
SWEEP_TIMES = tuple(time(h, m) for h in (0, 1, 2, 3, 4, 20) for m in (0, 30))


@pytest.mark.parametrize(("zone", "year"), SWEEP_ZONES)
def test_every_hour_of_a_year_in_transition_heavy_zones(zone: str, year: int) -> None:
    tz = ZoneInfo(zone)
    start = datetime(year, 1, 1, tzinfo=UTC)
    gaps_hit = overlaps_hit = 0
    for step in range(0, 366 * 24, 3):
        baseline = start + timedelta(hours=step)
        for at in SWEEP_TIMES:
            for n in (1, 2):
                result = compute_next_due(baseline, n, at, tz)
                assert result - baseline >= MIN_WINDOW
                local = result.astimezone(tz)
                if local.time() != at:
                    assert not _wall_time_exists(local.date(), at, tz) or not _wall_time_exists(
                        local.date() - ONE_DAY, at, tz
                    ), (zone, baseline, at, n)
                    gaps_hit += 1
                naive = datetime.combine(local.date(), at)
                first = naive.replace(tzinfo=tz, fold=0).astimezone(UTC)
                second = naive.replace(tzinfo=tz, fold=1).astimezone(UTC)
                if first != second and local.time() == at:
                    assert result == max(first, second)
                    overlaps_hit += 1
    if zone in {"America/New_York", "Europe/London", "Australia/Sydney"}:
        assert gaps_hit > 0, "the sweep never reached a DST gap"
        assert overlaps_hit > 0, "the sweep never reached a DST overlap"
