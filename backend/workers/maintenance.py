"""``python -m workers.maintenance``: the retention job (DATABASE §5).

Finishes account deletions: scrubs contacts whose all-clear has left and hard-deletes accounts
whose retention period is over. It connects as ``afterme_maintenance``. Without ``--every`` it
runs once and exits (for a scheduler); with ``--every SECONDS`` it loops until SIGTERM.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import signal

from app.audit.writer import AuditWriter
from app.core.clock import Clock, DbClock
from app.core.config import load_settings
from app.core.db import Database
from app.core.logging import configure_logging, get_logger
from app.maintenance.accounts import purge_due_accounts, scrub_settled_contacts
from app.maintenance.retention import purge_all
from app.testsupport.clock import OffsetDbClock

BATCH = 50


async def run(every: int | None) -> None:
    settings = load_settings()
    configure_logging(settings)
    log = get_logger("afterme.maintenance")
    # Not the API's container: this job needs a database connection, a clock and the audit
    # writer, and nothing else (no keys, no mailer).
    db = Database.from_settings(
        settings,
        application_name="afterme-maintenance",
        url=settings.maintenance_database_url.get_secret_value(),
    )
    clock: Clock = OffsetDbClock() if settings.test_support_enabled else DbClock()
    audit_writer = AuditWriter(db)
    if settings.is_production_like:
        role = await db.current_role()
        if role != "afterme_maintenance":
            msg = f"the maintenance job must connect as afterme_maintenance, not {role}"
            raise RuntimeError(msg)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, stop.set)
    try:
        while not stop.is_set():
            try:
                scrubbed, purged = await _once(
                    db,
                    clock,
                    audit_writer,
                    settings.account_deletion_days,
                    settings.audit_retention_days,
                )
                log.info("maintenance.done", contacts_scrubbed=scrubbed, accounts_purged=purged)
            except Exception as exc:  # the loop itself must survive one bad run
                log.error("maintenance.failed", error_class=type(exc).__name__)
                if every is None:
                    raise
            if every is None:
                return
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(stop.wait(), timeout=every)
    finally:
        await db.dispose()


async def _once(
    db: Database,
    clock: Clock,
    writer: AuditWriter,
    retention_days: int,
    audit_retention_days: int = 365,
) -> tuple[int, int]:
    """One pass. Every step is its own transaction (``independent_session`` commits on exit)."""
    log = get_logger("afterme.maintenance")
    purged = 0
    async with db.independent_session() as session:
        now = await clock.now(session)
        scrubbed = await scrub_settled_contacts(session, now=now)
    async with db.independent_session() as session:
        now = await clock.now(session)
        retained = await purge_all(session, now=now, audit_retention_days=audit_retention_days)
    # (not as keyword arguments: "refresh_tokens" would be redacted by name, count and all)
    log.info(
        "maintenance.retention",
        removed=[f"{name}={count}" for name, count in retained.items()],
        total=sum(retained.values()),
    )
    while True:
        async with db.independent_session() as session:
            now = await clock.now(session)
            removed = await purge_due_accounts(
                session,
                writer,
                now=now,
                retention_days=retention_days,
                batch=BATCH,
            )
        purged += len(removed)
        if len(removed) < BATCH:
            return scrubbed, purged


def main() -> None:
    parser = argparse.ArgumentParser(description="AfterMe retention and deletion job")
    parser.add_argument("--every", type=int, default=None, help="loop every N seconds")
    args = parser.parse_args()
    asyncio.run(run(args.every))


if __name__ == "__main__":
    main()
