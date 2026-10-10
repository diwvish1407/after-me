"""Keyset cursors (API_SPEC §1)."""

from __future__ import annotations

import base64
import uuid
from datetime import UTC, datetime, timedelta, timezone

import pytest

from app.checkins.schemas import CheckinRequest
from app.core.pagination import InvalidCursorError, decode_cursor, encode_cursor

pytestmark = pytest.mark.no_db


def test_a_cursor_round_trips_to_the_microsecond() -> None:
    at = datetime(2026, 10, 8, 9, 0, 0, 123456, tzinfo=UTC)
    row_id = uuid.uuid4()
    assert decode_cursor(encode_cursor(at, row_id)) == (at, row_id)


def test_a_cursor_is_url_safe_and_unpadded() -> None:
    cursor = encode_cursor(datetime(2026, 10, 8, tzinfo=UTC), uuid.uuid4())
    assert "=" not in cursor
    assert all(c.isalnum() or c in "-_" for c in cursor)


def test_the_instant_is_normalised_to_utc() -> None:
    ist = timezone(timedelta(hours=5, minutes=30))
    at = datetime(2026, 10, 8, 14, 30, tzinfo=ist)
    row_id = uuid.uuid4()
    assert decode_cursor(encode_cursor(at, row_id)) == (at.astimezone(UTC), row_id)


def _encode(raw: str) -> str:
    return base64.urlsafe_b64encode(raw.encode()).rstrip(b"=").decode()


@pytest.mark.parametrize(
    "cursor",
    [
        "",
        "!!!",
        "not base64 at all",
        _encode("v2:0:" + str(uuid.uuid4())),  # a version this server never issued
        _encode("v1:abc:" + str(uuid.uuid4())),  # not a number
        _encode("v1:0:not-a-uuid"),
        _encode("v1:0"),
        _encode("v1:0:" + str(uuid.uuid4()) + ":extra"),
        _encode("v1:" + "9" * 40 + ":" + str(uuid.uuid4())),  # beyond the datetime range
        base64.urlsafe_b64encode(b"\xff\xfe").decode(),  # not UTF-8
    ],
)
def test_foreign_cursors_are_refused(cursor: str) -> None:
    with pytest.raises(InvalidCursorError):
        decode_cursor(cursor)


def test_the_client_time_accepts_an_aware_datetime_object() -> None:
    ist = timezone(timedelta(hours=5, minutes=30))
    request = CheckinRequest(client_reported_at=datetime(2026, 10, 8, 14, 31, tzinfo=ist))
    assert request.client_reported_at == datetime(2026, 10, 8, 9, 1, tzinfo=UTC)
