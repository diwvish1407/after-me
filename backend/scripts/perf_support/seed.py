"""Bulk seeding of the performance database, in SQL, as the owner role.

Nothing here goes through the API: 100,000 sign-ups would take hours. Every id is derived from
the user's number (``md5('perf-user-' || i)::uuid``), so one table can be joined to another
without a temporary table, and the harness can compute any id in Python (``user_id(i)``).

What one ordinary user has, as in production: a verified, active account, a profile, a wrapped
key, an app session with its refresh token, a device with a push token, one verified contact, a
one-stage plan, an active schedule whose next deadline is somewhere in the next 24 hours, 20
check-ins of history with their audit records, and some delivered reminders. A small share has
older, expired sessions and one-time codes, and a past (resolved) incident. The first accounts
are in the states Home has to render: an incident in its grace period, and an escalated one.
"""

from __future__ import annotations

import hashlib
import json
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import psycopg

from perf_support import BACKEND_DIR  # noqa: F401 - puts backend/ on sys.path

from app.engine.timeline import materialise  # isort: skip
from app.incidents.snapshot import (  # isort: skip
    SnapshotStage,
    build_snapshot,
    parse_snapshot,
)

CHECKINS_PER_USER = 20
NOTIFICATIONS_PER_USER = 5
CHUNK = 20_000
TIMEZONES = (
    "Asia/Kolkata",
    "Asia/Kolkata",
    "Asia/Kolkata",
    "Europe/London",
    "America/New_York",
    "America/Los_Angeles",
    "Asia/Singapore",
    "Australia/Sydney",
    "Europe/Berlin",
    "Asia/Dubai",
)
GRACE_MINUTES = 180
STAGE_OFFSET_MINUTES = 180


def _uuid(kind: str, i: int) -> uuid.UUID:
    return uuid.UUID(hashlib.md5(f"perf-{kind}-{i}".encode(), usedforsecurity=False).hexdigest())


def user_id(i: int) -> uuid.UUID:
    return _uuid("user", i)


def session_id(i: int) -> uuid.UUID:
    return _uuid("session", i)


def device_id(i: int) -> uuid.UUID:
    return _uuid("device", i)


def contact_id(i: int) -> uuid.UUID:
    return _uuid("contact", i)


def plan_id(i: int) -> uuid.UUID:
    return _uuid("plan", i)


def step_id(i: int) -> uuid.UUID:
    return _uuid("step", i)


@dataclass(frozen=True)
class Layout:
    """Which user numbers are which (1-based, ``users`` in all)."""

    users: int
    states: int  # accounts per special state

    @classmethod
    def for_users(cls, users: int) -> Layout:
        return cls(users=users, states=max(5, min(200, users // 50)))

    @property
    def grace(self) -> range:
        return range(1, self.states + 1)

    @property
    def escalated(self) -> range:
        return range(self.states + 1, 2 * self.states + 1)

    @property
    def first_plain(self) -> int:
        return 2 * self.states + 1

    def plain(self, count: int, *, from_top: bool = False) -> range:
        """``count`` ordinary accounts: from the bottom of the plain range, or the top of it."""
        count = min(count, self.users - self.first_plain + 1)
        if from_top:
            return range(self.users - count + 1, self.users + 1)
        return range(self.first_plain, self.first_plain + count)


Say = Callable[[str], None]


def _sql(text: str) -> str:
    """Fill the @TOKENS@ of a statement. Literal percent signs are written ``%%`` in the text
    (the statements run with parameters, and psycopg turns the pair back into one)."""
    tz = "ARRAY[" + ",".join(f"'{name}'" for name in TIMEZONES) + "]"
    return (
        text.replace("%(lo)s", "%(lo)s::int")
        .replace("%(hi)s", "%(hi)s::int")
        .replace("@TZ@", tz)
        .replace("@GRACE@", str(GRACE_MINUTES))
        .replace("@OFFSET@", str(STAGE_OFFSET_MINUTES))
        .replace("@K@", str(CHECKINS_PER_USER - 1))
        .replace("@J@", str(NOTIFICATIONS_PER_USER))
    )


def _run(conn: psycopg.Connection[Any], sql: str, params: dict[str, Any] | None = None) -> int:
    cur = conn.execute(_sql(sql), params or {})  # type: ignore[arg-type]
    return cur.rowcount


def _timed(say: Say, label: str, fn: Callable[[], int]) -> None:
    started = time.monotonic()
    rows = fn()
    say(f"    {label:<32} {rows:>10,} rows  {time.monotonic() - started:6.1f} s")


def seed(conninfo: str, users: int, say: Say) -> Layout:
    """Fill an empty, migrated database. Returns the layout (who is in which state)."""
    layout = Layout.for_users(users)
    with psycopg.connect(conninfo, autocommit=True) as conn:
        conn.execute("SET synchronous_commit = off")  # a throwaway database
        conn.execute("SET maintenance_work_mem = '256MB'")
        # The categories are reference data of the migrations; everything else starts empty.
        _populate(conn, layout, say)
        started = time.monotonic()
        # VACUUM too: hint bits set and the visibility map built, so that autovacuum does not
        # start in the middle of a measurement and the first reads are not slower than later ones.
        conn.execute("VACUUM (ANALYZE)")
        say(f"    {'VACUUM ANALYZE':<32} {'':>10}       {time.monotonic() - started:6.1f} s")
    return layout


def _populate(conn: psycopg.Connection[Any], layout: Layout, say: Say) -> None:
    n = layout.users
    chunks = [(lo, min(lo + CHUNK - 1, n)) for lo in range(1, n + 1, CHUNK)]

    def chunked(label: str, sql: str) -> None:
        def go() -> int:
            return sum(_run(conn, sql, {"lo": lo, "hi": hi}) for lo, hi in chunks)

        _timed(say, label, go)

    chunked(
        "users",
        """
        INSERT INTO users (id, email, email_normalized, email_verified_at, password_hash, status,
                           tier, last_login_at, created_at, updated_at)
        SELECT md5('perf-user-' || i)::uuid, 'perf' || i || '@example.test',
               'perf' || i || '@example.test', now() - interval '30 days',
               '$argon2id$v=19$m=1024,t=1,p=1$c2VlZHNlZWQ$c2VlZHNlZWRzZWVkc2VlZHNlZWRzZWVkc2VlZA',
               'active', CASE WHEN i %% 10 = 0 THEN 'premium' ELSE 'free' END,
               now() - interval '1 hour', now() - interval '40 days', now()
          FROM generate_series(%(lo)s, %(hi)s) i
        """,
    )
    chunked(
        "user_profiles",
        """
        INSERT INTO user_profiles (user_id, display_name, timezone, locale)
        SELECT md5('perf-user-' || i)::uuid, 'Perf User ' || i,
               (@TZ@)[1 + i %% 10], 'en'
          FROM generate_series(%(lo)s, %(hi)s) i
        """,
    )
    chunked(
        "user_keys",
        """
        INSERT INTO user_keys (user_id, wrapped_dek, kek_id)
        SELECT md5('perf-user-' || i)::uuid, decode(md5('dek-' || i) || md5('dek2-' || i), 'hex'),
               'local-1'
          FROM generate_series(%(lo)s, %(hi)s) i
        """,
    )
    chunked(
        "devices",
        """
        INSERT INTO devices (id, user_id, platform, push_token, push_token_updated_at,
                             app_version, os_version, locale, created_at, last_seen_at)
        SELECT md5('perf-device-' || i)::uuid, md5('perf-user-' || i)::uuid, 'android',
               'fcm:' || md5('push-' || i) || md5('push2-' || i), now() - interval '20 days',
               '1.0.0+1', '14', 'en', now() - interval '30 days', now()
          FROM generate_series(%(lo)s, %(hi)s) i
        """,
    )
    chunked(
        "sessions (live)",
        """
        INSERT INTO sessions (id, user_id, kind, device_id, auth_method, created_at,
                              last_used_at, idle_expires_at, absolute_expires_at, ip_hash,
                              user_agent)
        SELECT md5('perf-session-' || i)::uuid, md5('perf-user-' || i)::uuid, 'app',
               md5('perf-device-' || i)::uuid, 'password', now() - interval '5 days',
               now() - (i %% 240) * interval '1 second', now() + interval '30 days',
               now() + interval '90 days', decode(md5('ip-' || i), 'hex'), 'AfterMe/1.0 (Android)'
          FROM generate_series(%(lo)s, %(hi)s) i
        """,
    )
    chunked(
        "refresh_tokens (live)",
        """
        INSERT INTO refresh_tokens (id, session_id, token_hash, issued_at, expires_at)
        SELECT md5('perf-refresh-' || i)::uuid, md5('perf-session-' || i)::uuid,
               decode(md5('rt-' || i) || md5('rt2-' || i), 'hex'), now() - interval '5 days',
               now() + interval '30 days'
          FROM generate_series(%(lo)s, %(hi)s) i
        """,
    )
    chunked(
        "sessions (old, revoked)",
        """
        INSERT INTO sessions (id, user_id, kind, device_id, auth_method, created_at,
                              last_used_at, idle_expires_at, absolute_expires_at, revoked_at,
                              revoke_reason, ip_hash, user_agent)
        SELECT md5('perf-oldsession-' || i)::uuid, md5('perf-user-' || i)::uuid, 'app', NULL,
               'password', now() - interval '120 days', now() - interval '70 days',
               now() - interval '60 days', now() + interval '1 day',
               now() - (45 + i %% 60) * interval '1 day', 'logout',
               decode(md5('oldip-' || i), 'hex'), 'AfterMe/0.9 (Android)'
          FROM generate_series(%(lo)s, %(hi)s) i
         WHERE i %% 4 = 0
        """,
    )
    chunked(
        "refresh_tokens (old)",
        """
        INSERT INTO refresh_tokens (id, session_id, token_hash, issued_at, expires_at, used_at)
        SELECT md5('perf-oldrefresh-' || i)::uuid, md5('perf-oldsession-' || i)::uuid,
               decode(md5('ort-' || i) || md5('ort2-' || i), 'hex'),
               now() - interval '120 days', now() - interval '60 days',
               now() - interval '70 days'
          FROM generate_series(%(lo)s, %(hi)s) i
         WHERE i %% 4 = 0
        """,
    )
    chunked(
        "auth_tokens (used codes)",
        """
        INSERT INTO auth_tokens (id, user_id, purpose, kind, secret_hash, attempts, expires_at,
                                 used_at, created_at)
        SELECT md5('perf-authtoken-' || i)::uuid, md5('perf-user-' || i)::uuid,
               'signup_verify', 'code', decode(md5('code-' || i) || md5('code2-' || i), 'hex'),
               1, now() - (39 + i %% 40) * interval '1 day',
               now() - (40 + i %% 40) * interval '1 day', now() - interval '41 days'
          FROM generate_series(%(lo)s, %(hi)s) i
        """,
    )
    chunked(
        "trusted_contacts",
        """
        INSERT INTO trusted_contacts (id, user_id, display_name, relationship, email,
                                      email_normalized, priority, verification_status,
                                      verified_at, status_changed_at, is_active,
                                      invitation_sent_at, invitation_send_count, created_at,
                                      updated_at)
        SELECT md5('perf-contact-' || i)::uuid, md5('perf-user-' || i)::uuid, 'Mom', 'mother',
               'mom' || i || '@example.test', 'mom' || i || '@example.test', 100, 'verified',
               now() - interval '29 days', now() - interval '29 days', true,
               now() - interval '30 days', 1, now() - interval '30 days', now()
          FROM generate_series(%(lo)s, %(hi)s) i
        """,
    )
    chunked(
        "escalation_plans",
        """
        INSERT INTO escalation_plans (id, user_id, grace_minutes, version, created_at, updated_at)
        SELECT md5('perf-plan-' || i)::uuid, md5('perf-user-' || i)::uuid, @GRACE@, 1,
               now() - interval '30 days', now() - interval '30 days'
          FROM generate_series(%(lo)s, %(hi)s) i
        """,
    )
    chunked(
        "escalation_steps",
        """
        INSERT INTO escalation_steps (id, plan_id, user_id, position, offset_minutes)
        SELECT md5('perf-step-' || i)::uuid, md5('perf-plan-' || i)::uuid,
               md5('perf-user-' || i)::uuid, 1, @OFFSET@
          FROM generate_series(%(lo)s, %(hi)s) i
        """,
    )
    chunked(
        "escalation_step_contacts",
        """
        INSERT INTO escalation_step_contacts (step_id, contact_id, user_id)
        SELECT md5('perf-step-' || i)::uuid, md5('perf-contact-' || i)::uuid,
               md5('perf-user-' || i)::uuid
          FROM generate_series(%(lo)s, %(hi)s) i
        """,
    )
    # The next deadline is spread over the next 24 hours (whole minutes); the baseline is one
    # day earlier, the last check-in is the baseline, and the local due time is derived from it.
    chunked(
        "checkin_configurations",
        """
        INSERT INTO checkin_configurations (user_id, interval_days, due_local_time,
                                            reminder_lead_minutes, status, baseline_at,
                                            last_checkin_at, next_due_at, activated_at, version,
                                            created_at, updated_at)
        SELECT uid, 1, (nd AT TIME ZONE tz)::time,
               (ARRAY[60,60,60,60,60,60,60,30,30,120,0,0,0,240,60])[1 + i %% 15], 'active',
               nd - interval '1 day', nd - interval '1 day', nd, now() - interval '30 days', 1,
               now() - interval '30 days', now()
          FROM (
            SELECT i, md5('perf-user-' || i)::uuid AS uid,
                   (@TZ@)[1 + i %% 10] AS tz,
                   date_trunc('minute', now() + (900 + (i::bigint * 7919) %% 85200)
                                                * interval '1 second') AS nd
              FROM generate_series(%(lo)s, %(hi)s) i
          ) q
        """,
    )
    chunked(
        "checkin_events (history)",
        """
        INSERT INTO checkin_events (id, user_id, kind, source, received_at, idempotency_key,
                                    session_id, device_id, response_snapshot, created_at)
        SELECT md5('perf-event-' || i || '-' || k)::uuid, c.user_id, 'ok', 'app', ts,
               'seed-' || md5(i || '/' || k), md5('perf-session-' || i)::uuid,
               md5('perf-device-' || i)::uuid,
               jsonb_build_object(
                 'checkin', jsonb_build_object('id', md5('perf-event-' || i || '-' || k),
                                               'kind', 'ok', 'received_at', ts),
                 'next_due_at', ts + interval '1 day', 'incident_resolved', false,
                 'server_time', ts),
               ts
          FROM generate_series(%(lo)s, %(hi)s) i
          JOIN checkin_configurations c ON c.user_id = md5('perf-user-' || i)::uuid
         CROSS JOIN generate_series(0, @K@) k
         CROSS JOIN LATERAL (
               SELECT c.last_checkin_at - k * interval '1 day'
                      - CASE WHEN k = 0 THEN interval '0'
                             ELSE ((i * 13 + k * 7) %% 3600) * interval '1 second' END AS ts) t
        """,
    )
    chunked(
        "audit_logs (check-ins)",
        """
        INSERT INTO audit_logs (occurred_at, actor_type, actor_id, subject_user_id, action,
                                resource_type, resource_id, request_id, ip_hash, user_visible,
                                metadata)
        SELECT e.received_at, 'user', e.user_id, e.user_id, 'checkin.recorded', 'checkin', e.id,
               'seed', decode(md5('ip-' || i), 'hex'), true, '{}'
          FROM generate_series(%(lo)s, %(hi)s) i
          JOIN checkin_events e ON e.user_id = md5('perf-user-' || i)::uuid
        """,
    )
    chunked(
        "audit_logs (setup)",
        """
        INSERT INTO audit_logs (occurred_at, actor_type, actor_id, subject_user_id, action,
                                resource_type, resource_id, request_id, ip_hash, user_visible,
                                metadata)
        SELECT now() - interval '30 days' + k * interval '1 minute', 'user',
               md5('perf-user-' || i)::uuid, md5('perf-user-' || i)::uuid,
               (ARRAY['contact.created', 'plan.updated', 'schedule.activated'])[1 + k],
               NULL, NULL, 'seed', decode(md5('ip-' || i), 'hex'),
               true, '{}'
          FROM generate_series(%(lo)s, %(hi)s) i CROSS JOIN generate_series(0, 2) k
        """,
    )
    chunked(
        "notifications (delivered)",
        """
        INSERT INTO notifications (id, user_id, audience, category, channel, template_key,
                                   params, status, send_after, attempt_count, dedupe_key,
                                   created_at, updated_at, sent_at, provider)
        SELECT md5('perf-notif-' || i || '-' || j)::uuid, md5('perf-user-' || i)::uuid, 'user',
               'user', 'email', 'checkin_pre_reminder', '{}', 'sent', ts, 1,
               'seed:' || md5(i || '/' || j), ts, ts, ts + interval '1 second', 'console'
          FROM generate_series(%(lo)s, %(hi)s) i
         CROSS JOIN generate_series(1, @J@) j
         CROSS JOIN LATERAL (
               SELECT now() - (((i::bigint * 31 + j * 17) %% 120) * interval '1 day')
                            - (j * interval '37 minutes') AS ts) t
        """,
    )
    chunked(
        "notification_logs",
        """
        INSERT INTO notification_logs (notification_id, attempted_at, provider, outcome,
                                       provider_message_id, latency_ms)
        SELECT id, sent_at, 'console', 'accepted', 'seed-' || md5(id::text), 40
          FROM notifications
         WHERE dedupe_key LIKE 'seed:%%'
           AND user_id IN (SELECT md5('perf-user-' || i)::uuid
                             FROM generate_series(%(lo)s, %(hi)s) i)
        """,
    )
    _timed(
        say,
        "ingestion_probes (30 days)",
        lambda: _run(
            conn,
            """
        INSERT INTO ingestion_probes (received_at, source)
        SELECT now() - m * interval '1 minute', 'monitor' FROM generate_series(1, 43200) m
        """,
        ),
    )
    _past_incidents(conn, layout, say)
    _special_states(conn, layout, say)


def _past_incidents(conn: psycopg.Connection[Any], layout: Layout, say: Say) -> None:
    """About one account in a hundred has a past, resolved incident (2 to 5 days ago). Deliberately
    less than a week of history: from ANOMALY_MIN_HISTORY on, the Hold's anomaly threshold is
    learned (at least a tenth of all active users per hour) instead of half of them, and PERF-02's
    10,000 of 100,000 would sit exactly on it (see PERF-02 in perf.py)."""
    started = time.monotonic()
    now = _db_now(conn)
    rows = 0
    for i in range(7, layout.users + 1, 100):
        if i in layout.grace or i in layout.escalated:
            continue
        opened = now - timedelta(days=2 + i % 4, hours=i % 7)
        _insert_incident(conn, i, opened=opened, status="resolved", now=now, past=True)
        rows += 1
    say(
        f"    {'escalation_incidents (past)':<32} {rows:>10,} rows  "
        f"{time.monotonic() - started:6.1f} s"
    )


def _special_states(conn: psycopg.Connection[Any], layout: Layout, say: Say) -> None:
    started = time.monotonic()
    now = _db_now(conn)
    for i in layout.grace:
        _insert_incident(conn, i, opened=now - timedelta(minutes=20), status="grace", now=now)
    for i in layout.escalated:
        _insert_incident(conn, i, opened=now - timedelta(minutes=200), status="escalated", now=now)
    total = len(layout.grace) + len(layout.escalated)
    say(
        f"    {'incidents (grace, escalated)':<32} {total:>10,} rows  "
        f"{time.monotonic() - started:6.1f} s"
    )


def _db_now(conn: psycopg.Connection[Any]) -> datetime:
    row = conn.execute("SELECT now()").fetchone()
    assert row is not None  # noqa: S101
    value = row[0]
    assert isinstance(value, datetime)  # noqa: S101
    return value.astimezone(UTC)


def _insert_incident(
    conn: psycopg.Connection[Any],
    i: int,
    *,
    opened: datetime,
    status: str,
    now: datetime,
    past: bool = False,
) -> None:
    """One incident of user ``i`` in the given state, with the timeline the opener writes."""
    uid, pid, sid, cid = user_id(i), plan_id(i), step_id(i), contact_id(i)
    snapshot = build_snapshot(
        plan_id=pid,
        plan_version=1,
        grace_minutes=GRACE_MINUTES,
        stages=[
            SnapshotStage(
                stage_id=sid,
                position=1,
                offset_minutes=STAGE_OFFSET_MINUTES,
                notify_contact_ids=(cid,),
            )
        ],
    )
    incident_id = _uuid("incident", i)
    missed = opened
    anchor = opened
    messaged = (
        opened + timedelta(minutes=STAGE_OFFSET_MINUTES, seconds=300)
        if (status == "escalated")
        else None
    )
    closed = opened + timedelta(minutes=45) if status == "resolved" else None
    conn.execute(
        """
        INSERT INTO escalation_incidents (id, user_id, plan_id, plan_version, plan_snapshot,
               missed_due_at, opened_at, anchor_at, grace_ends_at, status, contacts_messaged_at,
               closed_at, closed_by, created_at, updated_at)
        VALUES (%(id)s, %(uid)s, %(pid)s, 1, %(snap)s, %(missed)s, %(opened)s, %(anchor)s,
                %(grace_ends)s, %(status)s, %(messaged)s, %(closed)s, %(closed_by)s,
                %(opened)s, %(opened)s)
        """,
        {
            "id": incident_id,
            "uid": uid,
            "pid": pid,
            "snap": json.dumps(snapshot),
            "missed": missed,
            "opened": opened,
            "anchor": anchor,
            "grace_ends": anchor + timedelta(minutes=GRACE_MINUTES),
            "status": status,
            "messaged": messaged,
            "closed": closed,
            "closed_by": "user_checkin" if status == "resolved" else None,
        },
    )
    plan = parse_snapshot(snapshot)
    for action in materialise(
        incident_id=incident_id,
        snapshot=plan,
        anchor_at=anchor,
        final_warning_lead=timedelta(minutes=60),
    ):
        if status == "resolved":
            state = (
                "executed"
                if action.kind == "user_reminder" and action.variant == "missed"
                else "cancelled"
            )
        else:
            state = "executed" if action.scheduled_for <= now else "pending"
            if status == "escalated" and action.kind == "execute_stage":
                state = "executed"
        executed_at = action.scheduled_for if state == "executed" else None
        outcome = (
            json.dumps({"targets": [{"contact_id": str(cid), "result": "messaged"}]})
            if state == "executed" and action.kind == "execute_stage"
            else None
        )
        conn.execute(
            """
            INSERT INTO incident_actions (incident_id, user_id, kind, variant, step_id,
                   scheduled_for, original_scheduled_for, status, executed_at, outcome,
                   dedupe_key, created_at, updated_at)
            VALUES (%(incident)s, %(uid)s, %(kind)s, %(variant)s, %(step)s, %(at)s, %(at)s,
                    %(state)s, %(executed)s, %(outcome)s, %(key)s, %(created)s, %(created)s)
            """,
            {
                "incident": incident_id,
                "uid": uid,
                "kind": action.kind,
                "variant": action.variant,
                "step": action.step_id,
                "at": action.scheduled_for,
                "state": state,
                "executed": executed_at,
                "outcome": outcome,
                "key": action.dedupe_key,
                "created": opened,
            },
        )
    if status in ("grace", "escalated"):
        conn.execute(
            "UPDATE checkin_configurations SET status = 'incident_open', next_due_at = %s, "
            "baseline_at = %s, last_checkin_at = %s WHERE user_id = %s",
            (missed, missed - timedelta(days=1), missed - timedelta(days=1), uid),
        )
        # The newest check-in must not be later than the baseline (FS-25): history ends at it.
        conn.execute(
            "DELETE FROM checkin_events WHERE user_id = %s AND received_at > %s",
            (uid, missed - timedelta(days=1)),
        )
