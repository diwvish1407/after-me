"""Retention (DATABASE §5): what the maintenance role removes, and what it leaves."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import timedelta

import pytest
from pydantic import ValidationError
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import Database
from app.maintenance.retention import audit_rule, purge_all
from tests.support import OWNER_URL, make_settings
from tests.world import Person, World, ist

DUE = ist("2026-10-09T20:00")


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


# --- sessions, tokens, devices, the audit log (Phase 10 review, D-1 / D-3) --------------------


def _ids(world: World, query: str, *params: object) -> set[str]:
    return {str(next(iter(r.values()))) for r in world.db.execute(query, params).fetchall()}


def _make_sessions(world: World, person: Person, count: int) -> list[str]:
    """``count`` login sessions of ``person`` (a signup is one), oldest first."""
    return [
        str(r["id"])
        for r in world.db.execute(
            "SELECT id FROM sessions WHERE user_id = %s ORDER BY created_at, id", (person.user_id,)
        ).fetchall()
    ][:count]


async def _more_sessions(world: World, person: Person, total: int) -> list[str]:
    while len(_make_sessions(world, person, 99)) < total:
        await world.h.relogin(person.email)
    return _make_sessions(world, person, total)


def _refresh(world: World, session_id: str, *, expires: object, used: object = None) -> str:
    row = world.db.execute(
        "INSERT INTO refresh_tokens (session_id, token_hash, expires_at, used_at) "
        "VALUES (%s, uuid_send(gen_random_uuid()), %s, %s) RETURNING id",
        (session_id, expires, used),
    ).fetchone()
    assert row is not None
    return str(row["id"])


async def test_sessions_and_their_tokens_go_30_days_after_they_ended(world: World) -> None:
    person = await world.person()
    now = world.clock.current
    revoked_long, revoked_recent, expired_long, live = await _more_sessions(world, person, 4)
    day = timedelta(days=1)
    world.db.execute(
        "UPDATE sessions SET revoked_at = %s, revoke_reason = 'logout' WHERE id = %s",
        (now - 31 * day, revoked_long),
    )
    world.db.execute(
        "UPDATE sessions SET revoked_at = %s, revoke_reason = 'logout' WHERE id = %s",
        (now - 29 * day, revoked_recent),
    )
    world.db.execute(
        "UPDATE sessions SET idle_expires_at = %s, absolute_expires_at = %s WHERE id = %s",
        (now - 31 * day, now + 200 * day, expired_long),
    )
    world.db.execute(
        "UPDATE sessions SET idle_expires_at = %s, absolute_expires_at = %s WHERE id = %s",
        (now + 10 * day, now + 300 * day, live),
    )
    # a check-in made on a session that is about to go keeps its row, without the session
    world.db.execute(
        "INSERT INTO checkin_events (user_id, kind, source, received_at, idempotency_key, "
        "session_id, response_snapshot) VALUES (%s, 'ok', 'app', %s, 'kept-event-key-000001', "
        "%s, '{}')",
        (person.user_id, now - day, revoked_long),
    )
    # the live session's tokens: one rotated out long ago, one unused and past its expiry
    old_used = _refresh(world, live, expires=now + day, used=now - 31 * day)
    unused_old = _refresh(world, live, expires=now - 40 * day)
    current = _refresh(world, live, expires=now + 5 * day)
    recent_used = _refresh(world, live, expires=now + day, used=now - 5 * day)

    async with _as_maintenance(world) as session:
        removed = await purge_all(session, now=now)

    left = _ids(world, "SELECT id FROM sessions WHERE user_id = %s", person.user_id)
    assert left == {revoked_recent, live}  # the live one is never touched
    assert removed["sessions"] == 2
    tokens = _ids(world, "SELECT id FROM refresh_tokens WHERE session_id = %s", live)
    assert old_used not in tokens  # rotated out 31 days ago
    assert {unused_old, current, recent_used} <= tokens  # the live session's own tokens stay
    assert removed["refresh_tokens"] == 1
    # the tokens of the sessions that went with them (cascade), none of them left over
    assert world.db.execute(
        "SELECT count(*) AS n FROM refresh_tokens WHERE session_id = ANY(%s)",
        ([revoked_long, expired_long],),
    ).fetchone() == {"n": 0}
    event = world.db.execute(
        "SELECT session_id FROM checkin_events WHERE idempotency_key = 'kept-event-key-000001'"
    ).fetchone()
    assert event == {"session_id": None}


async def test_one_time_tokens_go_30_days_after_use_or_expiry(world: World) -> None:
    person = await world.person()
    other = await world.person("closing@example.com")
    now = world.clock.current
    day = timedelta(days=1)
    world.db.execute(
        "UPDATE users SET status = 'pending_deletion', deletion_requested_at = %s WHERE id = %s",
        (now - 100 * day, other.user_id),
    )
    rows = {
        "used_long": (person.user_id, now + day, now - 31 * day),
        "expired_long": (person.user_id, now - 31 * day, None),
        "expired_recent": (person.user_id, now - 29 * day, None),
        "used_recent": (person.user_id, now + day, now - 29 * day),
        "valid": (person.user_id, now + day, None),
        "closing_account": (other.user_id, now - 100 * day, None),  # goes with its account
    }
    ids: dict[str, str] = {}
    for name, (owner, expires, used) in rows.items():
        row = world.db.execute(
            "INSERT INTO auth_tokens (user_id, purpose, kind, secret_hash, expires_at, used_at) "
            "VALUES (%s, 'password_reset', 'code', uuid_send(gen_random_uuid()), %s, %s) "
            "RETURNING id",
            (owner, expires, used),
        ).fetchone()
        assert row is not None
        ids[name] = str(row["id"])
    async with _as_maintenance(world) as session:
        removed = await purge_all(session, now=now)
    left = _ids(world, "SELECT id FROM auth_tokens")
    assert {n for n, i in ids.items() if i in left} == {
        "expired_recent",
        "used_recent",
        "valid",
        "closing_account",
    }
    assert removed["auth_tokens"] == 2


async def test_a_closing_accounts_sessions_wait_for_the_account_to_go(world: World) -> None:
    person = await world.person()
    now = world.clock.current
    (session_id,) = await _more_sessions(world, person, 1)
    token = _refresh(world, session_id, expires=now - 40 * timedelta(days=1))
    world.db.execute(
        "UPDATE sessions SET revoked_at = %s, revoke_reason = 'account_deleted' WHERE id = %s",
        (now - 100 * timedelta(days=1), session_id),
    )
    world.db.execute(
        "UPDATE users SET status = 'pending_deletion', deletion_requested_at = %s WHERE id = %s",
        (now - 10 * timedelta(days=1), person.user_id),
    )
    async with _as_maintenance(world) as session:
        removed = await purge_all(session, now=now)
    assert removed["sessions"] == 0
    assert removed["refresh_tokens"] == 0
    assert token in _ids(world, "SELECT id FROM refresh_tokens")


def _device(world: World, person: Person, seen: object) -> str:
    row = world.db.execute(
        "INSERT INTO devices (user_id, platform, last_seen_at) VALUES (%s, 'android', %s) "
        "RETURNING id",
        (person.user_id, seen),
    ).fetchone()
    assert row is not None
    return str(row["id"])


async def test_devices_go_after_90_days_unseen_unless_something_still_uses_them(
    world: World,
) -> None:
    quiet = await world.person()
    watched = await world.ready("watched@example.com")
    (live_session,) = await _more_sessions(world, quiet, 1)
    # its owner has an open incident: the push reminders of that incident go to it
    await world.advance_to(DUE + timedelta(minutes=30))
    assert world.open_incident(watched) is not None
    now = world.clock.current
    day = timedelta(days=1)
    world.db.execute("DELETE FROM devices WHERE user_id = %s", (quiet.user_id,))
    unused = _device(world, quiet, now - 91 * day)
    recent = _device(world, quiet, now - 89 * day)
    used = _device(world, quiet, now - 200 * day)
    world.db.execute(
        "UPDATE sessions SET device_id = %s, revoked_at = NULL, idle_expires_at = %s, "
        "absolute_expires_at = %s WHERE id = %s",
        (used, now + 5 * day, now + 100 * day, live_session),
    )
    kept_for_incident = _device(world, watched, now - 200 * day)

    async with _as_maintenance(world) as session:
        removed = await purge_all(session, now=now)
    left = _ids(world, "SELECT id FROM devices")
    assert unused not in left
    assert {recent, used, kept_for_incident} <= left
    assert removed["devices"] >= 1


async def _audit_row(
    world: World,
    when: object,
    action: str,
    *,
    subject: str | None = None,
    resource_type: str | None = None,
    resource_id: str | None = None,
) -> str:
    row = world.db.execute(
        "INSERT INTO audit_logs (occurred_at, actor_type, subject_user_id, action, "
        "resource_type, resource_id) VALUES (%s, 'system', %s, %s, %s, %s) RETURNING id",
        (when, subject, action, resource_type, resource_id),
    ).fetchone()
    assert row is not None
    return str(row["id"])


async def test_audit_records_go_after_the_configured_period(world: World) -> None:
    person = await world.ready()
    closing = await world.person("closing@example.com")
    now = world.clock.current
    day = timedelta(days=1)
    await world.advance_to(DUE + timedelta(minutes=30))
    incident = world.open_incident(person)
    assert incident is not None
    now = world.clock.current
    world.db.execute(
        "UPDATE users SET status = 'pending_deletion', deletion_requested_at = %s WHERE id = %s",
        (now - day, closing.user_id),
    )
    old = await _audit_row(world, now - 366 * day, "profile.updated", subject=person.user_id)
    system = await _audit_row(world, now - 400 * day, "system.hold_entered")
    recent = await _audit_row(world, now - 364 * day, "profile.updated", subject=person.user_id)
    of_open_incident = await _audit_row(
        world,
        now - 500 * day,
        "incident.opened",
        subject=person.user_id,
        resource_type="incident",
        resource_id=str(incident["id"]),
    )
    of_closing_account = await _audit_row(
        world, now - 500 * day, "account.deletion_requested", subject=closing.user_id
    )
    async with _as_maintenance(world) as session:
        removed = await purge_all(session, now=now)  # the default: 365 days
    left = _ids(world, "SELECT id FROM audit_logs")
    assert {old, system}.isdisjoint(left)
    assert {recent, of_open_incident, of_closing_account} <= left
    assert removed["audit_logs"] >= 2

    # a shorter period, as a setting: 90 days at the least
    async with _as_maintenance(world) as session:
        await purge_all(session, now=now, audit_retention_days=90)
    left = _ids(world, "SELECT id FROM audit_logs")
    assert recent not in left
    assert {of_open_incident, of_closing_account} <= left  # still needed by someone

    world.db.execute(
        "UPDATE escalation_incidents SET status = 'cancelled', closed_at = %s, "
        "closed_by = 'user_safe' WHERE id = %s",
        (now, incident["id"]),
    )
    async with _as_maintenance(world) as session:
        await purge_all(session, now=now, audit_retention_days=90)
    left = _ids(world, "SELECT id FROM audit_logs")
    assert of_open_incident not in left  # closed: it follows the ordinary period
    assert of_closing_account in left  # the account is still closing


@pytest.mark.no_db
def test_the_audit_period_is_a_setting_that_cannot_go_below_90_days() -> None:
    assert make_settings().audit_retention_days == 365
    assert make_settings(audit_retention_days=90).audit_retention_days == 90
    with pytest.raises(ValidationError):
        make_settings(audit_retention_days=89)
    with pytest.raises(ValueError, match="at least 90"):
        audit_rule(89)
