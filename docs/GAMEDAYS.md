# AfterMe — Game days OPS-01 to OPS-05

| | |
|---|---|
| **Status** | Phase 10. The three operational game days of [TEST_PLAN §7](TEST_PLAN.md#7-end-to-end-and-operational-tests-staging), as a procedure for the owner in staging, plus the local rehearsal that was run first |
| **Related** | [ESCALATION_ENGINE §7, §8, §12](ESCALATION_ENGINE.md) · [DEPLOYMENT §9](DEPLOYMENT.md#9-runbooks) · [TEST_PLAN §12](TEST_PLAN.md#12-release-acceptance-criteria) (game days are a closed-beta gate) |

> **Commands.** There is no `afterme-admin` executable. Wherever this document says the operator's command it means `python -m cli.admin <command>` run from `backend/` (equivalently `make admin ARGS="<command>"`, or the same `python -m cli.admin` inside the container image). The commands below are written in that form.

**Why.** Every guarantee of the engine under failure ("an alert never arrives" and "an alert arrives wrongly") was tested in-process with a frozen clock. Nothing had been rehearsed against the real processes. A game day proves three things the unit tests cannot: that the **operator sees** what the runbook says they will see, that the **real worker and API processes** behave like the in-process engine, and that the **people on call** get paged.

**Two layers.**

1. **The local rehearsal** (`make gameday`, run by the build; below in [§1](#1-the-local-rehearsal)). The real API (uvicorn) and the real worker (`python -m workers.engine`) on a throwaway database, with the test clock, and no providers. It finds defects in the product and in the runbook cheaply, and prints the excerpts the runbook is written from. Run it again after any change to the engine, the dispatcher or the operator commands.
2. **The staging game days** (this document, [§3](#3-ops-01-ingress-outage) to [§5](#5-ops-03-invalid-email-provider-credentials)), run by the owner, in real time, with real providers, a real uptime check and a real pager. This is the closed-beta gate.

> **The one rule.** A game day uses **test accounts with the owner's own mailboxes**, never a real person's account. Everything below that moves a deadline or breaks a secret does so in **staging**, which holds no real data (DEPLOYMENT §1). Each section ends with how to put things back and how to stop.

---

## 1. The local rehearsal

```bash
cd backend
make gameday                         # all three, about five minutes
make gameday ARGS="--only ops-02"    # one scenario (ops-01, ops-02, ops-03)
```

It needs the `.venv` (`make setup`) and a local PostgreSQL that `psql -d postgres` reaches as a superuser (the Homebrew default). It creates **only** `afterme_gameday` (dropped and recreated for every scenario with the hardening of `scripts/dev_db_setup.sh`, and migrated as `afterme_owner` as `mobile/tool/integration.sh` does; unlike the script it changes **no role**, so the roles must exist, from `make setup`). The `DROP DATABASE` and `CREATE DATABASE` statements go to an explicit `localhost`, port and OS user that the harness derived, ignoring `PG*` and `AFTERME_*` from the shell, and a database host that is not this machine is refused. It starts the API on the first free port from 8010 and the worker against it, with test support on (one shared random token), rate limits off and a one-second worker tick, moves time with `POST /test/clock/advance`, and stops everything it started (also on Ctrl-C; a record of each child's PID, start time and full command line lets the next run stop what a killed run left behind, and only a process that still matches all three; a run that is still alive is refused, never reaped). It never touches `afterme_dev`, `afterme_test` or `afterme_it`, and `APP_ENV=test` keeps `backend/.env` out of the processes.

It prints the narrative, a "what the operator would see" excerpt per scenario (these are what the runbook shows), and a PASS / FAIL table. The exit status is `0` only when every check passes. A check that asserts something a design document promises and fails prints **`FAIL (defect)`** and is listed with the promise, the expected and the actual value: the product does not do what its documents say.

What the rehearsal places in the database, and why (so that nobody reads more into a PASS than it says):

* a contact's **acceptance** is an `UPDATE` (the invitation pages are covered by the Android suite);
* a **60-minute grace** (a custom time) makes the OPS-01 accounts premium with one `UPDATE users SET tier`, as `user set-tier` would;
* a **deadline** is placed with one `UPDATE checkin_configurations SET next_due_at` (as `backend/README.md` describes for trying a miss quickly): the API cannot set it and the 12-hour minimum window would cost twelve simulated hours of probes.

Everything else is the real API (sign-up with the mailed code, contacts, plan, schedule, activation, I'M OK) and the real worker.

**What it cannot prove, and staging must:** real providers (SPF/DKIM/DMARC, webhooks, a real 401 from Resend, real latency), a real uptime check calling the public ingress, the pager (a Hold, a heartbeat, a backlog actually reaching a phone), the platform restarting a crashed worker, two worker replicas at once, real database failover, NTP and clock skew (the test clock is the database clock plus an offset), and anything that depends on real time passing (tokens expiring, certificates, the 24-hour give-up).

---

## 2. Before any game day

**Preconditions (all three).**

* Staging runs the release candidate (API and at least one worker), `python -m cli.admin status` exits `0`, and `PROBE_TOKEN` is set with the uptime check calling `POST /internal/probe` every 60 s through the public domain (DEPLOYMENT §3).
* **`TEST_SUPPORT_*` is off.** Configuration refuses it with a real email provider, so nothing below can use the test clock: every game day runs in real time (the shortest escalation is a 60-minute grace, `grace_minutes` has a database floor of 60).
* Real providers: a primary and a different fallback, both reachable, `python -m cli.admin email-test --to <you>` prints `ok: provider=…`.
* The on-call phone receives pages from the monitoring service. Tell whoever else is paged that a game day is running.
* **Test accounts**, created through the app or the API, each with **one contact whose mailbox you read**, a one-stage plan, a daily schedule, activated. The shortest plan needs a 60-minute grace, which is a custom time: `python -m cli.admin user set-tier <user-id> premium --reason "game day"` for the test account (and `free` again afterwards).
* Placing a deadline needs the database: `UPDATE checkin_configurations SET next_due_at = now() + interval '2 minutes' WHERE user_id = '…';` as the migration or a read-write operator role, **for test accounts only**.

**The operator's four commands** (they run as the worker role and read the database, so they work while the API or the workers are down):

```bash
python -m cli.admin status            # exit 1 when anything would page; JSON with pages[] and warnings[]
python -m cli.admin hold status       # hold_active, hold_reasons, hold_exit_pending
python -m cli.admin hold enter --reason "game day abort"     # freeze every contact-facing effect
python -m cli.admin incident void <incident-id>               # close a test incident (audited)
```

**Stop criteria (all three).** If a message reaches a mailbox that is not yours, or any real account shows an incident: `python -m cli.admin hold enter --reason "game day abort"`, then stop and treat it as an S1.

**Time zone of the examples.** Times are relative to `T0`, the moment the test account's incident opens; `L` is the last good probe.

---

## 3. OPS-01 Ingress outage

**Purpose.** When the probe path stops, the worker must enter a Hold backdated to the last good probe; nothing may reach a contact during it; user reminders must continue; when probes are back the Hold must end by itself and move every deadline by the Hold's length plus 30 minutes, so that nobody is alerted wrongly; and a later miss must still escalate (ESCALATION_ENGINE §7, FS-09; DEPLOYMENT §9 "Hold entered (ingestion)").

**Accounts.**

The timeline is the local rehearsal's, in real time: it is a **two-hour** game day because the shortest escalation has a 60-minute grace. `T0` is the moment B's incident opens, `L = T0 + 59 min` is the last good probe, so that B's stage (`T0 + 60 min`) runs **in the undetected window**, which is the case that matters most.

| Account | Setup (deadlines placed with the `UPDATE` of §2) | Role in the test |
|---|---|---|
| **B** | deadline `T0 - 15 s`, grace 60; stage due `T0 + 60 min` | incident open; its stage runs before the Hold is known, is rolled back, then shifted |
| **A** | deadline `L + 8 min` (`T0 + 67`) | falls in the middle of the outage while nobody can reach the API |
| **R** | deadline `L + 40 min`, reminder lead 30 min | its pre-deadline reminder falls inside the Hold (`L + 10 min`) |
| **B2** *(optional)* | as B | taps I'M OK at `L + 5 min` while the API is up: "the monitor path is what is down" |
| **A2** *(optional)* | deadline `L + 6 min` | taps I'M OK at `L + 7 min`, after its deadline passed inside the Hold |

**Steps.**

1. From `T0` B's incident is open (`python -m cli.admin status`: `incidents_open: 1`) and probes arrive every minute (`SELECT count(*) FROM ingestion_probes` rises). `status` exits `0`.
2. At `L = T0 + 59 min` **stop the probes**: pause the Cloud Monitoring uptime check that calls `POST /internal/probe`.
3. About **3 to 4 minutes** after `L`, run `python -m cli.admin status` and `python -m cli.admin hold status`.
4. B2 and A2 (if used) tap I'M OK at `L + 5` and `L + 7`: `200`, and for B2 `incident_resolved: true`.
5. At `L + 7 min`, **deny traffic to the API** at the load balancer (the ingress itself; now nobody can check in). The local rehearsal does the same: the monitor path from minute 0, the API from minute 7.
6. At `L + 8 min` A's deadline passes; at `L + 10 min` R's reminder email arrives (user messages go on). `SELECT * FROM escalation_incidents WHERE user_id = '<A>'` must be empty.
7. At `L + 15 min` **restore the ingress and resume the probes**.
8. Watch `python -m cli.admin hold status` until `hold_active` is `false` and `hold_exit_pending` is `0`. Note the time: the Hold must end **about ten minutes** after the first fresh probe (`HOLD_EXIT_FRESH_SECONDS` = 600), not sooner.
9. Check the audit trail and the shift (SQL below), then wait for B's shifted stage.

```sql
-- the Hold and its exit
SELECT reason, started_at, detected_at, ended_at, exit_processed_at FROM system_holds ORDER BY started_at;
SELECT action, occurred_at, metadata FROM audit_logs WHERE action LIKE 'system.hold_%' ORDER BY id;
-- B's stage moved by the Hold's length + 30 minutes, A's incident opened after the exit
SELECT scheduled_for, original_scheduled_for, status FROM incident_actions WHERE user_id = '<B>' AND kind = 'execute_stage';
SELECT status, opened_at, anchor_at, grace_ends_at FROM escalation_incidents WHERE user_id = '<A>';
```

**What to observe.**

* **Within ~4 minutes of the last probe:** `python -m cli.admin status` exits `1` with `pages: ["hold active"]`; `hold status` shows `hold_reasons: ["ingestion"]`; the pager fires; `system_holds.started_at` equals the last probe (backdated).
* **During the Hold:** no `contact_alert` in any contact mailbox; A has no incident although its deadline passed; R's reminder arrives.
* **After the probes resume:** the Hold ends without an operator; `system.hold_exited` is audited once with `{users, rolled_back, shifted}`; B gets a `service_interruption` email ("Please check in"); B's stage action is `pending` with `scheduled_for = original_scheduled_for + (ended_at - started_at) + 30 min`; A's incident opens **after** the exit with `anchor_at = opened_at` and a full grace.
* **Later:** B's shifted stage runs on time and its contact gets **one** alert about five minutes after (the settle delay).

**Pass criteria.** All of the above, and: no contact message left during the Hold; A2's, B2's and R's contacts received nothing and A's alert left no earlier than its full grace after the Hold; `python -m cli.admin status` exits `0` with no page at the end. A Hold that never exits or exits before ten minutes of fresh probes, an incident opened for A during the Hold, a contact alert that arrives before B's shifted time, or an alert sent twice fails the game day.

**Restore.** Resume the uptime check and (if used) the ingress. Close the test incidents: `python -m cli.admin incident void <id>` for A's and B's, or check in (I'M OK before a contact was messaged; I'M SAFE with re-authentication after). Deactivate the schedules; `python -m cli.admin user set-tier <id> free --reason "game day over"`.

**Roll back / abort.** `python -m cli.admin hold enter --reason "game day abort"` freezes contact-facing effects at once; `python -m cli.admin hold exit` ends it (the engine then rolls back and shifts as for any Hold). Resume the probe path first; if a Hold is open because of the probes, it ends by itself.

**What the local rehearsal found** (`make gameday`, OPS-01; times simulated):

* The worker entered the Hold about **3 minutes 25 seconds** after the last good probe (203 to 206 s over several runs), backdated to it **exactly** (`started_at = L`), and `status` paged `hold active`. A stage that fell due one minute after `L` ran **before** the Hold was known; once its alert was past its `send_after` with the Hold open it was still `queued` and no mail existed. At exit it was rolled back (`rolled_back: 1`, the message `cancelled` with `hold_rollback`) and moved by **window + 30 minutes** (56 minutes for a 26-minute window), `shifted: 1`.
* **A deadline that passed inside the Hold opened no incident**, and a person who then tapped I'M OK (the Hold had kept the incident from opening) was accepted with no incident at all. A person whose incident was open and who tapped I'M OK while the monitor path was down was resolved quietly: the queued alert was cancelled and nothing was sent.
* **After the exit, the incident of the person whose deadline passed opened at the exit tick with a full grace period** (`anchor_at = opened_at`); that person's alert left **67 minutes** after the anchor (grace 60 + settle 5, plus one step), not 14 minutes earlier as it would have if the missed deadline had been the anchor. The shifted stage of the other ran on time and sent **one** alert. Read over every contact mailbox and every template after both alerts were due, nobody else's contact received anything beyond its invitation, and every sent outbox row matched exactly one mail by its provider message id.
* The Hold ended **10.3 minutes** after the first fresh probe (a step of one simulated minute); the exit time follows `HOLD_EXIT_FRESH_SECONDS`. (The first rehearsal found 7.2 minutes: the fresh-probe test accepted a stale gap at the start of its window. That was fixed in `HoldMonitor._auto_exit` and this check, OPS-01.9b, guards it.)
* **Operational note (from reading the code, not rehearsed):** the first tick of a worker that has monitoring on and has **never seen a probe** enters a Hold at once (`_ingestion_trigger`: no probe means no proof), which also shifts every open incident by that Hold plus 30 minutes. When enabling `PROBE_TOKEN` on a running system, send the first probe before the workers start (the rehearsal does).

---

## 4. OPS-02 All workers killed for 30 minutes

**Purpose.** With no worker running nothing may happen; the heartbeat must page; at the restart the engine must give everybody a full grace period (anchor rule), put back a stage that is more than 5 minutes late and warn the person with the real time, run a stage that is only slightly late, and send nothing twice (ESCALATION_ENGINE §5.2, §6.7, FS-08; DEPLOYMENT §9 "Worker down").

**Accounts** (relative to `K`, the moment the workers are stopped; with a 60-minute grace, U1's deadline is placed at `K - 55 min` and U2's at `K - 32 min`, so that both incidents are open and their stages fall at the times below; U3's deadline at `K + 15 min`):

| Account | Setup | Expected at the restart (`K + 30 min`) |
|---|---|---|
| **U1** | Incident open, stage 1 due at `K + 5 min` | 25 minutes late: **not run**, put back to restart + 30 min, `incident_delayed` sent |
| **U2** | Incident open, stage 1 due at `K + 28 min` | about 2 minutes late (**within 5 minutes**): runs as usual |
| **U3** | Deadline at `K + 15 min` | Incident opens at the restart, `anchor_at = opened_at`, full grace |

**Steps.**

1. Healthy: `python -m cli.admin status` exits `0`, heartbeat age under 2 minutes. Note the counts: `SELECT count(*) FROM escalation_incidents; SELECT count(*) FROM notifications;`.
2. **Stop every worker** (scale the worker service to zero; leave the API up). Note the time `K`.
3. About 3 minutes later: `python -m cli.admin status` exits `1` with `worker heartbeat older than 2 minutes`; the pager fires.
4. At `K + 30 min` check that nothing happened: the counts of step 1 are unchanged, no incident for U3, no `contact_alert`. `status` also pages `due action not executed for 5 minutes` (U1's stage).
5. **Start the workers** as quickly as you can (U2's lateness depends on it: a restart that takes more than 5 minutes after `K + 28 min` defers U2's stage too, which is also correct; record which happened).
6. Within a minute: `python -m cli.admin status` exits `0` again; run the SQL below and read U1's mailbox.

```sql
SELECT incident_id, status, scheduled_for, original_scheduled_for, executed_at FROM incident_actions
 WHERE kind = 'execute_stage' AND user_id IN ('<U1>','<U2>','<U3>');
SELECT user_id, opened_at, anchor_at, missed_due_at, grace_ends_at FROM escalation_incidents WHERE user_id = '<U3>';
SELECT action, occurred_at, metadata FROM audit_logs WHERE action = 'escalation.stage_deferred';
SELECT dedupe_key, count(*) FROM notifications GROUP BY 1 HAVING count(*) > 1;   -- must be empty
```

**What to observe / pass criteria.**

* While down: heartbeat page after 2 minutes; nothing else changes; the API keeps answering.
* U3: incident opened at the restart, `anchor_at = opened_at` (**not** the missed deadline), `grace_ends_at = anchor_at + grace`, its stage still `pending`.
* U1: stage `pending` at restart + 30 minutes (`scheduled_for - original_scheduled_for` = how late + 30 min), `escalation.stage_deferred` with `late_seconds` over 300, **one** `incident_delayed` email stating the real time, and later **one** alert at the new time.
* U2: stage `executed`, its alert **once**, after the settle delay; its last reminder, which fell due while down, is `cancelled` (`superseded`), not sent late.
* No dedupe key twice; no mail twice; no `held` action; `status` exits `0`.

**Restore.** Close the test incidents (`incident void`), deactivate the schedules, leave the workers running.

**Roll back / abort.** If anything contact-facing looks wrong after the restart: `python -m cli.admin hold enter --reason "game day abort"` before touching anything else.

**What the local rehearsal found** (`make gameday`, OPS-02; times simulated): every check passed. The heartbeat page was raised at **185 seconds** (the threshold is 120 s, the check runs when an operator looks); after 30 minutes `status` listed both `worker heartbeat older than 2 minutes` and `due action not executed for 5 minutes`; nothing was created while the workers were down. At the restart U3's incident opened **1 to 3 seconds** after the worker started, about 15 minutes after the deadline, with a full 180-minute grace; U1's stage was put back **55 minutes** (`late_seconds` 1510 to 1524, `shift_minutes: 55`: 25 late plus the 30-minute shift) with one `incident_delayed`; U2's stage ran **about 2 minutes late** (110 to 123 s) and was not deferred. Every dedupe key occurred once and the outbox's `sent` rows equalled the mails recorded, per recipient and template.

---

## 5. OPS-03 Invalid email-provider credentials

**Purpose.** A provider that refuses our credentials is our fault, never a verdict on the contact. The message must go by the fallback provider; when both refuse it must stay queued with backoff (not fail), the backlog must page, and when the credentials are fixed it must drain with one send per message (ESCALATION_ENGINE §8.3; DEPLOYMENT §9 "Email provider outage", "Provider credentials invalid").

**Accounts.** One test account **P** whose alert is due (as B in OPS-01: deadline `now + 2 min`, grace 60, stage at `T0 + 60 min`), and a second **P2** whose stage falls due at `T0 + 90 min` (so that a second message is queued while both providers are down).

**Steps.**

1. **Break the primary only.** In the secret manager set `EMAIL_API_KEY` to an invalid value and restart the workers (and the API: it sends the sign-up and reset mails through the same chain).
2. `python -m cli.admin email-test --to <you>` must print `ok: provider=<fallback> message_id=…` (the chain fell back).
3. When P's stage runs (`T0 + 60 min`) and its settle delay (5 minutes) passes, the contact alert must arrive **from the fallback provider**.
4. `python -m cli.admin status`: `warnings` contains `the fallback email provider is carrying messages`; `fallback_sends_15m` is above 0; nothing pages.
5. **Break the fallback too** (invalid fallback key), restart the workers. When P2's alert falls due it must **not** arrive. Once `send_after` is more than 5 minutes past, `python -m cli.admin status` exits `1` with `queued message past send_after for 5 minutes`; `warnings` adds `provider error rate above 5% in the last 15 minutes` as soon as five attempts have been logged in the window (one message alone needs about 15 minutes of retries to get there); `failed_messages_7d` stays `0`.
6. **Fix both secrets**, restart the workers. The queued alert is sent at its next retry (the backoff is 1, 2, 4, 8 minutes) and arrives **once**; `status` exits `0`.

```sql
SELECT id, template_key, status, attempt_count, next_attempt_at, provider FROM notifications
 WHERE template_key = 'contact_alert' ORDER BY created_at;
SELECT outcome, error_code, count(*) FROM notification_logs GROUP BY 1, 2;
SELECT verification_status FROM trusted_contacts WHERE id IN ('<P contact>','<P2 contact>');   -- verified
```

**Pass criteria.** The contact stays `verified` (a rejected credential is never read as a bounce); P's alert arrives once by the fallback; P2's stays `queued` with `attempt_count` rising and `next_attempt_at` set, never `failed`; the backlog page appears within ~6 minutes of `send_after`; after the fix each message arrives exactly once and `status` exits `0`. The 24-hour give-up is not rehearsed (it needs 24 hours); it is covered by the engine's tests.

**Restore.** Both secrets valid, workers and API restarted, `python -m cli.admin email-test --to <you>` prints `ok: provider=<primary>`. Close the test incidents.

**Roll back / abort.** If a contact alert for a real address could leave: `python -m cli.admin hold enter --reason "game day abort"`.

**What the local rehearsal found** (`make gameday`, OPS-03; the real `Engine` and `Dispatcher` in-process against an `httpx.MockTransport`, because a worker subprocess cannot take an injected transport): every check passed.

* Both adapters answered **`ProviderUnavailableError`** with the codes the runbook lists (`resend_401`, `postmark_10`); the chain logged `email.provider_failed provider=resend error_class=ProviderUnavailableError code=resend_401`; the contact stayed `verified` and no `contact.bounced` was written.
* With only Resend rejecting, the alert was delivered by **Postmark**, accepted once; after the second failure Resend was **skipped for 60 seconds** (no call, one Postmark call), and asked again after 61.
* With both rejecting, the two queued alerts stayed `queued` with `attempt_count` 4 after 7 minutes (backoff 1, 2, 4 minutes), `failed_messages_7d` 0, and `python -m cli.admin status` paged **`queued message past send_after for 5 minutes`** (`oldest_queued_message_age_seconds: 437`) with the 5% warning.
* After the fix both were sent **exactly once** and no page remained. The 5% warning stays for the next 15 minutes by design (it counts the last 15 minutes).
* **Note for the runbook.** While the fallback is carrying everything, `provider_errors_15m` is **`0`**: the chain hides the primary's failures (only the message's final outcome is logged), so the signal is the warning and `fallback_sends_15m`, not `provider_errors_15m`. DEPLOYMENT §9 lists all three; read it as "the error count rises when both fail".

---

## 6. Recording a game day

After each staging game day, record in the beta log (a spreadsheet, BETA_PLAN §7): the date, the release, who ran it, the observed numbers (detection time, exit time, shift, deferral, backlog age), anything that differed from this page, and the pass or fail. The closed-beta gate (TEST_PLAN §12) needs OPS-01, OPS-02 and OPS-03 **passed in staging**; a failure is fixed and the game day repeated.

---

## 7. OPS-04 Database failover under load

**Purpose.** Prove what [INFRASTRUCTURE §12](INFRASTRUCTURE.md#12-disaster-recovery) promises for a zone failure: the regional high-availability instance fails over to its standby in about a minute with no data loss (RPO 0); the API and the worker reconnect **without a restart**; while the database is away nothing leaves for a contact (the engine cannot read the state, so it treats it as a Hold) and no message is sent twice afterwards; the pager fires for what is worth a page; and an outage that lasts longer than the probe's stale limit (3 minutes) becomes a recorded Hold window that is shifted correctly (ESCALATION_ENGINE §7.2, §6; DEPLOYMENT §9 "Hold entered (ingestion)").

**Preconditions.**

* All of §2, with the release candidate running in **staging**.
* **Staging must have a standby.** Staging is single-zone by default. For the game day set `db_high_availability = true` in `infra/terraform/envs/staging/terraform.tfvars`, `terraform apply` (the conversion takes 10 to 30 minutes and briefly restarts the database), and wait until `gcloud sql instances describe afterme-pg-staging --project <staging> --format='value(settings.availabilityType)'` prints `REGIONAL`. Set it back to `false` afterwards. (Repeat the failover on **production** once, before the first tester, while it is still empty; it is HA already.)
* The paging path works (the alert test of `infra/README.md` step 12 was done) and the other on-call person knows the game day is running.
* Two test accounts, as in OPS-01 (each with one contact whose mailbox you read): **R**, a reminder that falls due during the failover: set `UPDATE checkin_configurations SET next_due_at = now() + interval '30 minutes 40 seconds' WHERE user_id = '<R>';` about 30 seconds before you trigger the failover (the reminder lead is 30 minutes, so the reminder is due at the moment of the failover); and **B**, as in OPS-01: an incident already open with its 60-minute stage due **at least 30 minutes after** the failover (so you can see that nothing early or twice leaves).
* The load: `infra/scripts/load_ready.sh https://api.staging.afterme.app 900` in a terminal (a database query ten times a second; prints a line a second). Optionally also check in from a test phone every minute.

**Steps.**

1. Healthy baseline: `python -m cli.admin status` exits 0 (job **afterme-oncall-status**); note `gcloud sql operations list --instance afterme-pg-staging --project <staging> --limit 3`; note the counts `SELECT count(*) FROM notifications; SELECT count(*) FROM audit_logs;`. Start the load script.
2. Note the time `F`, then trigger the failover:
   ```bash
   gcloud sql instances failover afterme-pg-staging --project afterme-staging
   ```
   (The command returns when the operation is accepted; the failover itself takes about a minute.)
3. Watch the load script: a run of `503=…` lines, then `ok=10` again. Note the length of the run: **U**, the unavailable time.
4. Watch the engine: `python -m cli.admin status` (job **afterme-oncall-status**) every minute; the worker logs (`worker.tick_failed`, `engine.hold_failed`), the uptime check, the dashboard.
5. When the database is back (`gcloud sql instances describe … --format='value(state)'` is `RUNNABLE` and the load script is green) wait **10 more minutes**, then run `status` again and read R's mailbox and B's timeline:
   ```sql
   SELECT reason, started_at, ended_at, exit_processed_at FROM system_holds ORDER BY started_at DESC LIMIT 3;
   SELECT dedupe_key, count(*) FROM notifications GROUP BY 1 HAVING count(*) > 1;   -- must be empty
   SELECT scheduled_for, original_scheduled_for, status FROM incident_actions WHERE user_id = '<B>' AND kind = 'execute_stage';
   ```
6. Record the operation's own numbers: `gcloud sql operations list --instance afterme-pg-staging --project <staging> --limit 5` (type `FAILOVER`, start and end).

**What to observe.**

* **U ≤ 120 seconds** (the usual figure for a regional failover is 60 to 120; a figure over 180 seconds is a finding even if everything else passes).
* The API and the worker recover **without a restart or a redeploy** (new revisions or restarts would show in `gcloud run revisions list`). The first requests after the failover may be `503`; none after the load script goes green.
* While the database was away, nothing was sent to any contact (no `contact_alert` in any contact mailbox; `notifications` rows with `audience = 'contact'` unchanged).
* **Paging.** For an outage under 3 minutes: the watchdog job fails (`afterme-status-check`), so **one** PAGE *engine status check reports a page* (or *database …*) may arrive; no Hold is expected. For an outage over 3 minutes: the ingestion Hold is expected (a `system.hold_window_recorded` / `system.hold_entered` page), and after 10 minutes of fresh probes it ends by itself with the shift applied to B's stage (`scheduled_for - original_scheduled_for` = Hold window + 30 minutes) and **one** *service interruption* mail to the affected accounts.
* R's reminder (a message **to the person**) is delivered **once**, late by about U, not lost and not repeated.
* `SELECT … HAVING count(*) > 1` is empty: no duplicate dedupe key, no mail twice.
* `RPO`: every row written before `F` is present (compare the counts of step 1 plus the writes you made; the check-ins from the test phone before `F` are in `GET /v1/checkins`).

**Pass criteria.** U ≤ 120 s; recovery without a restart; no contact message during or because of the failover; no duplicate; no data lost; any Hold that occurred ended by itself 10 minutes after fresh probes with the correct shift; `status` exits 0 within 15 minutes of recovery; the page(s) that fired were the expected ones and arrived on both phones within 5 minutes of the condition. A restart that was needed, a message to a contact, a duplicate, a lost write, or a page that never arrived fails the game day.

**Restore.** Set `db_high_availability` back to `false` in staging and apply (skip if you keep HA for the next drill). Close test incidents (`incident void`), deactivate the schedules.

**Roll back / abort.** Nothing to roll back: a failover cannot be undone and does not need to be. If anything contact-facing looks wrong: **afterme-oncall-hold-enter** (`python -m cli.admin hold enter --reason "game day abort"`) before touching anything else. If the instance does not return to `RUNNABLE` within 15 minutes, stop the game day and treat it as S1 (Cloud SQL support; DR in INFRASTRUCTURE §12).

---

## 8. OPS-05 Backup restore into a scratch instance, and the switch-over

**Purpose.** A backup that has never been restored is a hope. Prove that (a) a point-in-time clone of the production-shaped database comes up with the data, the schema at Alembic head, the roles and the grants; (b) the application runs correctly against it; (c) the **time to restore and switch** is inside the RTO (1 hour) and the newest recoverable data is inside the RPO (5 minutes); and (d) the procedure of DEPLOYMENT §9 "Database restore" (restore to a new instance, verify, **operator Hold**, switch, review, exit) works with the real commands. Quarterly (DEPLOYMENT §6).

**Preconditions.**

* Staging holds some data (the test accounts of the earlier game days). Staging is the environment where the **switch** is rehearsed; the production restore is rehearsed **up to and including (a)** (a clone of production, never switched to, deleted afterwards).
* The admin VM is up (`admin_vm_enabled = true`, `infra/README.md` step 6) and you can SSH to it through IAP, or you run `psql` from another host inside the VPC.
* You know the password of the `postgres` administrator (password manager). Nobody else is running a deploy.
* `python -m cli.admin status` exits 0.

**Steps.** (`<P>` = project, staging first; times in UTC.)

1. **Fingerprint the source** (on the admin VM; `$SRC` is the private IP of `afterme-pg-staging`, `$DB` is `afterme_staging`):
   ```bash
   export PGSSLMODE=require; read -r -s -p "postgres password: " PGPASSWORD; export PGPASSWORD
   psql -h $SRC -U postgres -d $DB -Atc "select version_num from alembic_version;
     select count(*) from users; select count(*) from escalation_incidents; select count(*) from notifications;
     select max(received_at) from ingestion_probes; select max(occurred_at) from audit_logs;"
   ```
   Note the output and the time `T_note`.
2. **Take a backup now and choose the restore point** (also proves on-demand backups work): 
   ```bash
   gcloud sql backups create --instance afterme-pg-staging --project <P> --description "OPS-05"
   gcloud sql backups list --instance afterme-pg-staging --project <P> --limit 5
   T=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S.000Z)      # on macOS: date -u -v-10M +%Y-%m-%dT%H:%M:%S.000Z
   ```
3. **Clone to a scratch instance** (start the stopwatch: `T_start`):
   ```bash
   gcloud sql instances clone afterme-pg-staging afterme-pg-staging-restore \
     --point-in-time "$T" --project <P> \
     --network projects/<P>/global/networks/afterme-vpc --allocated-ip-range-name afterme-private-services
   gcloud sql instances describe afterme-pg-staging-restore --project <P> --format='value(state,ipAddresses[0].ipAddress)'
   ```
   `<P>` for the network name is the project id; the clone must have a private IP only. Note `NEW` (its private IP) and the time the state is `RUNNABLE`.
4. **Verify the clone at SQL level** (admin VM, same commands as step 1 against `$NEW`, plus roles and grants):
   ```bash
   psql -h $NEW -U postgres -d $DB -Atc "select version_num from alembic_version; select count(*) from users;
     select max(received_at) from ingestion_probes; select max(occurred_at) from audit_logs;
     select rolname, rolcanlogin from pg_roles where rolname like 'afterme\\_%' order by 1;
     select has_table_privilege('afterme_worker','incident_actions','UPDATE'),
            has_table_privilege('afterme_api','incident_actions','INSERT');"
   ```
   Expected: the same Alembic revision; counts equal or lower than step 1 only by what was written after `T`; `max(...)` timestamps within **5 minutes before `T`** (the RPO check: the newest data in the clone is no older than the log archiving allows); the four login roles with `rolcanlogin = t` and `afterme_readonly` `f`; `true, false` for the two privilege checks (the worker may update actions, the API may not insert them).
5. **Switch-over rehearsal (staging only).**
   1. Enter Hold first: job **afterme-oncall-hold-enter**; confirm with **afterme-oncall-hold-status**. (In a real restore the clone may lack recent check-ins; nothing may alert on that.)
   2. Rewrite the four URLs to the new host (no value is printed):
      ```bash
      OLD=<private IP of afterme-pg-staging>; NEW=<private IP of the clone>
      for s in database-url worker-database-url maintenance-database-url migration-database-url; do
        gcloud secrets versions access latest --secret $s --project <P> | sed "s/@${OLD}:/@${NEW}:/" \
          | gcloud secrets versions add $s --project <P> --data-file=- --quiet
      done
      ```
   3. Restart everything so it reads the new versions (a changed variable makes a new revision):
      ```bash
      STAMP=$(date +%s)
      gcloud run services update afterme-api --project <P> --region asia-south1 --update-env-vars AFTERME_DEPLOY_STAMP=$STAMP --quiet
      gcloud beta run worker-pools update afterme-worker --project <P> --region asia-south1 --update-env-vars AFTERME_DEPLOY_STAMP=$STAMP --quiet
      ```
      The jobs read the secret at each run, so they follow without a restart.
   4. Run **afterme-oncall-status**: it must connect (the worker role works on the clone) and show the restored state; `infra/scripts/smoke.sh https://api.staging.afterme.app` passes; sign in with a test account and check in from the phone.
   5. Stop the stopwatch: `T_end − T_start` is the **restore-and-switch time** (clone, verify, rewrite, restart). Record it.
   6. Review (what was lost between `T` and now is visible in step 4's counts), then exit Hold with the owner's OK: job **afterme-oncall-hold-exit** (deadlines shift by the Hold's length plus 30 minutes).
6. **Switch back and clean up.** Rewrite the four URLs to `$OLD` (same loop with the two addresses swapped), restart as in 5.3, run `status` and `smoke.sh`. Then delete the scratch instance: 
   ```bash
   gcloud sql instances patch afterme-pg-staging-restore --no-deletion-protection --project <P> --quiet
   gcloud sql instances delete afterme-pg-staging-restore --project <P> --quiet
   ```
   Remove the stamp variable at the next deploy (`terraform apply` shows the drift; the deploy workflow does not carry it).
7. **Production, up to step 4:** repeat steps 1 to 4 on `afterme-pg-prod` (clone name `afterme-pg-prod-restore`); never switch; delete the clone as in step 6.

**What to observe.** The clone starts and is private-only; the schema revision matches; the grants are intact (a restore that loses a grant would show as a permission error in the application, so the two privilege checks matter); the newest data is within the RPO; `status` runs against the clone; the Hold made the switch quiet (no `contact_alert` left during it); the deadlines shifted when Hold ended.

**Pass criteria.** Clone `RUNNABLE`; Alembic revision equal; counts consistent with `T`; newest `ingestion_probes` and `audit_logs` rows **≤ 5 minutes before `T`**; roles and grants as expected; the application works against the clone (status, smoke test, a check-in); **restore-and-switch ≤ 60 minutes**; no message to a contact during the drill; staging back on its own instance, scratch instance deleted, `status` exits 0. A missing grant, an older-than-RPO data point or a time over an hour fails the game day (and the RTO in DEPLOYMENT §6 is then re-stated honestly with the measured figure).

**Restore.** Step 6 above (switch back, delete the clone). Close test incidents; deactivate schedules.

**Roll back / abort.** At any point: switch the four URLs back to `$OLD` and restart (step 6); the original instance is never touched by the drill, so aborting costs nothing. If anything contact-facing looks wrong at any time: **afterme-oncall-hold-enter**.
