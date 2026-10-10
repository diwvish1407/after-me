"""The clock abstraction (ARCHITECTURE §4.5).

All authoritative timestamps and expiry comparisons use a :class:`Clock`, never
``datetime.now()``. Production uses the database clock; tests drive a :class:`FrozenClock`.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Protocol

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession


class Clock(Protocol):
    async def now(self, session: AsyncSession) -> datetime:
        """Return the current instant (timezone-aware, UTC)."""
        ...


class DbClock:
    """PostgreSQL ``now()``: the start time of the current transaction.

    The value is constant within a transaction, so every comparison and timestamp written by one
    request agrees with every other one, and there is a single ordering of events across replicas.
    """

    async def now(self, session: AsyncSession) -> datetime:
        value = (await session.execute(text("SELECT now()"))).scalar_one()
        if not isinstance(value, datetime) or value.tzinfo is None:  # pragma: no cover
            msg = "database returned a naive timestamp"
            raise TypeError(msg)
        return value.astimezone(UTC)


class FrozenClock:
    """A clock that only moves when a test moves it."""

    def __init__(self, at: datetime) -> None:
        self._now = _require_aware(at)

    async def now(self, session: AsyncSession) -> datetime:
        return self._now

    @property
    def current(self) -> datetime:
        return self._now

    def set(self, at: datetime) -> None:
        self._now = _require_aware(at)

    def advance(self, delta: timedelta | None = None, /, **kwargs: float) -> datetime:
        self._now += delta if delta is not None else timedelta(**kwargs)
        return self._now


def _require_aware(value: datetime) -> datetime:
    if value.tzinfo is None:
        msg = "FrozenClock needs a timezone-aware datetime"
        raise ValueError(msg)
    return value.astimezone(UTC)
