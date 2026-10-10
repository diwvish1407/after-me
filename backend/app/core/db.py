"""Database engine, sessions and the declarative base.

Transactions: one :class:`AsyncSession` per request. Services commit explicitly before a success
response; request teardown only rolls back and closes. Bookkeeping that must survive an error
response (rate-limit counters, failed-login counters, code attempts, failure audit records) uses
:meth:`Database.independent_session`, a separate connection and transaction.

To avoid self-deadlocks, an independent transaction must never touch rows that the request
transaction has already locked or written; services order their work accordingly.

Bookkeeping connections come from their own small pool. A request holds one connection from the
main pool while it waits for its bookkeeping connection, so sharing a pool would let enough
concurrent requests starve each other (each holding one connection, all waiting for a second).
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import DateTime, MetaData, text
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase

from app.core.config import Settings

NAMING_CONVENTION: dict[str, str] = {
    "ix": "ix_%(table_name)s_%(column_0_N_name)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_N_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}

TIMESTAMPTZ = DateTime(timezone=True)


def in_list(column: str, values: tuple[str, ...]) -> str:
    """SQL text for a CHECK constraint restricting ``column`` to ``values`` (single source of truth
    shared by the tuple that the application code uses and the constraint)."""
    return f"{column} IN ({', '.join(repr(v) for v in values)})"


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING_CONVENTION)
    type_annotation_map = {datetime: TIMESTAMPTZ}  # noqa: RUF012 - SQLAlchemy class attribute


@dataclass(frozen=True)
class Database:
    engine: AsyncEngine
    sessionmaker: async_sessionmaker[AsyncSession]
    bookkeeping_engine: AsyncEngine
    bookkeeping_sessionmaker: async_sessionmaker[AsyncSession]

    @classmethod
    def from_settings(
        cls,
        settings: Settings,
        *,
        application_name: str = "afterme-api",
        url: str | None = None,
    ) -> Database:
        """``url`` overrides ``settings.database_url``: the worker process connects as its own,
        differently privileged role (DATABASE §6)."""
        options = " ".join(
            (
                f"-c statement_timeout={settings.db_statement_timeout_ms}",
                f"-c lock_timeout={settings.api_lock_timeout_ms}",
                "-c TimeZone=UTC",
            )
        )

        def make_engine(pool_size: int, max_overflow: int) -> AsyncEngine:
            return create_async_engine(
                url or settings.database_url.get_secret_value(),
                pool_size=pool_size,
                max_overflow=max_overflow,
                pool_pre_ping=True,
                hide_parameters=True,  # driver errors must not echo bound values into logs
                connect_args={"options": options, "application_name": application_name},
            )

        engine = make_engine(settings.db_pool_size, settings.db_max_overflow)
        # Bookkeeping transactions are short and never nest, so each one needs a connection only
        # briefly; size the pool so every request connection can have one waiting.
        bookkeeping_engine = make_engine(settings.db_pool_size, settings.db_max_overflow)
        return cls(
            engine=engine,
            sessionmaker=async_sessionmaker(engine, expire_on_commit=False, autoflush=True),
            bookkeeping_engine=bookkeeping_engine,
            bookkeeping_sessionmaker=async_sessionmaker(
                bookkeeping_engine, expire_on_commit=False, autoflush=True
            ),
        )

    @asynccontextmanager
    async def independent_session(self) -> AsyncIterator[AsyncSession]:
        """A separate connection and transaction that commits on success, whatever the request
        transaction does afterwards."""
        async with self.bookkeeping_sessionmaker() as session, session.begin():
            yield session

    async def current_role(self) -> str:
        """The database role this process is connected as."""
        async with self.sessionmaker() as session:
            return str((await session.execute(text("SELECT current_user"))).scalar_one())

    async def dispose(self) -> None:
        await self.engine.dispose()
        await self.bookkeeping_engine.dispose()
