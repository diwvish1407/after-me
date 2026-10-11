"""Retention (DATABASE §5): what the maintenance role removes, and what it leaves."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import timedelta

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import Database
from app.maintenance.retention import purge_all
from tests.support import OWNER_URL
from tests.world import World


@asynccontextmanager
async def _as_maintenance(world: World) -> AsyncIterator[AsyncSession]:
    db = Database.from_settings(world.h.settings, application_name="test-retention", url=OWNER_URL)
    try:
        async with db.independent_session() as session:
            try:
                await session.execute(text("SET LOCAL ROLE afterme_maintenance"))
            except DBAPIError:
                pytest.skip("run backend/scripts/dev_db_setup.sh to let the owner SET ROLE")
            yield session
    finally:
        await db.dispose()


async def test_the_job_purges_by_the_clock_it_is_given(world: World) -> None:
    person = await world.ready()
    owner = person.user_id
    world.db.execute(
        "INSERT INTO notifications (user_id, audience, category, channel, template_key, status, "
        "send_after, dedupe_key, created_at, updated_at) VALUES "
        "(%s, 'user', 'user', 'email', 'incident_missed', 'sent', %s, 'a', %s, %s), "
        "(%s, 'user', 'user', 'email', 'incident_missed', 'sent', %s, 'b', %s, %s), "
        "(%s, 'user', 'user', 'email', 'incident_missed', 'queued', %s, 'c', %s, %s)",
        (
            owner,
            world.clock.current,
            world.clock.current - timedelta(days=91),
            world.clock.current,
            owner,
            world.clock.current,
            world.clock.current - timedelta(days=89),
            world.clock.current,
            owner,
            world.clock.current,
            world.clock.current - timedelta(days=200),
            world.clock.current,
        ),
    )
    world.db.execute(
        "INSERT INTO notification_logs (notification_id, provider, outcome) "
        "SELECT id, 'resend', 'accepted' FROM notifications WHERE dedupe_key = 'a'"
    )
    async with _as_maintenance(world) as session:
        removed = await purge_all(session, now=world.clock.current)
    assert removed["notifications"] == 1
    keys = {
        r["dedupe_key"]
        for r in world.db.execute(
            "SELECT dedupe_key FROM notifications WHERE user_id = %s AND dedupe_key IN "
            "('a','b','c')",
            (owner,),
        ).fetchall()
    }
    assert keys == {"b", "c"}
    assert world.db.execute("SELECT count(*) AS n FROM notification_logs").fetchone() == {"n": 0}


async def test_probes_and_old_check_in_events_follow_their_own_periods(world: World) -> None:
    person = await world.ready()
    now = world.clock.current
    world.db.execute(
        "INSERT INTO ingestion_probes (received_at, source) VALUES (%s, 'x'), (%s, 'x')",
        (now - timedelta(days=31), now - timedelta(days=29)),
    )
    world.db.execute(
        "INSERT INTO checkin_events (user_id, kind, source, received_at, idempotency_key, "
        "response_snapshot) VALUES (%s, 'ok', 'app', %s, 'old-event-key-0000001', '{}'), "
        "(%s, 'ok', 'app', %s, 'new-event-key-0000002', '{}')",
        (person.user_id, now - timedelta(days=401), person.user_id, now - timedelta(days=399)),
    )
    async with _as_maintenance(world) as session:
        removed = await purge_all(session, now=now)
    assert removed["ingestion_probes"] == 1
    assert removed["checkin_events"] == 1
    keys = [
        r["idempotency_key"]
        for r in world.db.execute(
            "SELECT idempotency_key FROM checkin_events WHERE user_id = %s", (person.user_id,)
        ).fetchall()
    ]
    assert "old-event-key-0000001" not in keys
    assert "new-event-key-0000002" in keys


async def test_the_messages_of_an_open_incident_are_kept_however_old_they_are(
    world: World,
) -> None:
    """They are who must be told when the person returns (an incident stays open until then)."""
    person = await world.ready()
    await world.advance_to(world.clock.current + timedelta(days=2))  # an incident, stage run
    incident = world.open_incident(person)
    assert incident is not None
    alert = world.db.execute(
        "SELECT id FROM notifications WHERE user_id = %s AND template_key = 'contact_alert'",
        (person.user_id,),
    ).fetchone()
    assert alert is not None
    now = world.clock.current
    world.db.execute(
        "UPDATE notifications SET created_at = %s WHERE id = %s",
        (now - timedelta(days=500), alert["id"]),
    )
    async with _as_maintenance(world) as session:
        await purge_all(session, now=now)
    kept = world.db.execute(
        "SELECT status FROM notifications WHERE id = %s", (alert["id"],)
    ).fetchone()
    assert kept is not None  # still there: its incident is open
    assert kept["status"] == "sent"

    # once the incident is closed, it follows the ordinary period
    world.db.execute(
        "UPDATE escalation_incidents SET status = 'cancelled', closed_at = %s, "
        "closed_by = 'user_safe' WHERE id = %s",
        (now, incident["id"]),
    )
    async with _as_maintenance(world) as session:
        removed = await purge_all(session, now=now)
    assert removed["notifications"] >= 1
    assert (
        world.db.execute("SELECT 1 FROM notifications WHERE id = %s", (alert["id"],)).fetchone()
        is None
    )


async def test_old_receipts_of_direct_mail_are_purged(world: World) -> None:
    person = await world.ready()
    now = world.clock.current
    world.db.execute(
        "INSERT INTO email_receipts (user_id, contact_id, template_key, provider, "
        "provider_message_id, sent_at) VALUES (%s, %s, 'contact_invitation', 'resend', 'old', %s), "
        "(%s, %s, 'contact_invitation', 'resend', 'new', %s)",
        (
            person.user_id,
            person.contacts["Mom"],
            now - timedelta(days=91),
            person.user_id,
            person.contacts["Mom"],
            now - timedelta(days=10),
        ),
    )
    async with _as_maintenance(world) as session:
        removed = await purge_all(session, now=now)
    assert removed["email_receipts"] == 1
    left = {
        r["provider_message_id"]
        for r in world.db.execute("SELECT provider_message_id FROM email_receipts").fetchall()
    }
    assert "old" not in left
    assert "new" in left
    assert len(left) >= 2  # the invitation the contact really received is remembered too
