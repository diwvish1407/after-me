"""``python -m workers.engine``: the escalation worker process (ARCHITECTURE §6).

Runs the engine tick and the outbox dispatcher in a loop until it receives SIGTERM or SIGINT.
It connects as the ``afterme_worker`` database role. Several replicas are safe: every unit of
work takes the user's lock with ``SKIP LOCKED`` and every effect carries a dedupe key.
"""

from __future__ import annotations

import asyncio
import contextlib
import signal

from app.api.container import build_worker_services
from app.core.config import load_settings
from app.core.logging import configure_logging, get_logger
from app.engine.dispatcher import Dispatcher
from app.engine.runtime import Engine, TickReport
from app.notifications.providers.factory import build_push_provider


async def run() -> None:
    settings = load_settings()
    configure_logging(settings)
    log = get_logger("afterme.worker")
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
            try:
                report = await engine.tick()
            except Exception as exc:  # the loop itself must survive a bad tick
                log.error("worker.tick_failed", error_class=type(exc).__name__)
            # Fail safe: if the tick did not complete, or could not tell whether a Hold is in
            # force, nothing contact-facing is sent this cycle (INV-4, INV-10).
            contact_facing = report is not None and not report.hold_unknown
            try:
                await dispatcher.dispatch(contact_facing=contact_facing)
            except Exception as exc:
                log.error("worker.dispatch_failed", error_class=type(exc).__name__)
            # A full last page means more is waiting: go straight on rather than sleep.
            pause = 0.2 if report is not None and report.backlog else settings.tick_seconds
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(stop.wait(), timeout=pause)
    finally:
        await services.db.dispose()
        log.info("worker.stopped", instance=engine.instance_id)


def main() -> None:
    asyncio.run(run())


if __name__ == "__main__":
    main()
