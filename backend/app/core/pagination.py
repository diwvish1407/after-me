"""Keyset pagination for time-ordered lists (API_SPEC §1).

A cursor is an opaque URL-safe string that names the last row of the previous page by its
``(timestamp, id)``. It is not signed: every query is scoped to the caller, so a forged cursor
can only move within the caller's own rows.
"""

from __future__ import annotations

import base64
import binascii
import uuid
from datetime import UTC, datetime, timedelta
from typing import Final

LIMIT_DEFAULT: Final = 20
LIMIT_MAX: Final = 100

_EPOCH: Final = datetime(1970, 1, 1, tzinfo=UTC)
_VERSION: Final = "v1"


class InvalidCursorError(ValueError):
    """The cursor was not produced by :func:`encode_cursor`."""


def encode_cursor(at: datetime, row_id: uuid.UUID) -> str:
    micros = (at.astimezone(UTC) - _EPOCH) // timedelta(microseconds=1)
    raw = f"{_VERSION}:{micros}:{row_id}".encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def decode_cursor(value: str) -> tuple[datetime, uuid.UUID]:
    try:
        padded = value + "=" * (-len(value) % 4)
        version, micros, row_id = base64.urlsafe_b64decode(padded).decode().split(":")
        if version != _VERSION:
            raise InvalidCursorError
        return _EPOCH + timedelta(microseconds=int(micros)), uuid.UUID(row_id)
    except (ValueError, UnicodeDecodeError, binascii.Error, OverflowError) as exc:
        raise InvalidCursorError from exc


def encode_seq_cursor(at: datetime, seq: int) -> str:
    """Like :func:`encode_cursor` for tables ordered by a numeric identity (the audit log)."""
    micros = (at.astimezone(UTC) - _EPOCH) // timedelta(microseconds=1)
    raw = f"s1:{micros}:{seq}".encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def decode_seq_cursor(value: str) -> tuple[datetime, int]:
    try:
        padded = value + "=" * (-len(value) % 4)
        version, micros, seq = base64.urlsafe_b64decode(padded).decode().split(":")
        if version != "s1":
            raise InvalidCursorError
        number = int(seq)
        if number < 0:
            raise InvalidCursorError
        return _EPOCH + timedelta(microseconds=int(micros)), number
    except (ValueError, UnicodeDecodeError, binascii.Error, OverflowError) as exc:
        raise InvalidCursorError from exc
