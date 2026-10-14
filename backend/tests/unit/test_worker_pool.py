"""E-3: the worker's database pool must cover every unit of a tick page and every concurrent send
of a dispatcher pass, or a settle (tx B) after the provider accepted can wait out the pool
timeout, leave the row ``sending`` and have it re-sent after 5 minutes. The worker refuses to
start with a smaller pool (Terraform sets 14 + 0: infra/terraform/modules/run)."""

from __future__ import annotations

from typing import Any

import pytest

import workers.engine as worker
from app.engine.dispatcher import CONCURRENCY
from app.engine.runtime import UNIT_CONCURRENCY
from tests.support import make_settings

pytestmark = pytest.mark.no_db


def test_the_minimum_is_units_plus_sends_plus_two() -> None:
    assert worker.MIN_POOL_CONNECTIONS == UNIT_CONCURRENCY + CONCURRENCY + 2 == 14


@pytest.mark.parametrize(("pool", "overflow"), [(2, 1), (13, 0), (10, 3)])
def test_a_smaller_pool_is_refused(pool: int, overflow: int) -> None:
    with pytest.raises(RuntimeError, match="pool"):
        worker.check_pool(make_settings(db_pool_size=pool, db_max_overflow=overflow))


@pytest.mark.parametrize(("pool", "overflow"), [(14, 0), (10, 5), (20, 0)])
def test_a_pool_that_covers_the_concurrency_is_accepted(pool: int, overflow: int) -> None:
    worker.check_pool(make_settings(db_pool_size=pool, db_max_overflow=overflow))


async def test_the_worker_refuses_before_it_connects(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        worker, "load_settings", lambda: make_settings(db_pool_size=2, db_max_overflow=1)
    )

    def must_not_connect(*args: Any, **kwargs: Any) -> Any:
        raise AssertionError("the worker connected with a pool that is too small")

    monkeypatch.setattr(worker, "build_worker_services", must_not_connect)
    with pytest.raises(RuntimeError, match="pool"):
        await worker.run()
