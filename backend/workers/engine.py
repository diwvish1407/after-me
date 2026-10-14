"""``python -m workers.engine``: the escalation worker process (ARCHITECTURE §6).

Runs the engine tick and the outbox dispatcher in a loop until it receives SIGTERM or SIGINT.
It connects as the ``afterme_worker`` database role. Several replicas are safe: every unit of
work takes the user's lock with ``SKIP LOCKED`` and every effect carries a dedupe key.
"""

from __future__ import annotations

import asyncio
import contextlib
import signal
import time
from collections.abc import Callable

from app.api.container import build_worker_services
from app.core.config import Settings, load_settings
from app.core.logging import configure_logging, get_logger
from app.engine.dispatcher import CONCURRENCY as DISPATCH_CONCURRENCY
from app.engine.dispatcher import Dispatcher, DispatchReport
from app.engine.runtime import UNIT_CONCURRENCY, Engine, TickReport
from app.notifications.providers.factory import build_push_provider

# One connection per unit of a tick page and per concurrent send of a dispatcher pass, plus 2:
# the page reader / Hold evaluation / stuck-row recovery session, and a failed unit's attempt
# count (or a stale connection being replaced). With less, a settle (tx B) after the provider
# accepted can wait out the pool timeout and leave the row ``sending``; it is then re-sent after
# 5 minutes (ESCALATION_ENGINE §8.3). Terraform sets the pool to exactly this (14 + 0).
MIN_POOL_CONNECTIONS = UNIT_CONCURRENCY + DISPATCH_CONCURRENCY + 2


def check_pool(settings: Settings) -> None:
    """Refuse to run the worker on a pool smaller than its own concurrency."""
    available = settings.db_pool_size + settings.db_max_overflow
    if available < MIN_POOL_CONNECTIONS:
        msg = (
            f"the worker's database pool (DB_POOL_SIZE + DB_MAX_OVERFLOW = {available}) is "
            f"smaller than its concurrency needs ({MIN_POOL_CONNECTIONS} = {UNIT_CONCURRENCY} "
            f"units + {DISPATCH_CONCURRENCY} sends + 2)"
        )
        raise RuntimeError(msg)


async def drain_outbox(
    dispatcher: Dispatcher,
    first: DispatchReport,
    *,
    contact_facing: bool,
    until: float,
    stopping: Callable[[], bool],
    clock: Callable[[], float] = time.monotonic,
) -> DispatchReport:
    """A full batch means more messages are waiting: send the next batch now instead of after
    the pause, until the next tick is due. A pass is the same pass as before (every message is
    re-checked, Hold included, as it is claimed) and the decision to send contact-facing
    messages is the one this tick made, so nothing goes out that the tick would have held; only
    the idle time between ticks is used. Without this the loop sent at most ``BATCH`` messages
    per tick period, 100 every 15 s, however many were queued (PERF-03)."""
    report = first
    while report.backlog and not stopping() and clock() < until:
        report = await dispatcher.dispatch(contact_facing=contact_facing)
    return report


async def run() -> None:
    settings = load_settings()
    configure_logging(settings)
    log = get_logger("afterme.worker")
    check_pool(settings)
    services = build_worker_services(settings)
    if settings.is_production_like:
        role = await services.db.current_role()
        if role != "afterme_worker":
            msg = f"the worker must connect as afterme_worker, not {role}"
            raise RuntimeError(msg)
    engine = Engine(services)
    dispatcher = Dispatcher(services, push=build_push_provider(settings))
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        with contextlib.suppress(NotImplementedError):  # not available on every platform
            loop.add_signal_handler(sig, stop.set)

    log.info("worker.started", instance=engine.instance_id, tick_seconds=settings.tick_seconds)
    try:
        while not stop.is_set():
            report: TickReport | None = None
            tick_started = time.monotonic()
            try:
                report = await engine.tick()
            except Exception as exc:  # the loop itself must survive a bad tick
                log.error("worker.tick_failed", error_class=type(exc).__name__)
            # Fail safe: if the tick did not complete, or could not tell whether a Hold is in
            # force, nothing contact-facing is sent this cycle (INV-4, INV-10).
            contact_facing = report is not None and not report.hold_unknown
            outbox_backlog = False
            try:
                first = await dispatcher.dispatch(contact_facing=contact_facing)
                last = await drain_outbox(
                    dispatcher,
                    first,
                    contact_facing=contact_facing,
                    until=tick_started + settings.tick_seconds,
                    stopping=stop.is_set,
                )
                outbox_backlog = last.backlog  # still more queued: the next tick is due
            except Exception as exc:
                log.error("worker.dispatch_failed", error_class=type(exc).__name__)
            # A full last page means more is waiting: go straight on rather than sleep.
            pause = (
                0.2
                if outbox_backlog or (report is not None and report.backlog)
                else settings.tick_seconds
            )
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(stop.wait(), timeout=pause)
    finally:
        await services.db.dispose()
        log.info("worker.stopped", instance=engine.instance_id)


def main() -> None:
    asyncio.run(run())


if __name__ == "__main__":
    main()
