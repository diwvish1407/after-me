# Query plans of the hot paths (Phase 11)

How these were made, what they showed, what changed. Regenerate the raw material with
`make perf ARGS="--only plans --plans-md plans.md"` (every distinct statement of the hot paths,
with its `EXPLAIN (ANALYZE, BUFFERS)`); `tests/perf/test_hot_path_plans.py` keeps the result true.

## Method

* Dataset: `scripts/perf.py --users 100000` on the throwaway database `afterme_perf`: 100,000
  verified people with an active schedule (deadlines spread over 24 h), profile, key, device,
  live session + refresh token, one verified contact, a one-stage plan, 20 check-ins and the 20
  audit records that go with them, 5 delivered reminders (30 % older than the 90-day retention),
  25,000 expired sessions, 100,000 used one-time codes, 43,200 ingestion probes, ~1,000 resolved
  incidents, 200 incidents in grace and 200 escalated. 2.0 M check-in events, 2.3 M audit rows,
  0.5 M notifications, 2.4 GiB. `VACUUM (ANALYZE)` after the seed.
* The application's own code runs (a request through the ASGI app, an engine tick, a dispatcher
  pass, the Hold monitor, the operator commands, every retention rule) while a recorder listens
  on the SQLAlchemy engines and keeps each distinct statement with the parameters of its first
  call. Each is then explained with those parameters, inside a transaction that is rolled back.
  Nothing is retyped: a statement that changes in the code changes in the plan.
* Machine: Apple M2, 8 cores, 16 GiB; PostgreSQL 14.19 (Homebrew; `shared_buffers` 128 MB,
  `work_mem` 4 MB), on the same machine as the load generator, the API and the worker. **Other
  work ran on the laptop** (load average 4 to 24 on 8 cores); times are indicative and the
  *before* runs were the more disturbed ones. The shape of a plan (index or scan, rows read) does
  not depend on that; the milliseconds do.

## Findings

Ordered by consequence. "Before" is 100,000 people without migration 0011; "after" with it
(`20261017_0011_performance_indexes.py`).

| # | Statement (path) | Before | After | Change |
|---|---|---|---|---|
| 1 | Retention of **sessions** (`DELETE FROM sessions ...`) | statement timeout (15 s) on the first batch; nothing ever deleted | 20 batches of 1,000 in 1.6 s, longest 0.7 s | `ix_checkin_events_session` (partial), `ix_checkin_events_device`: `ON DELETE SET NULL` of ONE session scanned all 2 M check-in events, 1,000 times per batch |
| 2 | Retention of **refresh tokens** | 6.1 s per batch (EXPLAIN), timeout on the 9th | 31 ms per batch; 20,000 rows in 2 s | `ix_refresh_tokens_replaced_by` (self-reference, `SET NULL`), `ix_checkin_events_session` |
| 3 | `due_actions` / `late_stage_actions` of the engine's unit of work for ONE person | read every due pending action of every person through `ix_incident_actions_due` (est. 10,748 rows) and kept one person's | index scan of that person's pending actions | `ix_incident_actions_user_pending (user_id, scheduled_for) WHERE status = 'pending'`. With 10,000 people due at once: 10,000 units x ~10,000 rows |
| 4 | Dispatcher `UPDATE notifications ... WHERE status = 'sending' AND updated_at < ...` (start of every pass) | Seq Scan, 114 ms at 0.5 M rows (~4 s at 18 M); every pass, and passes now repeat | 0.3 ms | `ix_notifications_sending (updated_at) WHERE status = 'sending'` (72 kB) |
| 5 | Retention of **notifications** | 346 ms per batch (Seq Scan + sort) | 47 ms | `ix_notifications_finished (created_at) WHERE status IN ('sent','failed','cancelled')` |
| 6 | Retention of **audit_logs**, **check-in events** | 467 ms / 211 ms per batch (index scan of a non-time index + sort) | 0.02 ms / 0.01 ms | `ix_audit_occurred`, `ix_checkin_events_received_at` |
| 7 | Hold anomaly check (`incidents opened in the hour`, `min(opened_at)`, same-hour baseline; every tick during a burst) | Seq Scan of `escalation_incidents` (14 scans), 42 ms at 1.4 k rows | 0.1 ms | `ix_incidents_opened (opened_at)` |
| 8 | Home / plan: `stage_contacts` | Seq Scan of `escalation_steps` (100,000 rows) on every `GET /v1/home` and plan read: 9.6 ms | 0.8 ms | `ix_escalation_steps_user (user_id)` |
| 9 | Retention of **devices** | 12 ms per batch; each deleted device scans `sessions`, `checkin_events`, `notifications` | `ix_sessions_device` etc. | `ix_sessions_device`, `ix_checkin_events_device`, `ix_notifications_device`, `ix_notifications_action` (all partial `IS NOT NULL`) |
| 10 | **Pre-deadline reminders** (not an index) | every person inside a reminder window (about 5 % of everyone) was read, locked and re-checked **on every tick** until the deadline (up to 2,000 units per tick); a full last page set `backlog`, so the worker never slept | candidates whose e-mail reminder for this deadline already exists are not selected; the scan is bounded to the largest lead (240 min) | `reminder_candidates` + `pre_reminder_stamp` (dedupe key now carries epoch seconds, see below). Steady tick 8.4 s p50 (loaded) -> 52 ms |

Index sizes at 100,000 people: `ix_checkin_events_received_at` 39 MB, `ix_audit_occurred` 38 MB,
`ix_checkin_events_device` 21 MB, `ix_checkin_events_session` 20 MB, `ix_notifications_finished`
5.3 MB, `ix_escalation_steps_user` 4.3 MB, `ix_sessions_device` 4.2 MB,
`ix_incident_actions_user_pending` 2.9 MB, `ix_notifications_device` 1.0 MB,
`ix_notifications_action` 0.6 MB, `ix_incidents_opened` 0.2 MB, `ix_notifications_sending` 72 kB,
`ix_refresh_tokens_replaced_by` 8 kB: about 135 MB on a 2.4 GiB database, growing with the
tables (check-in events and audit rows are the large ones). A `BRIN` index on the two
append-only time columns would be a few MB instead of 77 MB; it was not chosen because the
seed does not insert in time order, so the plan could not be shown here. Revisit on staging.

The migration uses plain `CREATE INDEX` (not `CONCURRENTLY`): acceptable for a system with no
traffic yet; on a live database build them concurrently first (the migration is
`IF NOT EXISTS`).

### Foreign keys

PostgreSQL checks `ON DELETE SET NULL / CASCADE` with the *child's* index; with none it scans the
child table once per deleted parent row. Every foreign key to `sessions`, `devices`,
`refresh_tokens` and `incident_actions` now has one (the test fails when a new one has not):
the only exception is `release_events.action_id` (a few rows per incident). Foreign keys to
`users` / `trusted_contacts` without a leading index (e.g. `incident_actions.user_id`,
`notifications.contact_id`, `release_events.user_id`) only matter for the account purge, which
deletes one account at a time in the background; they are listed in the report, not indexed.

### Round trips

Statements per request (API connection + the bookkeeping connection of the rate limiter and the
session touch), counted by the recorder, unchanged by this work:

| Request | API | Bookkeeping |
|---|---|---|
| `POST /v1/checkins` (new tap) | 12 | 5 (two rate-limit counters: delete + upsert each, plus the session touch) |
| `POST /v1/checkins` (replay) | 3 | 2 |
| `GET /v1/home` (active / grace / escalated) | 11 / 14 / 14 | 2 |
| `GET /v1/activity`, `GET /v1/checkins` | 4, 3 | 2 |

`GET /v1/home` is session lookup, the clock, then schedule, profile, contacts, plan, activity,
instructions, open incident, Hold: nine small indexed reads, 0.1 to 1 ms each. They were not
merged: p95 is 25 ms at 20 rps, and a merge would change the response code paths that the
contract tests pin. If Cloud SQL's round trip (1 to 2 ms) makes this matter, the cheapest folds
are `service_interruption` and `count_active` into one statement with the profile. The tests pin
the counts (`HOME_BUDGET`, `CHECKIN_BUDGET`).

## What the plans still show (and why it is accepted)

* `afterme-admin beta-report`: `count(DISTINCT user_id)` over **all** check-in events when no
  `--since` is given (4.4 s for 2 M rows with `work_mem` 4 MB; minutes and a statement timeout at
  40 M). It is an on-demand operator report. Run it with `--since`; or give the report a
  period-bound query. Other report/status statements scan `notifications` / `notification_logs`
  (20 to 140 ms at 0.5 M rows).
* Hold's count of active people (`status IN ('active','incident_open')`, 15 ms at 100,000) runs
  only when a burst exceeds the floor.
* Retention of `sessions`, `auth_tokens`: `least(...)` is an expression, so they scan
  (30 to 130 ms per batch at 125 k / 100 k rows); bounded by the number of people.
* `reminder_candidates` now costs ~60 ms per page in the middle of the day (one probe of
  `uq_notifications_dedupe_key` per person already reminded); it replaced up to 2,000
  transactions per tick.

## Behaviour changes made for these numbers

* **Dedupe key of a pre-deadline reminder** is `prereminder:{user}:{epoch seconds of the deadline}:...`
  instead of the ISO text of the deadline, so SQL can build it (docs/DATABASE.md section 3.8 names
  the old form). `params.due_at` (read by the dispatcher) is unchanged. A reminder queued
  under the old key before this release would be queued once more at the next tick of its window.
  A device whose push token arrives after the e-mail reminder was queued is picked up again
  (review E-2): a person is skipped only when the e-mail AND a push for every device that has a
  token exist (a few more index probes per person in the window; `make perf ARGS="--users 10000
  --only perf-02,tick"` after the change: reminder candidates p50 13 ms per page, steady tick
  p95 22 ms, PERF-02 PASS). Suspended accounts are no longer candidates.
* **Dispatcher backlog** (review E-4): a full pass counts as a backlog only if it moved
  something (sent, retried, failed, cancelled); a batch of rows that only wait is not.
* **Worker loop**: when a dispatcher pass is full (100 messages) the loop sends the next pass
  at once, until the next tick is due (`workers/engine.py: drain_outbox`). The tick and the
  contact-facing decision are the same; every message is still re-checked as it is claimed.
  Before, the loop sent at most 100 messages per tick period.
* **Engine tick**: the units of work of one page (open, execute, remind) run four at a time
  (`UNIT_CONCURRENCY`, `runtime.run_units`). Each is its own transaction on its own person.
