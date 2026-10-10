# AfterMe — Escalation Engine Specification

| | |
|---|---|
| **Status** | Draft v0.1 — awaiting product-owner approval |
| **Criticality** | **Highest.** This component decides whether people are contacted and whether private information is released. |
| **Related** | [PRD](PRD.md) · [ARCHITECTURE](ARCHITECTURE.md) · [DATABASE](DATABASE.md) · [TEST_PLAN](TEST_PLAN.md) |

> **Design principle: fail-safe, not fail-trigger.**
> If the system is uncertain (an error, inconsistent data, an outage, or an unexpected state), it **does not** contact anyone and **does not** release anything. A delayed alert is recoverable; a wrongful release is not.

---

## 1. Responsibilities

The engine owns:

1. Computing check-in deadlines.
2. Opening an **incident** when a deadline passes without a check-in.
3. Building the incident's **timeline**: user reminders, final warnings and stage executions.
4. Executing due timeline actions after passing the **safety gate**.
5. Writing every external effect to the **notification outbox**. It never calls providers directly.
6. Closing incidents when the user checks in (resolve) or confirms they are safe (cancel), and sending the **all-clear**.
7. Entering and leaving **Hold**, the system-wide circuit breaker.

The engine runs in the **worker process**, never in the API request path. The API only records check-ins and closes incidents, which are "stop" operations. No API endpoint can open an incident, run a stage or create a release.

## 2. Safety invariants

These are non-negotiable. Each has dedicated automated tests ([TEST_PLAN §4](TEST_PLAN.md#4-escalation-engine-tests)).

| ID | Invariant |
|---|---|
| **INV-1 Backend authority** | Only the engine worker can open incidents, execute stages or create releases. No client request, and no API handler, can cause escalation. |
| **INV-2 Check-in supremacy** | Once a check-in transaction has committed, nothing contact-facing for that user's incident is executed or sent afterwards (except the all-clear). |
| **INV-3 Single clock** | Every escalation-relevant timestamp comes from the **database clock**, through the `Clock` interface. Client timestamps are stored for information only and never used in a decision. |
| **INV-4 Fail-safe gate** | Every contact-facing action passes the safety gate (§6.4) inside the per-user lock. Any failed check, exception or ambiguity means **not executed**. There is no "execute anyway" path. |
| **INV-5 Exactly-once effects** | Incidents, timeline actions, releases and notifications carry unique dedupe keys. Running the engine twice on the same state produces no new effects. |
| **INV-6 Consent** | Contact-facing escalation messages and releases go only to contacts whose status is `verified` **at execution time** and who are not on the global suppression list. |
| **INV-7 Narrowing only** | Execution uses the **intersection** of the incident's plan snapshot and current live data. Live changes can remove actions but never add them. |
| **INV-8 Minimum notice** | The user always gets the full grace period, measured from when the incident was actually opened. No release runs earlier than `MIN_RELEASE_OFFSET` (24 h) after that point. |
| **INV-9 Warning before release** | A stage that releases instructions runs only if its final-warning action for that incident has executed. |
| **INV-10 Hold** | While the system is in Hold, no incident is opened and nothing contact-facing is executed or sent (all-clears excepted). |

## 3. Deadline computation

### 3.1 Schedule model (1.0)

```
interval_days   : 1..30
due_local_time  : HH:MM
timezone        : IANA name from user_profiles.timezone (e.g. "Asia/Kolkata")
```

Meaning, in user language: *"Check in at least once every N days, by HH:MM."* For N = 1: *"once a day, by 8 PM."*

### 3.2 Algorithm

The **baseline** is the server time of the last check-in, or of schedule activation or change.

```python
MIN_WINDOW = timedelta(hours=12)

def resolve_local(d: date, t: time, tz: ZoneInfo) -> datetime:
    """Local wall time -> UTC instant. In a DST gap or overlap, pick the LATER instant
    (gives the user more time, never less)."""
    naive = datetime.combine(d, t)
    a = naive.replace(tzinfo=tz, fold=0).astimezone(UTC)
    b = naive.replace(tzinfo=tz, fold=1).astimezone(UTC)
    return max(a, b)

def compute_next_due(baseline: datetime, interval_days: int, due: time, tz: ZoneInfo) -> datetime:
    d = baseline.astimezone(tz).date() + timedelta(days=interval_days)
    while True:
        candidate = resolve_local(d, due, tz)
        if candidate - baseline >= MIN_WINDOW:
            return candidate
        d += timedelta(days=1)
```

Properties (verified by property-based tests with Hypothesis across all IANA zones):

- `next_due − baseline ≥ 12 h`
- `next_due − baseline ≤ interval_days + 1 day (+ DST shift)`
- The local wall time of `next_due` equals `due_local_time`, except inside a DST gap, where it is later.
- Deterministic: same inputs, same output.

### 3.3 Verified test vectors

| Case | Input | Expected `next_due` / resolution |
|---|---|---|
| Daily 20:00 IST, check-in Tue 2026-10-13 19:30 | baseline 19:30 +05:30 | Wed 2026-10-14 20:00 +05:30 |
| Daily 20:00 IST, check-in Tue 10:00 | | Wed 2026-10-14 20:00 +05:30 |
| Daily 20:00 IST, check-in Tue 23:59 | | Wed 2026-10-14 20:00 +05:30 |
| Daily 20:00 IST, check-in Wed 00:01 | | Thu 2026-10-15 20:00 +05:30 |
| Daily 00:30 IST, check-in Tue 23:50 | candidate Wed 00:30 is < 12 h away | Thu 2026-10-15 00:30 +05:30 |
| DST gap, America/New_York 2026-03-08 02:30 | non-existent local time | 2026-03-08T07:30Z (03:30 EDT) |
| DST overlap, America/New_York 2026-11-01 01:30 | ambiguous local time | 2026-11-01T06:30Z (second occurrence, EST) |
| DST gap, Europe/London 2026-03-29 01:30 | non-existent | 2026-03-29T01:30Z (02:30 BST) |
| DST overlap, Europe/London 2026-10-25 01:30 | ambiguous | 2026-10-25T01:30Z (second occurrence, GMT) |

### 3.4 Schedule and timezone changes

- Not allowed while an incident is open (`409 incident_open`). The user must check in first.
- Otherwise the new deadline is `compute_next_due(baseline = now, …)` with the new settings, and the change is audited. Changing the schedule therefore also resets the clock. That is acceptable because only the authenticated owner can do it.
- The timezone **never** changes automatically. The app may suggest an update when the device timezone differs (FR-PROF-03).
- The timezone database (`tzdata`) is pinned and updated through normal dependency updates. Updates are noted in release notes.

## 4. Incident lifecycle

### 4.1 States

```
                         deadline passed, no check-in, not in Hold
     ┌───────────────┐   (worker)                                    ┌──────────────┐
     │  no incident  │ ─────────────────────────────────────────────▶│    GRACE     │
     └───────────────┘                                               └──────┬───────┘
            ▲                                                               │ stage 1 executes
            │ schedule restarts                                             ▼
            │                                                        ┌──────────────┐
            │                                                        │  ESCALATING  │
            │                                                        └──────┬───────┘
            │                                                               │ last stage executes
            │                                                               ▼
            │                                                        ┌──────────────┐
            │                                                        │  ESCALATED   │ (open; nothing pending)
            │                                                        └──────────────┘
            │
            │   From any OPEN state (grace / escalating / escalated):
            │     • I'M OK, and no contact has been messaged yet ─────▶ RESOLVED
            ├──── • I'M SAFE (re-auth), contacts were messaged ──────▶ CANCELLED (+ all-clear)
            │     • account deleted / operator void ─────────────────▶ VOIDED (+ all-clear if any messaged)
```

| State | Open? | Meaning |
|---|---|---|
| `grace` | ✓ | Deadline missed. No stage has executed yet. Only the user is being reminded. |
| `escalating` | ✓ | At least one stage has executed and more are pending. |
| `escalated` | ✓ | All stages have executed. Releases stay valid until the user returns. |
| `resolved` | ✗ | The user checked in before any contact was messaged. Nobody else ever knew. |
| `cancelled` | ✗ | The user confirmed I'M SAFE after contacts were messaged. All-clear sent; releases revoked. |
| `voided` | ✗ | Closed by the system (account deletion, operator action after a confirmed fault). |

Constraints:
- **At most one open incident per user** (partial unique index).
- **At most one incident per missed deadline** (`UNIQUE (user_id, missed_due_at)`).
- While an incident is open, the schedule is suspended (`checkin_configurations.status = 'incident_open'`), so no new deadlines are generated.

### 4.2 "Contacts messaged" decides I'M OK vs I'M SAFE

`escalation_incidents.contacts_messaged_at` is set by the **dispatcher**, inside the per-user lock, at the moment the first contact-facing escalation message is handed to a provider (§8.2).

- `contacts_messaged_at IS NULL`: a normal **I'M OK** check-in resolves the incident. Any stage that executed but whose messages are still inside the settle delay is rolled back silently: queued messages are cancelled and releases revoked before anyone could see them.
- `contacts_messaged_at IS NOT NULL`: `POST /v1/checkins` returns `409 safe_required`, and the user must use **I'M SAFE**, which requires re-authentication (FR-AUTH-08) and sends the all-clear.

## 5. The incident timeline

### 5.1 Plan model

```
escalation_plan
  grace_minutes                 60..4320           (stage 1 always runs at the end of grace)
  stages[1..N]                  N ≤ tier limit (free 2, premium 10)
    offset_minutes              stage 1: = grace_minutes
                                stage k: ≥ stage(k-1).offset + 30, ≤ 43200 (30 days)
    notify_contact_ids[]        contacts messaged at this stage
    (releases)                  instruction_recipients whose release_stage = this stage
                                → that stage's offset_minutes must be ≥ MIN_RELEASE_OFFSET (1440)
```

The plan is valid if it has ≥ 1 stage. Activating the plan requires ≥ 1 stage that notifies ≥ 1 contact (an empty stage is allowed later, e.g. after a contact is deleted, and simply does nothing).

### 5.2 Anchor

```
anchor_at = max(missed_due_at, opened_at)
```

All offsets are measured from `anchor_at`. If the worker opens the incident late (for example after downtime), the user still gets the **full** grace period from the moment the incident actually exists (INV-8).

### 5.3 Materialised actions

When the incident is opened, the engine inserts every timeline action in the same transaction. The user can then see the entire future timeline, and the worker only needs to execute rows.

| Kind | Variant | Scheduled for | Audience | Subject to Hold |
|---|---|---|---|---|
| `user_reminder` | `missed` | `anchor` | User (push + email) | No |
| `user_reminder` | `midpoint` | `anchor + grace/2` | User (push) | No |
| `user_reminder` | `last_chance` | `anchor + grace − 15 min` | User (push + email) | No |
| `user_final_warning` | — | `anchor + stage.offset − 60 min` (for each stage with releases) | User (push + email) | No |
| `execute_stage` | stage N | `anchor + stage.offset` | Contacts (+ summary to user) | **Yes** |

Dedupe key: `incident:{incident_id}:{kind}:{variant|stage_id}`.

### 5.4 Plan snapshot

`escalation_incidents.plan_snapshot` (JSONB) records the plan at opening time:

```json
{
  "schema": 1,
  "plan_id": "…", "plan_version": 7, "grace_minutes": 180,
  "stages": [
    { "stage_id": "…", "position": 1, "offset_minutes": 180,
      "notify_contact_ids": ["c-mom"], "releases": [] },
    { "stage_id": "…", "position": 2, "offset_minutes": 1440,
      "notify_contact_ids": ["c-bro"],
      "releases": [ { "instruction_id": "i-house", "contact_id": "c-bro" } ] }
  ]
}
```

Snapshots contain **IDs only**, never names, addresses or content. At execution, each ID is re-validated against live data (INV-7).

## 6. Worker algorithm

### 6.1 Tick loop

```
every TICK_SECONDS (15 s), per worker replica:
    1. heartbeat()                        upsert service_heartbeats
    2. hold.evaluate()                    probes, anomaly, operator flag → enter/exit Hold (§7)
    3. if not hold.active:
           open_due_incidents(batch)      §6.3
    4. execute_due_actions(batch)         §6.4  (contact-facing actions skip themselves while in Hold)
    5. enqueue_pre_deadline_reminders()   user-only, dedupe per (user, next_due_at)
    6. dispatch_outbox(batch)             §8 (may run as a separate process; same rules)
```

Each unit of work (one user) runs in its **own short transaction**. An exception rolls back that unit only, is logged with its error class (never with sensitive data), increments a metric, and is retried on the next tick. Other users are unaffected.

### 6.2 Locking and lock order

The **per-user lock** is the user's `checkin_configurations` row (`SELECT … FOR UPDATE`). Every code path that reads or changes escalation state for a user takes it first. The global lock order is:

```
1. checkin_configurations (user)  →  2. escalation_incidents  →  3. incident_actions  →  4. notifications / release_events
```

| Path | Lock acquisition |
|---|---|
| Worker (open incident, execute action, dispatch contact-facing message) | `FOR UPDATE SKIP LOCKED` on the user row. If it is busy, skip and retry next tick. |
| API (check-in, I'M SAFE, schedule/plan change, account deletion) | `FOR UPDATE` with `lock_timeout = 5s`. On timeout, return `503 retryable` and the client retries with the same idempotency key. |

Because every path takes the same lock first, check-ins and stage executions are **serialised per user**, and deadlocks are prevented by the fixed lock order. Multiple worker replicas are safe: `SKIP LOCKED` gives each user to exactly one replica per tick.

### 6.3 Opening incidents

```sql
-- candidates (no locks)
SELECT user_id FROM checkin_configurations
 WHERE status = 'active' AND next_due_at <= :now
 ORDER BY next_due_at LIMIT :batch;
```

For each candidate, in its own transaction:

1. Lock the user row (`SKIP LOCKED`). Re-check `status = 'active' AND next_due_at <= :now`.
2. **Consistency check:** `NOT EXISTS (checkin_events WHERE user_id = :u AND received_at > baseline_at)`. If a check-in exists that the schedule didn't absorb, the data is inconsistent: **do not open**, raise a critical alert, and leave the row for investigation.
3. Check that the user account is `active`. If not, skip.
4. Load the plan; build the snapshot; compute `anchor_at = max(next_due_at, :now)`.
5. `INSERT escalation_incidents` (status `grace`). The unique constraints make a duplicate open impossible.
6. `INSERT incident_actions` for the whole timeline (§5.3).
7. `UPDATE checkin_configurations SET status = 'incident_open'`.
8. Write the audit event `incident.opened`.
9. Commit.

### 6.4 Executing due actions and the safety gate

```sql
-- candidates (no locks)
SELECT DISTINCT user_id FROM incident_actions
 WHERE status = 'pending' AND scheduled_for <= :now LIMIT :batch;
```

For each user, in one transaction: lock the user row (`SKIP LOCKED`), then the incident, then the due actions (oldest first).

**Safety gate.** Every check runs inside the transaction, after locking.

| # | Check | On failure |
|---|---|---|
| G1 | System is **not** in Hold (re-read inside the transaction). *Contact-facing actions only.* | Leave `pending`. Shifted when the Hold ends. |
| G2 | Incident is open (`grace` / `escalating` / `escalated`). | Mark action `cancelled`. |
| G3 | No `checkin_events` for this user with `received_at > incident.missed_due_at`. | **Inconsistent.** Mark `held` and raise a critical alert. |
| G4 | `scheduled_for ≤ now`, `scheduled_for ≥ anchor + grace` (stages), and for release stages `offset ≥ MIN_RELEASE_OFFSET` (re-validated against current config). | Mark `held` and raise a critical alert. |
| G5 | User account `active`. | Mark `cancelled` (account deletion closes the incident separately). |
| G6 | Snapshot `schema` recognised; `incident.user_id = action.user_id = locked user`. | Mark `held` and raise a critical alert. |
| G7 | *Per target contact:* belongs to user, not deleted, `is_active`, `verification_status = 'verified'`, address not suppressed. | Skip **that target**; record the reason. |
| G8 | *Per release:* instruction belongs to user, not deleted, `status = 'active'`, recipient mapping still exists with this stage; contact passed G7. | Skip **that release**; record the reason. |
| G9 | *Release stages:* the stage's `user_final_warning` action has status `executed`. | Leave `pending`. If it has been waiting more than 30 min, mark `held` and alert. |

The global checks G1–G6 and G9 decide whether the action runs at all. The per-target checks G7–G8 narrow it (INV-7). An exception anywhere rolls back the whole transaction, and `attempt_count` is incremented in a separate transaction. **After 5 failed attempts the action becomes `held` and an operator is alerted. A held action is never executed automatically.**

### 6.5 What each action does (inside the same transaction)

**`user_reminder` / `user_final_warning`:** Enqueue user notifications (push + email per §5.3), mark the action `executed`, and audit.

**`execute_stage`:**
1. Compute `targets = (notify_contact_ids ∪ release contacts) ∩ G7-valid`.
2. For each valid release (G8): `INSERT release_events` (unique `(incident_id, instruction_id, contact_id)`, `visible_after = now + SETTLE_DELAY`).
3. For each target contact, enqueue **at most one** message for this stage. The template depends on context: `contact_alert` (first message, no release), `contact_alert_with_release` (first message plus release), or `contact_release` (already alerted earlier). Category `contact_escalation`, `send_after = now + SETTLE_DELAY`.
4. Ensure a `portal_access` row exists for each `(incident, contact)` with a release. The bearer token is minted by the **dispatcher** at send time and only its hash is stored, so the raw token never sits in the database.
5. Enqueue a user summary ("Mom has been notified. Brother has received *House emergency*"). Instruction titles are **not** put in push payloads; the email shows only "1 instruction".
6. Update incident status: `grace` → `escalating`; and → `escalated` if no `execute_stage` remains pending.
7. Mark the action `executed` and record per-target outcomes. Write audit events: `escalation.stage_executed`, `release.created` (per release), `notification.queued`.

### 6.6 Settle delay

Contact-facing escalation messages and releases wait `SETTLE_DELAY` (5 min) before they can be sent or viewed. This:
- gives a last-moment check-in the chance to stop them before anyone sees them (§4.2);
- is longer than Hold detection (`INGESTION_STALE` = 3 min), so a stage that ran during an undetected outage can be rolled back before anything leaves the system (§7.3).

### 6.7 Late stages (the worker was down, or the clock jumped)

*Owner decision 2026-10-10, resolving review finding F-03.* A worker that was running executes a stage within a tick of its time. A contact-facing stage found **more than `LATE_TOLERANCE_SECONDS` (300) overdue** was not found by a running worker, and the person has meanwhile received none of the reminders that come before it, so running it at once would contact someone with no warning at all. Instead, in the same transaction and before anything is executed (and never during a Hold, which has its own shift, §7.3):

1. The earliest overdue stage `S` is put back to `now + max(LATE_SHIFT_MINUTES, …)`, and **every stage from `S` onwards moves by the same amount**, so their spacing (≥ 30 min) and order are kept. If a moved stage releases instructions, the amount is raised so that it is still a full `FINAL_WARNING_LEAD` (60 min) after now: its final warning, if already due, runs in this tick and the stage can never run in the same tick as its warning (INV-9).
2. Final warnings that are still ahead move with their stage; one that is already due runs now, as it should.
3. The person gets **one** `incident_delayed` message (push and email) saying who will be notified at what time, with the real time. It uses its own dedupe key (`late:{action}:{scheduled epoch}:{channel}`) and is cancelled if the incident closes first.
4. `escalation.stage_deferred` is audited with how late it was and how far it moved.

It can only delay an alert, never advance one: every moved action ends strictly later than it was. Reminders are unaffected (they are superseded after the end of grace, §13.1 note 3). If the outage repeats, the stage is put back again and the person warned again.

## 7. System Hold (the circuit breaker)

### 7.1 Why

If users **can't** check in (API down, network or ingress failure, a broken app release), deadlines pass through no fault of the user. Without Hold, the engine would alert contacts for thousands of people at once. Hold stops that.

### 7.2 Triggers

| Trigger | Detection | Exit |
|---|---|---|
| **Ingestion outage** | An external uptime monitor calls `POST /internal/probe` through the **public ingress** every 60 s. The API records each probe in `ingestion_probes`. Hold starts if the latest probe is older than `INGESTION_STALE` (3 min). The Hold is **backdated** to the last good probe. On each tick the worker also scans probe history since its watermark for gaps > 3 min that happened while it was down, and records them as closed Hold windows. | Automatic, after probes have been fresh for 10 continuous minutes. |
| **Anomaly** | Incidents opened in the last 60 min (counting only those since the last anomaly Hold ended) exceed a threshold that follows **how many people there are and what this hour of the day normally has**: without a week of history, `max(ANOMALY_FLOOR = 25, ½ × active users)`; with it, `max(floor, ⅒ × active users, min(4 × the most that opened in this same hour on any of the last 14 days, 0.9 × active users))`. A due time that many people share makes one hour of every day busy, which is not an anomaly; a bad release that stops check-ins takes nearly everyone who is due, which is. | **Manual only**, after an operator investigates. |
| **Operator** | `afterme-admin hold enter --reason "…"` (audited). | Manual: `afterme-admin hold exit`. |

### 7.3 Behaviour

**While Hold is active:**
- No incidents are opened (deadlines simply wait).
- `execute_stage` actions stay `pending`.
- The dispatcher does not send `contact_escalation` messages; they stay queued. The portal hides releases created inside a Hold window.
- User reminders continue (harmless and useful). All-clears and OTPs continue (they reduce harm).
- The operator is paged.

**When Hold ends** (window `[started_at, ended_at]`), in one transaction per affected user:
1. **Roll back undelivered effects inside the window.** For every `execute_stage` action executed inside the window whose contact messages were **not yet handed to a provider**: cancel those messages, revoke the releases it created, reset the action to `pending`.
2. **Shift.** For every open incident, add `shift = (ended_at − started_at) + HOLD_RECOVERY_BUFFER` (30 min) to all pending `execute_stage` and `user_final_warning` actions. Their relative spacing is preserved.
3. Send each affected user a reminder: "We had a service interruption. Please check in."
4. Audit `system.hold_exited` with the counts.

Deadlines that passed during the Hold are processed normally once the Hold ends. Because `anchor = max(missed_due_at, opened_at)`, each of those users gets a full grace period starting then.

### 7.4 Residual risk (accepted, documented)

- Hold detection is backdated, and the settle delay (5 min) is longer than detection (3 min). So a stage that runs during an outage is caught before its messages leave, unless the dispatcher itself keeps sending through an outage that is invisible to the probe. That is mitigated because the probe goes through the same public ingress as real users.
- Notifications are **at-least-once** at the provider boundary (§8.3). A duplicate alert is possible in rare crash cases. A **wrongful** alert is not.

## 8. Notifications (outbox coupling)

### 8.1 Categories

| Category | Examples | Hold applies | Settle delay | Requires open incident |
|---|---|---|---|---|
| `user` | reminders, warnings, summaries, security emails | No | No | No |
| `contact_escalation` | alert, alert + release, release | **Yes** | **Yes** | **Yes** |
| `contact_other` | invitation, OTP, all-clear | No | No | No |

### 8.2 Dispatch of `contact_escalation` messages

```
tx A (per user lock, SKIP LOCKED):
    re-check: notification still 'queued', send_after ≤ now, not in Hold,
              no Hold window covers the creating action, incident still open,
              contact still verified and not suppressed
    on any failure → mark 'cancelled' (or leave queued if Hold) and stop
    mark notification 'sending'; mint portal token (store hash); set incident.contacts_messaged_at if NULL
commit
call provider (outside any transaction, with idempotency key = notification.id where supported)
tx B: mark 'sent' (+ provider message id) or 'failed' with retry schedule; write notification_logs row
```

Once tx A commits, the message counts as "messaged" for §4.2, even if the provider call later fails. This is the conservative direction: the user is asked to confirm I'M SAFE, and the contact gets an all-clear.

### 8.3 Retries and failure

- Exponential backoff: 1, 2, 4, 8, 16, 32, 60 min, then hourly, up to 24 h.
- After 3 consecutive provider failures, switch to the secondary email provider if one is configured.
- Hard bounce (provider webhook): contact → `bounced`, user notified to fix the address.
- After the maximum attempts: `failed`, operator alerted, and the user is told the contact could not be reached.
- Duplicate delivery after a crash between the provider call and tx B is possible. It is mitigated by provider idempotency keys and accepted as low-harm.

## 9. Check-in and cancellation (API side)

### 9.1 `POST /v1/checkins` (I'M OK)

```
BEGIN
  lock checkin_configurations (user) FOR UPDATE, lock_timeout 5s
  if checkin_events has (user, Idempotency-Key) → return the stored result (replay-safe)
  incident ← open incident FOR UPDATE (if any)
  if incident and incident.contacts_messaged_at IS NOT NULL → ROLLBACK; 409 safe_required
  INSERT checkin_events(kind='ok', received_at = now)
  if incident:
      incident.status = 'resolved', closed_by = 'user_checkin'
      pending actions → 'cancelled'
      queued notifications for the incident (except user/all-clear) → 'cancelled'
      release_events for the incident → revoked (never visible: still within settle delay)
  baseline_at = last_checkin_at = now; next_due_at = compute_next_due(now, …); status = 'active'
  audit checkin.recorded (+ incident.resolved)
COMMIT → 200 { next_due_at, … }
```

**Stale replay: a decision for Phase 5.** The app keeps an unconfirmed tap and retries it with the same key whenever it next runs, however late. The server stamps `received_at` at *receipt* and computes the next deadline from that instant, so a tap made at 18:00 that reaches the server two days later restarts the clock two days after the user's last real confirmation. While no engine exists this has no effect; once it does, it can delay an escalation that should have fired. The options, none yet chosen: (a) accept it as specified; (b) the app drops, with a visible notice, a pending tap older than a threshold (keeps INV-3: the server still never uses a client time); (c) the server records but does not advance the deadline for a tap whose `client_reported_at` is older than a threshold (uses a client time in a decision, and a phone with a wrong clock could then cause a *wrongful* escalation, so this is the worst option). **Decided (owner, 2026-10-10): (b).** The app drops a pending tap whose age exceeds `pendingCheckInMaxAge` = **12 hours** (the minimum window of §3.2) and says so on Home ("Your earlier check-in wasn't received"); a tap younger than that is delivered as the tap it was. The age is measured on the phone's own clock (tap time to now); a clock that moved back never drops a tap. The check is made when a stored record is restored and before every retry, so a tap can also age out while the app stays open offline. The server is unchanged: it never uses a client time in a decision (INV-3). The threshold is one constant and can be tuned when the engine's grace periods are tested end to end. (A tap exactly 12 hours old is still sent. A fresh tap made while a record kept after `426` is stale simply replaces it with a new key.)

### 9.2 `POST /v1/incidents/{id}/safe` (I'M SAFE)

Requires: ownership of the incident, an open incident, and re-authentication within the last 5 min (`sessions.reauthenticated_at`).

```
BEGIN (same lock order)
  idempotency check
  INSERT checkin_events(kind='safe')
  incident.status = 'cancelled', closed_by = 'user_safe'
  pending actions → 'cancelled'; queued contact_escalation notifications → 'cancelled'
  release_events → revoked_at = now; portal_access → revoked
  for each contact with a message in status 'sending' or 'sent' for this incident:
      enqueue contact_all_clear (category contact_other, dedupe per incident+contact)
  restart the schedule (as §9.1)
  audit incident.cancelled, release.revoked (×n), notification.queued (×n)
COMMIT
```

### 9.3 Race analysis

| Interleaving | Outcome |
|---|---|
| Check-in commits, then the worker reaches the user | The worker re-reads under lock: incident closed → G2 cancels the actions. **No effect.** |
| The worker executes stage 1, then the check-in arrives within the settle delay | The check-in sees `contacts_messaged_at IS NULL`, resolves, cancels the queued messages and revokes the releases. **Nobody is contacted.** |
| The dispatcher's tx A commits (message being sent), then the check-in arrives | `contacts_messaged_at` is set → `409 safe_required`; I'M SAFE sends the all-clear. **Correct and honest.** |
| Two check-ins with the same key | The second waits for the lock, finds the key and returns the same result. **One event.** |
| Two worker replicas | `SKIP LOCKED` on the user row: one replica processes that user, the other skips. Dedupe keys back this up. |

## 10. Changes during an open incident

| Change | Allowed? | Effect |
|---|---|---|
| Schedule / timezone / plan stages / grace | **No** (`409 incident_open`) | The user must check in first. |
| Deactivate or delete an instruction | Yes | Its releases are skipped by G8. Already-created releases from this incident are revoked. |
| Remove a recipient mapping | Yes | Skipped by G8. |
| Delete a contact | Yes | Skipped by G7. The contact's releases are revoked. No all-clear is sent to a deleted contact; that is the user's own action. |
| Contact opts out (portal) | Yes | Skipped by G7. Releases to them are revoked. |
| Account deletion | Yes | The incident becomes `voided`, all-clear goes to contacts already messaged, releases are revoked, then the deletion flow continues. |
| Subscription lapses | — | **No effect** on an open incident or on the configured plan ([PRD §10](PRD.md#10-free-and-premium-)). |

## 11. Failure-scenario catalogue

Each scenario has an automated test (prefix `ENG-FS`, see [TEST_PLAN §4.3](TEST_PLAN.md#43-failure-scenario-tests)).

| ID | Scenario | Expected behaviour |
|---|---|---|
| FS-01 | The check-in DB write fails (error or timeout) | API returns 5xx/503; no partial state; the app shows "Not received — retrying" and retries with the same key; reminders continue. If the failure is widespread, the probe goes stale → Hold. |
| FS-02 | The check-in commits but the response is lost | The client retries with the same `Idempotency-Key` and gets the original result; one event. |
| FS-03 | Double tap / concurrent check-ins | Serialised by the user lock; the same key gives one event. |
| FS-04 | The check-in races a stage execution | See §9.3. Never a contact message after the check-in commits. |
| FS-05 | The worker crashes mid-transaction | Rollback; the action stays `pending`; retried next tick. |
| FS-06 | The worker crashes after commit, before dispatch | The outbox persists; the dispatcher sends later (subject to its own re-checks). |
| FS-07 | The dispatcher crashes after the provider accepted the message | Possible duplicate message; never a wrongful one. Provider idempotency key used where supported. |
| FS-08 | All workers down for hours, API up | No incidents opened, no actions. On restart: `anchor = now`, so full grace. A stage of an already-open incident that is **more than `LATE_TOLERANCE` overdue is not run**: it is put back to at least `LATE_SHIFT` from now (with every later stage, by the same amount) and the person is warned again with the real time (§6.7). A stage that is only slightly late runs as usual. |
| FS-09 | API/ingress down, worker up | Probes stop → Hold (backdated) → nothing contact-facing. On recovery: rollback inside the window, then shift. |
| FS-10 | Database down | Nothing runs. On recovery, the probe gap → closed Hold window → rollback/shift. Anchor rule gives full grace. |
| FS-11 | FCM down | User reminders also go by email. No effect on escalation timing. |
| FS-12 | Email provider down | Retries, then fallback provider. Contact alerts are delayed, not lost. Operator alerted when the backlog age exceeds 5 min. |
| FS-13 | Mass-miss (e.g. a bad app release blocks check-ins) | Anomaly Hold; operator investigates; exit with shift, or void incidents if a bug is confirmed. A void **restarts the schedule** (a full interval from now; not a check-in) and tells the person (the service-interruption notice, or the all-clear confirmation when contacts had been told): without that the person would be left with `incident_open` and no incident, which nothing ever picks up again (review F-01). |
| FS-14 | DST gap or overlap on a deadline | §3.2 resolution (the later instant). Vectors in §3.3. |
| FS-15 | The user travels to another timezone | Nothing changes until the user explicitly updates the timezone; then it is recomputed from now. |
| FS-16 | Plan edit attempted during an incident | `409 incident_open`. |
| FS-17 | Instruction deleted, contact removed or opted out during an incident | Narrowed by G7/G8; existing releases revoked. |
| FS-18 | Account deleted during an incident | Voided; all-clear to contacts already messaged; releases revoked. |
| FS-19 | Replay of a captured check-in request | Same key → stored result. A new key with an expired token → 401. Server time is used regardless. |
| FS-20 | Device clock wrong | Irrelevant; only server time is used. |
| FS-21 | Snapshot references a deleted stage, contact or instruction | Skipped by the gate; reason recorded. |
| FS-22 | Two or more worker replicas | `SKIP LOCKED` plus dedupe keys: exactly-once effects (concurrency test with 4 workers). |
| FS-23 | An action raises persistently | 5 attempts → `held` → operator alert. Never auto-executed afterwards. |
| FS-24 | Database clock adjusted (NTP) | Actions never run before `scheduled_for` by DB time. Large jumps alert via monitoring. |
| FS-25 | A check-in exists that the schedule didn't absorb | The incident is not opened (or the action is held). Critical alert. |
| FS-26 | Premium lapses during an incident | No effect. |
| FS-27 | The user's session expired; can't check in from the app | Log in again (app or web); reminders explain this; forgot-password path available. |
| FS-28 | Deadline reached while the check-in request is in flight | Serialised by the lock. Either no incident is opened, or it opens and is immediately resolved by the check-in (I'M OK; nobody contacted). |

## 12. Observability

| Metric / alert | Threshold | Severity |
|---|---|---|
| Worker heartbeat age | > 2 min | **Page** |
| Hold active | any | **Page** |
| Hold evaluation failing (engine ticks, the `hold_monitor` heartbeat is older than 2 min) | any | **Page** |
| `held` actions of open incidents | > 0 | **Page** |
| Messages given up on after 24 h (`failed`, last 7 days) | > 0 | **Page** |
| Consistency-check failures (FS-25) | > 0 | **Page** |
| Oldest due-but-unexecuted action | > 5 min | Page |
| Oldest queued notification past `send_after` | > 5 min | Page |
| Provider failure rate (15 min) | > 5% | Alert |
| Incidents opened per hour | anomaly (§7.2) | Hold + page |
| Incidents escalated then cancelled (false alarms) | trend | Product review |

Structured log events carry `user_id` (pseudonymous UUID), `incident_id`, `action_id`, `kind` and `outcome`. They **never** carry names, addresses, instruction content or tokens.

## 13. Configuration

| Parameter | Default | Notes |
|---|---|---|
| `TICK_SECONDS` | 15 | Worker loop interval (environment variable `AFTERME_TICK_SECONDS`, and likewise for every row) |
| `MIN_WINDOW_HOURS` | 12 | Minimum time from a check-in to the next deadline |
| `GRACE_MIN_MINUTES` / `GRACE_MAX_MINUTES` | 60 / 4320 | |
| `STAGE_MIN_GAP_MINUTES` | 30 | |
| `STAGE_MAX_OFFSET_MINUTES` | 43200 | 30 days |
| `MIN_RELEASE_OFFSET_MINUTES` | 1440 | Fail-safe minimum for releases |
| `FINAL_WARNING_LEAD_MINUTES` | 60 | |
| `SETTLE_DELAY_SECONDS` | 300 | Must be > `INGESTION_STALE_SECONDS` |
| `INGESTION_PROBE_INTERVAL_SECONDS` | 60 | External monitor |
| `INGESTION_STALE_SECONDS` | 180 | |
| `HOLD_EXIT_FRESH_SECONDS` | 600 | |
| `HOLD_RECOVERY_BUFFER_MINUTES` | 30 | |
| `ANOMALY_FLOOR_PER_HOUR` | 25 | The absolute floor; the fractions of §7.2 are constants |
| `LATE_TOLERANCE_SECONDS` | 300 | A contact-facing stage found later than this is put back (§6.7); at least two ticks |
| `LATE_SHIFT_MINUTES` | 30 | How far from now it is put back; at least 30 in production |
| `ACTION_MAX_ATTEMPTS` | 5 | Then `held` |
| `API_LOCK_TIMEOUT_MS` | 5000 | |

Startup validation refuses to run if `SETTLE_DELAY_SECONDS ≤ INGESTION_STALE_SECONDS + 2 × TICK_SECONDS`, `LATE_TOLERANCE_SECONDS < 2 × TICK_SECONDS` or `MIN_RELEASE_OFFSET_MINUTES < 1440` in production.

### 13.1 Phase 5 implementation notes

*Where it lives.* `backend/app/engine/` (worker-only code; a test enforces that the API process never imports it): `timeline.py` (pure materialisation), `gate.py` (pure G1–G9 and G7), `opener.py` (§6.3), `executor.py` (§6.4–§6.5), `dispatcher.py` (§8), `hold.py` (§7), `runtime.py` (the tick), `store.py` (system-level queries). The snapshot (`app/incidents/snapshot.py`) is shared data. Entry points: `python -m workers.engine` (tick + dispatcher), `python -m cli.admin` (operator: `status`, `hold status|enter|exit`, `incident void`, `action retry`). Every parameter of §13 is an environment variable `AFTERME_<NAME>`; `SETTLE_DELAY_SECONDS > INGESTION_STALE_SECONDS` is refused at startup in every environment.

*Deliberate additions and deviations from the text above (each is tested):*
1. **The user's "has been notified" summary waits the settle delay too** (`send_after = now + SETTLE_DELAY`) and is cancelled when the stage is rolled back or the incident resolved. The user is never told something that is not yet true, and a Hold rollback leaves nothing to retract.
2. **A Hold blocks until its exit is processed** (rollback and shift applied). Between `ended_at` and processing, no incident opens and no contact message is sent (INV-10).
3. **Reminders expire.** A `user_reminder` found after the end of grace, or after a stage has run, is cancelled as *superseded*: "Mom will be notified at 11:00 PM" must not be sent at 11:01 PM.
4. **Dedupe keys carry the action's scheduled instant** (see DATABASE §3.4 notes) so a rolled-back and shifted stage can message again exactly once.
5. **Hold exit idempotency.** The per-user "service interruption" notice's dedupe key `(hold, user)` is written in the same transaction as the shift and doubles as the "already processed" marker; users whose lock is busy are retried on the next tick and the Hold's `exit_processed_at` is set only when every affected user was processed.
6. **Ingestion monitoring is on only where a probe token is configured** (staging and production require one). Where it is off (local development) the ingestion trigger does not exist; the anomaly and operator triggers do.
7. **A stuck `sending` row** (a dispatcher that died between tx A and tx B) is returned to the queue after 5 minutes and re-checked like any other message; the provider's idempotency key is the notification id.
8. **Check-in with an `incident_open` configuration and no incident row** is accepted and repairs the schedule (the person is never locked out); the worker raises FS-25 for the opposite inconsistency.
9. **Releases** are a seam (`app/engine/releases.py`): the snapshot, the final warning (60 min before a releasing stage), G9 and, since the review (F-17), **G8** are implemented and tested with a stand-in. G8 is evaluated per release in `ActionExecutor._stage`: a release that fails is skipped and recorded in the action's `outcome.releases`, and its contact is told only if the stage lists them to be notified (INV-7). Phase 6 supplies the real source and creates the release events there. (Until the review, `still_valid` was never called and this note claimed it was.)

*Changes made after the independent review (§13.2), each tested in `tests/engine/test_review_findings.py`:*
10. **A void restarts the schedule** (F-01), see FS-13. It sets no `last_checkin_at`: a void is not evidence that the person is fine.
11. **Unknown Hold state is a Hold** (F-02). If `hold.evaluate` raises, the tick opens no incident, leaves contact-facing stages pending (`force_hold`), and the worker tells the dispatcher not to send escalation messages or the "has been notified" summary that cycle; user reminders go on. A `hold_monitor` heartbeat that goes stale while the engine's does not is paged.
12. **The dispatcher does not trust a notification row** (F-04). In tx A it re-derives the recipient from the incident's own snapshot and the action's `step_id`, requires the template to be one the engine writes, the dedupe key to carry the action id, `executed_at + SETTLE <= now` and G3, and leaves a row that is too early queued. Migration `0005` adds triggers so that `afterme_api` can only enqueue non-escalation `queued` rows, only `queued → cancelled` on notifications, `pending → cancelled` on actions and *open → closed* on incidents, and takes DML on the plan tables and DELETE on incidents, actions and notifications from the worker.
13. **The summary "Mom has been notified" is only true together with the alert** (F-08): it waits while a Hold is open (or its state is unknown) and is cancelled when the incident closes before any contact was messaged, whoever closed it.
14. **The all-clear audience** (F-09) is every contact whose message was handed to a provider *or attempted with an unclear outcome* (a timeout leaves `queued` with `attempt_count > 0`, or `failed`): the provider may have delivered it. A contact whose message was never attempted is told nothing.
15. **Rollback reaches back one settle delay** (F-10): a stage that ran up to `SETTLE_DELAY` before the outage began is still undelivered when it is detected and is taken back with the window. A window is applied only to incidents that were open at some point before it ended, so a window found late in the probe history cannot shift an incident that opened after it.
16. **Giving up is visible and counted from the first attempt** (F-11): a message that waited out a Hold no longer fails for good on its first transient error, and `failed` rows page.
17. **Infrastructure errors do not count towards `held`** (F-13) (connection loss, lock timeouts, OS and timeout errors); `python -m cli.admin action retry <id>` puts a held action back after an operator has looked at it. `held` pages only for open incidents.
18. **Paging** (F-14): opening, executing and reminding take up to 10 pages of 200 users per tick, skipping users already seen this tick, so rows that cannot be opened (no plan, inconsistent) never starve those behind them; a full last page makes the worker go straight into the next cycle instead of sleeping.
19. **Hold decisions are serialised** (F-06) by one advisory lock, so two workers cannot both enter, or record the same window of, a Hold; entering an operator Hold twice is one Hold; an operator exit is not followed by re-entry over the incidents that Hold already covered (F-05b, only incidents opened since the last anomaly Hold ended count).
20. **`contacts_messaged_at` is set only once a message was actually built** (a row that cannot be built is cancelled and leaves the incident saying nobody was told), and **`SETTLE_DELAY_SECONDS` must exceed `INGESTION_STALE_SECONDS` plus two ticks** (the old rule allowed a margin of zero).
21. **Late stages are put back, not run** (F-03, §6.7), with their own message `incident_delayed` (new copy: USER_FLOWS §13.1). The final warning's "stage at" is now the stage action's real time, not `anchor + offset`, which a Hold or this shift may have moved.
22. **A fresh password is needed to weaken a safety net that is on** (F-12): `PUT /v1/plan` when the schedule is `active` and the plan changes; `DELETE /contacts/{id}` and `PATCH` that deactivates or changes the email of a contact **who is in a plan stage**, while the schedule is not `inactive`. Changing a contact's email is included because it re-points an alert (and a thief controls the new inbox).
23. **The anomaly threshold follows people and the hour** (F-05a, §7.2), and the Home screen shows a persistent banner when check-ins are on but nobody would be told (USER_FLOWS §4).

*Observability.* `python -m cli.admin status` prints the §12 table as one snapshot and exits `1` when anything would page (stale heartbeat, Hold active or not evaluable, held actions of open incidents, messages given up on, consistency violations, an action due or a message queued for more than 5 minutes). Structured events: `incident.opened`, `engine.action_held`, `engine.unit_failed`, `engine.consistency_violation`, `system.hold_entered`, `dispatch.failed`; none carries a name, an address or a token.

### 13.2 Independent review of the engine (Phase 5)

An adversarial review read the engine, the migration, the API surface and the tests without running anything; each finding below was then checked against the code by the author before it was fixed or dispositioned (F-15 by reasoning about the session's identity map, not by a test). Nothing was found in the core path (check-in vs stage vs dispatcher tx A, `SKIP LOCKED`, the settle delay, G1–G7, Hold rollback and shift); the defects were at its edges.

| ID | Sev. | Finding | Disposition |
|---|---|---|---|
| F-01 | S1 missed alert | `incident void` left the schedule `incident_open` with no incident: nobody watched that person again | **Fixed** (note 10) |
| F-02 | S2 wrongful contact | A failing Hold evaluation was logged and the tick went on to execute stages | **Fixed** (note 11) |
| F-03 | S2 wrongful contact | After a worker outage an overdue stage runs with no warning to the person, who also got no reminders (FS-08 said "runs late, correct") | **Fixed** by owner decision (§6.7, note 21) |
| F-04 | S2 defence in depth | API role could forge a `contact_escalation` row, or reopen a closed incident; the dispatcher believed the row | **Fixed** (note 12) |
| F-05 | S3 | (a) a daily spike makes p95 = 0, so the floor is the threshold: a large user base trips it nightly; (b) re-entry after an operator exit | **Fixed** (b: note 19; a: by owner decision, §7.2, note 23) |
| F-06 | S3 | two workers could both enter, or both record, a Hold; shift applied twice | **Fixed** (note 19) |
| F-07 | S3 | during a Hold more than 100 queued alerts starved every other message | **Fixed** |
| F-08 | S3 | "Mom has been notified" sent when the incident was closed inside the settle delay | **Fixed** (note 13); also found: the summary ignored Hold |
| F-09 | S3 | a contact whose message may have been delivered (ambiguous error) got no all-clear | **Fixed** (note 14) |
| F-10 | S3 | a stage inside its settle delay when an outage began was not rolled back | **Fixed** (note 15) |
| F-11 | S3 | giving up after 24 h was silent; measured from creation | **Fixed** (note 16). The person is still not told that a contact message failed: needs a new template (Phase 8, with real providers) |
| F-12 | S3 security | step-up re-auth is required to deactivate or lengthen the interval, but not to edit the plan, deactivate a contact or delete one: a stolen 15-minute token can neutralise escalation | **Fixed** by owner decision (note 22) |
| F-13 | S3 | five failed ticks (75 s of database flapping) held a stage for ever, and there was no un-hold | **Fixed** (note 17) |
| F-14 | S3 | batches of 200 with no paging, and a fixed sleep | **Fixed** (note 18) |
| F-15 | — | "read skew in tx A" on the contact | **Not a defect**: both reads go through one session's identity map, so the second sees the first's values; taking `FOR SHARE` would add a lock-order inversion with the contact paths, so it was deliberately not added |
| F-16 | S3 | the probe route is rate limited per IP *before* the token check | **Documented**: only matters if the monitor shares an address with hostile clients; see DEPLOYMENT |
| F-17 | S3 | G8 was never called; this document claimed it was | **Fixed** (note 9) |

*Owner decisions (taken 2026-10-10: "do the needful using your research and best understanding")*

1. **F-03** was implemented as recommended (§6.7). Two choices were left to the implementer and are worth a second look: the tolerance is 5 minutes (a busy worker is two ticks, a restart a few minutes), and the person gets a new message `incident_delayed` rather than a re-send of "in 15 minutes" (which would be false).
2. **F-12** was implemented for plan edits, contact deactivation and deletion, **and contact email change** (a thief who re-points Mom's address and verifies it from their own inbox receives the alerts), each only where it weakens a live safety net.
3. **F-05a** was implemented as a seasonal baseline plus fractions of the active users (§7.2). The fractions are constants chosen without data; **review them against the first weeks of real data** (`afterme-admin status` shows `incidents_opened_last_hour`).
4. **The Home gap banner**: shown for check-ins on with no live contact, no stage, or only stages that tell no one (mobile; the server already reported it).

*Known limits that remain*

* One user whose Hold-exit processing keeps raising leaves the Hold unprocessed (fail-safe, but nobody's alerts go out until it is looked at: it pages as *Hold active*).
* The Hold notice is email only (push copy exists).
* The stateful simulation moves the clock tick by tick through every due instant, except for its `outage` step (hours with no tick), which is what lets it check that no stage runs late. It also includes operator voids.

## 14. Worked example (the T0–T8 lifecycle)

User: Asia/Kolkata, every 1 day by 20:00. Plan: grace 3 h; stage 1 (+3 h) notify **Mom**; stage 2 (+24 h) notify **Brother** and release **"House emergency"** to Brother.

| T | Time (IST) | Event | System state / effects |
|---|---|---|---|
| T0 | Day 1 19:30 | I'M OK | Event recorded; `next_due_at` = Day 2 20:00 |
| — | Day 2 19:00 | Pre-deadline reminder | Push to user |
| T1 | Day 2 20:00 | Deadline passes | Next tick: incident opened (`grace`), anchor 20:00; timeline materialised; `missed` reminder (push + email) |
| T2 | Day 2 21:30 / 22:45 | Midpoint / last-chance reminders | Push (+ email) |
| T3 | Day 2 23:00 | Grace ends; stage 1 | Status `escalating`; Mom message queued (`send_after` 23:05) |
| T4 | Day 2 23:05 | Dispatch | Mom emailed (alert, no content); `contacts_messaged_at` set; user told "Mom has been notified" |
| — | Day 3 19:00 | Final warning | User: "In 1 hour, 1 instruction will be shared with Brother" |
| T5 | Day 3 20:00 | Stage 2 | Release event + portal access; Brother message at 20:05; status `escalated` |
| — | Day 3 20:20 | Brother views | OTP to Brother's verified email → views; `release.viewed` audited |
| T6 | Day 3 21:00 | User returns, taps I'M OK | `409 safe_required` → app shows the I'M SAFE flow |
| T7 | Day 3 21:01 | Re-auth + I'M SAFE | Incident `cancelled`; releases revoked (portal now says "no longer available"); all-clear queued to Mom and Brother; `next_due_at` = Day 4 20:00 |
| T8 | Day 3 → Day 10 | Time advances (ticks) | **No** further contact-facing actions for the incident. A new incident only if the user misses Day 4 20:00. |

Variant (must also be tested): the user checks in at Day 2 22:00 (in grace) → `resolved`; zero contact messages ever created or sent.
