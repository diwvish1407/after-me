"""The worker's loop drains a backlog of messages between ticks (PERF-03)."""

from __future__ import annotations

from typing import Any

import pytest

from app.engine.dispatcher import DispatchReport
from workers.engine import drain_outbox

pytestmark = pytest.mark.no_db


class FakeDispatcher:
    def __init__(self, full_passes: int) -> None:
        self.full_passes = full_passes
        self.calls: list[bool] = []

    async def dispatch(self, *, contact_facing: bool = True) -> DispatchReport:
        self.calls.append(contact_facing)
        self.full_passes -= 1
        return DispatchReport(backlog=self.full_passes > 0)


async def test_a_full_batch_is_followed_by_another_until_the_queue_is_short() -> None:
    dispatcher = FakeDispatcher(full_passes=3)
    first = DispatchReport(backlog=True)
    last = await drain_outbox(
        dispatcher,  # type: ignore[arg-type]
        first,
        contact_facing=True,
        until=100.0,
        stopping=lambda: False,
        clock=lambda: 0.0,
    )
    assert len(dispatcher.calls) == 3
    assert last.backlog is False


async def test_the_decision_of_the_tick_is_passed_on() -> None:
    dispatcher = FakeDispatcher(full_passes=2)
    await drain_outbox(
        dispatcher,  # type: ignore[arg-type]
        DispatchReport(backlog=True),
        contact_facing=False,
        until=100.0,
        stopping=lambda: False,
        clock=lambda: 0.0,
    )
    assert dispatcher.calls == [False, False]


async def test_it_stops_when_the_next_tick_is_due() -> None:
    dispatcher = FakeDispatcher(full_passes=1000)
    times = iter([0.0, 1.0, 2.0, 99.0, 100.0, 101.0])
    last = await drain_outbox(
        dispatcher,  # type: ignore[arg-type]
        DispatchReport(backlog=True),
        contact_facing=True,
        until=100.0,
        stopping=lambda: False,
        clock=lambda: next(times),
    )
    assert len(dispatcher.calls) == 4  # 0, 1, 2 and 99 are before the deadline
    assert last.backlog is True


async def test_it_stops_on_shutdown_and_does_nothing_without_a_backlog() -> None:
    dispatcher = FakeDispatcher(full_passes=1000)
    kwargs: dict[str, Any] = {"contact_facing": True, "until": 100.0, "clock": lambda: 0.0}
    await drain_outbox(
        dispatcher,  # type: ignore[arg-type]
        DispatchReport(backlog=True),
        stopping=lambda: True,
        **kwargs,
    )
    await drain_outbox(
        dispatcher,  # type: ignore[arg-type]
        DispatchReport(backlog=False),
        stopping=lambda: False,
        **kwargs,
    )
    assert dispatcher.calls == []
