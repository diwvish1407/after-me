"""The database clock plus an offset kept in ``system_flags`` (test environments only)."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Final

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

OFFSET_KEY: Final = "test_clock_offset_seconds"
MAX_STEP_SECONDS: Final = 400 * 24 * 3600  # one step never moves more than 400 days

_NOW_SQL = text(
    "SELECT now() + COALESCE((SELECT (value #>> '{}')::bigint FROM system_flags WHERE key = :key),"
    " 0) * interval '1 second'"
)
_OFFSET_SQL = text(
    "SELECT COALESCE((SELECT (value #>> '{}')::bigint FROM system_flags WHERE key = :key), 0)"
)
_ADVANCE_SQL = text(
    """
    INSERT INTO system_flags (key, value, updated_by)
    VALUES (:key, to_jsonb(CAST(:seconds AS bigint)), 'test-clock')
    ON CONFLICT (key) DO UPDATE
       SET value = to_jsonb((system_flags.value #>> '{}')::bigint + CAST(:seconds AS bigint)),
           updated_at = now(), updated_by = 'test-clock'
    """
)
_RESET_SQL = text(
    """
    INSERT INTO system_flags (key, value, updated_by)
    VALUES (:key, to_jsonb(CAST(0 AS bigint)), 'test-clock')
    ON CONFLICT (key) DO UPDATE SET value = to_jsonb(CAST(0 AS bigint)),
       updated_at = now(), updated_by = 'test-clock'
    """
)


class OffsetDbClock:
    """PostgreSQL ``now()`` plus the offset. Constant within a transaction, like ``DbClock``."""

    async def now(self, session: AsyncSession) -> datetime:
        value = (await session.execute(_NOW_SQL, {"key": OFFSET_KEY})).scalar_one()
        if not isinstance(value, datetime) or value.tzinfo is None:  # pragma: no cover
            msg = "database returned a naive timestamp"
            raise TypeError(msg)
        return value.astimezone(UTC)


async def offset_seconds(session: AsyncSession) -> int:
    return int((await session.execute(_OFFSET_SQL, {"key": OFFSET_KEY})).scalar_one())


async def advance(session: AsyncSession, seconds: int) -> None:
    await session.execute(_ADVANCE_SQL, {"key": OFFSET_KEY, "seconds": seconds})


async def reset(session: AsyncSession) -> None:
    await session.execute(_RESET_SQL, {"key": OFFSET_KEY})
