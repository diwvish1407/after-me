"""Test fixtures: a real PostgreSQL database, the app under test, a frozen clock.

* The test database (``AFTERME_TEST_DB_NAME``, default ``afterme_test``) is created with the
  ``afterme_owner`` role when missing and migrated once per session with Alembic.
* The application connects as ``afterme_api``, so a missing GRANT fails the tests.
* Isolation: every test starts from empty tables (TRUNCATE as the owner). Per-test rollback is not
  an option because some bookkeeping commits on independent connections.
"""

from __future__ import annotations

import os

# Tests must not depend on the developer's shell or backend/.env.
_KEEP = {
    "AFTERME_TEST_DB_NAME",
    "AFTERME_DEV_DB_NAME",
    "AFTERME_TEST_PG_HOST",
    "AFTERME_TEST_PG_PORT",
    "AFTERME_OWNER_DB_PASSWORD",
    "AFTERME_API_DB_PASSWORD",
    "AFTERME_WORKER_DB_PASSWORD",
    "AFTERME_UPDATE_CONTRACTS",
}
for _name in list(os.environ):
    if _name.startswith("AFTERME_") and _name not in _KEEP:
        del os.environ[_name]
os.environ["AFTERME_APP_ENV"] = "test"

from collections.abc import AsyncIterator, Iterator  # noqa: E402
from typing import Any  # noqa: E402

import httpx  # noqa: E402
import psycopg  # noqa: E402
import pytest  # noqa: E402
from alembic import command  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from psycopg import sql  # noqa: E402

from app.core.clock import FrozenClock  # noqa: E402
from app.core.config import Settings  # noqa: E402
from app.instructions.models import CATEGORY_SEED  # noqa: E402
from app.main import create_app  # noqa: E402
from app.models import ALL_TABLES  # noqa: E402
from app.notifications.email import RecordingEmailProvider  # noqa: E402
from tests.routes import test_router  # noqa: E402
from tests.support import (  # noqa: E402
    CLIENT_IP,
    OWNER_URL,
    T0,
    TEST_DB,
    Harness,
    alembic_config,
    connect,
    ensure_database,
    make_settings,
)
from tests.world import World, build_world  # noqa: E402


@pytest.fixture(scope="session")
def migrated_database() -> str:
    ensure_database(TEST_DB)
    command.upgrade(alembic_config(OWNER_URL), "head")
    return TEST_DB


@pytest.fixture(scope="session")
def owner_db(migrated_database: str) -> Iterator[psycopg.Connection[dict[str, Any]]]:
    with connect(database=migrated_database) as conn:
        # Fail loudly instead of hanging if a test leaks a connection holding locks.
        conn.execute("SET lock_timeout = '15s'")
        yield conn


@pytest.fixture(autouse=True)
def _clean_tables(request: pytest.FixtureRequest) -> None:
    if "no_db" in request.keywords:
        return
    owner: psycopg.Connection[dict[str, Any]] = request.getfixturevalue("owner_db")
    # ``instruction_categories`` is reference data seeded by the migration: it stays.
    cleared = [t for t in ALL_TABLES if t != "instruction_categories"]
    owner.execute(
        sql.SQL("TRUNCATE {} RESTART IDENTITY CASCADE").format(
            sql.SQL(", ").join(sql.Identifier(t) for t in cleared)
        )
    )
    # ... and is put back if an earlier run (or a test that truncates everything) lost it.
    for category_id, sort_order in CATEGORY_SEED:
        owner.execute(
            "INSERT INTO instruction_categories (id, sort_order) VALUES (%s, %s) "
            "ON CONFLICT (id) DO NOTHING",
            (category_id, sort_order),
        )


@pytest.fixture
def clock() -> FrozenClock:
    return FrozenClock(T0)


@pytest.fixture
def mail() -> RecordingEmailProvider:
    return RecordingEmailProvider()


@pytest.fixture
def settings(request: pytest.FixtureRequest) -> Settings:
    overrides: dict[str, Any] = {}
    if request.node.get_closest_marker("no_rate_limit"):
        overrides["rate_limit_enabled"] = False
    marker = request.node.get_closest_marker("settings")
    if marker is not None:
        overrides.update(marker.kwargs)
    return make_settings(**overrides)


@pytest.fixture
async def app(
    settings: Settings, clock: FrozenClock, mail: RecordingEmailProvider, owner_db: Any
) -> AsyncIterator[FastAPI]:
    application = create_app(settings, clock=clock, email_provider=mail)
    application.include_router(test_router)
    application.state.owner_db = owner_db  # tests only: lets factories prepare state
    yield application
    await application.state.services.db.dispose()


@pytest.fixture
async def client(app: FastAPI) -> AsyncIterator[httpx.AsyncClient]:
    transport = httpx.ASGITransport(app=app, client=(CLIENT_IP, 51000))
    async with httpx.AsyncClient(transport=transport, base_url="https://api.afterme.test") as c:
        yield c


@pytest.fixture
def h(
    app: FastAPI,
    client: httpx.AsyncClient,
    mail: RecordingEmailProvider,
    clock: FrozenClock,
    settings: Settings,
) -> Harness:
    return Harness(app=app, client=client, mail=mail, clock=clock, settings=settings)


@pytest.fixture
async def world(h: Harness, owner_db: Any) -> AsyncIterator[World]:
    """The API, the engine (as the worker role) and the clock, driven together."""
    w = build_world(h, owner_db)
    yield w
    await w.dispose()


def pytest_configure(config: pytest.Config) -> None:
    config.addinivalue_line("markers", "settings(**overrides): override test settings")
    config.addinivalue_line("markers", "no_db: the test does not touch the database")
