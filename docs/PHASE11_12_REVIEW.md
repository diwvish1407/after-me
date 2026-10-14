# AfterMe — Phase 11 and 12 independent review

| | |
|---|---|
| **Status** | Findings dispositioned 2026-10-14 |
| **Scope** | Phase 11 (backend performance: migration 0011, concurrent engine units, reminder scan, outbox drain; mobile start-up, timers, call consolidation) and Phase 12 (Cloud KMS adapter and rotation, migration 0012, legal and support pages, Terraform, deploy workflow, on-call jobs) |
| **Result** | **0 S1, 1 S2, 8 S3, 5 S4.** Nothing breaks INV-1…10. The S2 and every S3 are fixed; two S4 are accepted |

## Disposition

| Finding | Disposition |
|---|---|
| **INF-1 (S2)** after a migration the previous API image could never become ready, so rollback was impossible; the rollback script stopped half-way | **Fixed**: readiness accepts a schema *ahead* of the image (logged `health.schema_ahead`), refuses one behind; expand/contract enforced by a test; `rollback.sh` rolls back API, worker pool and every job and exits 1 naming what it could not |
| E-3 worker pool 3 connections vs 4 units + 8 sends | **Fixed**: pool 14 in Terraform, the worker refuses to start below it, connection budgets checked at plan time; role limit raised in `provision_roles.sql` (re-run it) |
| K-1 KMS error on a first key gave 500 | **Fixed**: 503 + Retry-After |
| K-2 some KMS failures were silent | **Fixed**: every failure logs `kms.call_failed` once; configuration/integrity codes page at once |
| K-3 no deployed identity could run `kms check/rewrap/rotate-user` | **Fixed**: Cloud Run job `afterme-kms` as the API identity, operator-only |
| INF-2 any `v*` tag could deploy to staging | **Fixed**: Workload Identity bound to the GitHub Environment and repository id; repository settings in `infra/README.md` |
| INF-3 the complaint alert could never fire | **Fixed**: any complaint pages; hard bounces/failures at 5 an hour |
| E-1 reminder key format change duplicates a reminder at deploy | **Documented**: first deploy only, no users yet |
| E-2 a phone registered late in a reminder window got no push | **Fixed**: skip only when the email and a push for every current device exist; suspended accounts are not candidates |
| E-4 drain loop could spin on rows that only wait | **Fixed**; release links are no longer picked up while the Hold state is on or unknown |
| M-1 an invalid concurrent index would be accepted | **Fixed**: migration 0011 refuses to run over one |
| D-1 documentation said the app emits no `severity` | **Fixed** |
| K-4 a read racing `rotate-user` can show "cannot be opened" once | **Accepted** (S4, transient) |
| MOB-1 onboarding forgets saved instructions after a restart mid-onboarding | **Accepted** (S4) |

---

## Report as delivered by the reviewer

# AfterMe: adversarial review of the Phase 11 and Phase 12 changes

Reviewer: independent, read-only (no pytest, no PostgreSQL, no emulator, no edits to the repo).
Date: 2026-10-14. Scope: the working-tree diff against `e9a1feb` plus the untracked Phase 11/12 files.
Severity scale: TEST_PLAN §11 (S1 safety/privacy, S2 core feature broken, S3 degraded, S4 cosmetic).
CONFIRMED means the code path was traced end to end. PLAUSIBLE means the mechanism is real but depends on load, timing or configuration.

## Summary table

| ID | Sev | Area | File:line | Claim | Confidence |
|---|---|---|---|---|---|
| INF-1 | **S2** | Deploy / rollback | `backend/app/api/health.py:46-52`, `infra/terraform/modules/run/main.tf:198-206`, `.github/workflows/deploy.yml` ("Roll the API back"), `infra/scripts/rollback.sh:14` | `/health/ready` requires the DB revision to **equal** the image's Alembic head, and it is the API's startup probe. After any release that migrates, the previous image can never become ready. So the automatic rollback fails, `rollback.sh` fails (and under `set -e` it also leaves the worker and jobs unrolled), and between the migrate step and the new revision being ready the *old* revision cannot start any instance | CONFIRMED |
| K-1 | S3 | KMS / first instruction | `backend/app/security/vault.py:121-123`, `backend/app/instructions/service.py:390-399` | A `KmsError` from `wrap` while creating a person's **first** key is not turned into `VaultUnavailableError`, so `_warm` lets it through and the person gets a generic 500, not 503 + Retry-After. Onboarding step 7 is exactly this path | CONFIRMED |
| K-2 | S3 | KMS observability | `backend/app/security/gcp_kms.py:206-209, 222-223, 229-230`, `vault.py:112-115`, `infra/terraform/modules/monitoring/main.tf` (`kms_call_failed`) | `unknown_key`, `integrity`, `bad_response`, `key_mismatch` and the breaker's `recently_unavailable` are raised without the `kms.call_failed` log, and the vault swallows them silently. A changed `KMS_KEY_NAME` makes every instruction and every portal release "temporarily unavailable" with no log line and no KMS page | CONFIRMED (path); PLAUSIBLE (trigger) |
| K-3 | S3 | KMS rotation operability | `backend/app/ops/kms.py:17-19`, `infra/terraform/modules/kms/main.tf:48-53`, `modules/run/main.tf:73-80`, `modules/admin_vm/main.tf:19-25`, `docs/DEPLOYMENT.md:217`, `docs/SECURITY.md:125` | No provisioned identity can run `cli.admin kms rewrap / rotate-user / check` in staging or prod. These need the API DB role **and** KMS EncrypterDecrypter, and only the API service has both. Old KEK versions can never be retired, and per-user rotation after a suspected exposure needs an ad-hoc IAM change. The docs still describe the local KEK | CONFIRMED |
| E-1 | S3 | Engine reminders (deploy boundary) | `backend/app/engine/runtime.py:349-373`, `backend/app/engine/store.py:395-415` | The dedupe key changed from ISO to epoch seconds. Everyone inside a reminder window at deploy time gets the pre-deadline reminder (email and push) a second time, because neither the scan nor `ON CONFLICT` sees the old-format row | CONFIRMED (documented in tests/perf/PLANS.md) |
| E-2 | S3 | Engine reminders (skip rule) | `backend/app/engine/store.py:390-415` | Once the email reminder row exists the person is never rescanned. A device or push token registered later in the window gets **no push** reminder for that deadline (before, the next tick queued it) | CONFIRMED (documented); not covered by a test |
| E-3 | S3 | Engine concurrency vs the prod pool | `infra/terraform/modules/run/main.tf:56-57`, `backend/app/engine/runtime.py:46`, `backend/app/engine/dispatcher.py:68, 830`, `backend/app/core/db.py:81-89` | The prod worker pool is 2 + 1 = 3 connections. `UNIT_CONCURRENCY=4` and dispatcher `CONCURRENCY=8` queue on it (default `pool_timeout` 30 s). PERF-02/03 were measured with the default pool of 10, so the numbers do not hold in the deployed shape. A `_settle` that times out on the pool after the provider accepted leaves the row `sending`; it is recovered after 5 min and **sent again** | PLAUSIBLE |
| INF-2 | S3 | WIF (staging) | `infra/terraform/modules/iam/main.tf:134-146`, `infra/terraform/envs/staging/main.tf:12-13`, `deploy.yml` plan job | Staging accepts any `refs/tags/v*` token. The "tag must be on main" check runs inside the workflow file *at the tagged commit*, so anyone who can push a tag controls it. From there: staging cicd SA, then `run.developer` + `serviceAccountUser`, then a job or revision as the staging **api** SA (KMS decrypt + all secrets) | PLAUSIBLE (depends on GitHub tag rules) |
| INF-3 | S3 | Alerting | `infra/terraform/modules/monitoring/alerts.tf` (`bounces_complaints`), `backend/app/notifications/webhooks.py:52-58` | The regex `complained\|bounced\|hard_bounce\|soft_bounce\|spam_complaint` never matches the app's `complaint` (or `failed`), and the threshold is 9, not 1. "Any spam complaint" never notifies | CONFIRMED |
| E-4 | S4 | Worker drain | `backend/app/engine/dispatcher.py:169, 443-449`, `backend/workers/engine.py:40, 89-93` | `backlog = len(candidates) >= 100` counts rows that come back `wait` without being rescheduled (release-link rows during a Hold, busy user locks). With 100 such rows `drain_outbox` re-claims the same rows back-to-back until the next tick, and the 0.2 s pause keeps the worker from ever sleeping. This is a busy loop, not a safety issue | PLAUSIBLE |
| K-4 | S4 | Vault after `rotate-user` | `backend/app/security/vault.py:204-209` | A request that read an instruction row before the rotation committed, but resolves the key after it, raises `DecryptionError` and gets "content cannot be opened" (500 / portal error) instead of a retry. It is transient | PLAUSIBLE |
| M-1 | S4 | Migration 0011 runbook | `backend/migrations/versions/20261017_0011_performance_indexes.py` docstring + `upgrade()` | The documented "CONCURRENTLY first, then `IF NOT EXISTS` makes 0011 a no-op" path can leave an **INVALID** index (a failed concurrent build) that 0011 silently accepts | PLAUSIBLE |
| D-1 | S4 | Docs drift | `docs/INFRASTRUCTURE.md:308` | Says the app's JSON has no `severity`. `app/core/logging.py` now adds it | CONFIRMED |
| MOB-1 | S4 | Mobile onboarding | `mobile/lib/features/onboarding/application/setup_controller.dart` (`_created`) | Saved instructions are remembered only in memory. After an app restart mid-onboarding, step 7 shows none saved, so the person may save a duplicate | CONFIRMED (UX only) |

**Counts:** S1: 0 · S2: 1 · S3: 8 · S4: 5 (14 findings).

---

## 1. Engine changes for performance (priority 1)

### What was checked and holds

* **No two units for the same person run at once on one replica.** Each step (`open_due_incidents`, `execute_due_actions`, `enqueue_pre_deadline_reminders`) runs on its own, one after the other (`runtime.py:156-159`), and each page finishes before the next is read. The page queries return one row per person: `due_deadlines` and `reminder_candidates` read `checkin_configurations` (PK `user_id`), and `users_with_due_actions` uses `GROUP BY user_id`. So an open unit and an execute unit for the same person can never be in the same `gather`. Across replicas, `open_incident` (`opener.py:51`) and `run_user` (`executor.py:107`) take `lock_user ... SKIP LOCKED` **before** any read or write. Lock order is config → incidents (`lock_incidents`, ID order) → actions → notifications.
* **No deadlock between concurrent units.** Units of different people share no locked rows. The audit writer is a plain `session.add` (`audit/writer.py:380-383`) with no chain or advisory lock. Notification inserts collide only on dedupe keys, which contain the user id. The Hold advisory lock is taken only in `HoldMonitor.evaluate`, before the units. The dispatcher does not run at the same time as the tick in the same process.
* **Failure isolation.** Every `work` callable catches `Exception` (`runtime.py:198, 243, 324`), so `gather` sees no exception. Report counters are plain int `+=` between awaits, which is safe on one event loop. `ActionExecutor`, `HoldMonitor` and `InstructionReleases` keep no per-call state (`executor.py:82-89`). Residual: a `BaseException` other than an outer cancel would leave sibling tasks running detached. Nothing in a unit raises one today.
* **Hold.** `open_incident` and `run_user` re-read `open_hold` inside the unit, after the lock (`opener.py:58`, `executor.py:112`), and `force_hold=report.hold_unknown` is passed through. An operator Hold that starts mid-page is seen by every unit that has not yet taken its lock. A unit already past the check behaves as it did when units ran one at a time. The dispatcher re-checks the Hold on every escalation claim (`dispatcher.py:467`) and on release links (`dispatcher.py:448`).
* **`drain_outbox`.** It reuses the tick's `contact_facing`, so a failed or unknown Hold evaluation keeps every drain pass from sending anything contact-facing. Each pass re-reads `open_hold` (`dispatcher.py:167`) and each claim re-checks it. It stops at `tick_started + tick_seconds` and on SIGTERM. The longest gap between two Hold evaluations is unchanged at about 15 s plus one pass of at most 85 s, the same as the old dispatch-then-sleep. The `settle_delay > ingestion_stale + 2·tick` assumption (`config.py:350`) is no worse than before, though it was already loose against a 60-85 s pass.
* **Reminder skip rule, cut-off and key shape.** `MAX_REMINDER_LEAD_MINUTES = 240` equals the CHECK maximum (`checkins/models.py:42`), and `next_due_at - lead <= now` already implies `<= now + 240`. Midpoint and last-chance reminders come from incident actions (executor), not from this scan, so the cut-off cannot touch them. A moved deadline or timezone change gives a new epoch, so a new reminder. Python `int(ts)` truncates while PostgreSQL `CAST(numeric AS bigint)` rounds, but `compute_next_due` only produces whole minutes (`schedule.py:39-60`) and nothing else writes `next_due_at` with seconds. A mismatch would only cost a rescan, never a duplicate, because the Python key is what `ON CONFLICT` sees. The UUID-as-text form matches `str(uuid)`. Pure-Python check: `pre_reminder_stamp(2026-10-14T14:30Z) == "1791988200"`.

### E-1 (S3, CONFIRMED). Duplicate pre-deadline reminders at the deploy boundary

`_pre_reminder` now builds `prereminder:{user}:{epoch}:email|push:{device}`. Rows queued by the previous release carry `prereminder:{user}:{ISO}:...`. After deploy, `reminder_candidates`' `NOT EXISTS` does not find the new-form key, so the person is a candidate again. `outbox.enqueue` inserts new rows because `ON CONFLICT (dedupe_key)` sees a different key. Both reminders pass `_recheck_user`, since `params.due_at` is the same ISO text. Result: each person inside their window at deploy time (about 5,000 at 100k users, per PLANS.md) gets the reminder twice. It is user-facing only, and PLANS.md accepts it. Cheap fix: also match the legacy key in the `NOT EXISTS`, and in a one-off guard in `_pre_reminder`, for one release.

### E-2 (S3, CONFIRMED). A device registered after the email reminder gets no push for that deadline

Before this change every tick re-ran `_pre_reminder` for everyone in the window, and per-device dedupe added a push draft for any newly registered device. Now the scan stops at the first email row, and the push and email drafts are written together, so a device that appears later is never added.

Scenario: lead 120 min. At T-120 the person has a device row whose `push_token` is NULL (permission not yet granted, or the FCM token not yet uploaded). At T-90 the token arrives. The person relies on push and only gets the email. The same happens after reinstalling or moving to a new phone inside the window: the old device's push may already be gone, and the new device gets nothing.

PLANS.md documents it. No test covers it, and no user-facing doc mentions it. Fix options: also rescan when a device's `push_token_updated_at` is newer than the email row's `created_at`, or key the skip on "every current device has a row".

### E-3 (S3, PLAUSIBLE). The prod worker pool is smaller than the concurrency it serves

`modules/run/main.tf:56-57` sets `AFTERME_DB_POOL_SIZE=2`, `AFTERME_DB_MAX_OVERFLOW=1` for the worker: 3 connections in the main pool. `UNIT_CONCURRENCY=4` and dispatcher `CONCURRENCY=8` both draw on it, with `pool_timeout` left at the default 30 s (`db.py:81-89`). `scripts/perf.py` sets no pool, so PERF-02 and PERF-03 ran with 10 connections. The "10,000 due in under 2 minutes" result does not carry over to the deployed shape.

This does not deadlock: each unit and each claim/settle holds one connection at a time. There is one safety-relevant edge. In `_deliver`, if `_settle` (tx B, `dispatcher.py:830`) cannot get a connection within 30 s after the provider **accepted**, `sqlalchemy.exc.TimeoutError` is caught by `one()`. `_back_off` then finds the row `sending`, not `queued`, and does nothing. `_recover_stuck` re-queues the row after 5 minutes and it is sent again: a duplicate alert, or a second release link minted. The second send carries the same idempotency key, but not every fallback provider honours it.

This is at-least-once by design, but the sizing makes it more likely under database slowness (exactly when CPU is above 80%). Fix: size the worker pool to at least `max(UNIT_CONCURRENCY, CONCURRENCY) + 1`, which fits the 20-connection worker budget at 2 instances × 2 pools × (8 + 1) = 36. That means raising the role limit or cutting the dispatcher concurrency. Then re-measure PERF-02/03 with the prod pool values.

### E-4 (S4, PLAUSIBLE). Drain busy-loop on rows that "wait"

`report.backlog` counts candidates, not progress. During a Hold, release-link rows (`CONTACT_RELEASE`, category `contact_other`) are not filtered out of `_candidates` (`dispatcher.py:245-251`) and come back `wait` (`dispatcher.py:448`) without a `next_attempt_at`. With 100 of them, every pass re-claims the same 100 and `drain_outbox` loops until the next tick. Then `pause=0.2` and the next tick start straight away, so the worker never idles while the Hold lasts. Nothing wrong is sent; this costs DB load and log volume. Fix: count `left_queued` against `backlog`, or set `backlog` only when something was sent, cancelled or retried.

### Risks not covered by `backend/tests/engine` and `tests/unit/test_worker_drain.py`

* `run_units` is referenced by no test (grep). Nothing asserts that one unit raising mid-page leaves the other three in flight and the page complete, or that `report` counts stay right under concurrency.
* Nothing covers the legacy-key boundary (E-1), the late device (E-2) or a suspended user in the window. A suspended account keeps an active schedule (`ops/users.py:220`), so the person is rescanned every tick: no email row is ever written, and the old "full page keeps the worker awake" cost comes back for them.
* `test_worker_drain.py` uses a fake dispatcher only. No test runs `drain_outbox` with a real dispatcher while a Hold starts mid-drain (operator `hold enter`), and none covers the `wait` rows of E-4.
* No test runs the engine or dispatcher with the production pool values (E-3).
* `test_reminder_candidates.py` covers "queued means not rescanned" and "new deadline means new reminder". It does not cover timezone change at the same instant, a deadline moved back to a previously reminded instant (correctly not re-sent, as before), or the 240-minute bound against a 240-minute lead at the exact boundary.

## 2. Cloud KMS adapter and key rotation (priority 2)

### Checked and sound

* AAD binding: `wrap` and `unwrap` send `dek_aad(user_id, key_id)`, and `kms check` proves a different user id is refused. The `key_id` is pinned to the configured CryptoKey, and the database cannot choose which key is called (`unknown_key`). A `name` that is not a version of the configured key is refused (`key_mismatch`).
* CRC32C: the implementation is correct (`crc32c(b"123456789") == 0xE3069283`, checked in pure Python), it is checked both ways, and the plaintext length is checked.
* The circuit breaker only fails *closed* faster. No path returns a DEK without a successful decrypt. 4xx answers do not open the breaker. A 401 refreshes the token once.
* `rotate_user`: KMS calls happen outside any lock. Then one transaction does the per-user lock (`SKIP LOCKED`), `user_keys FOR UPDATE` with compare-and-swap, re-encryption of every `instructions` row (the only ciphertext column in the schema), the version bump and the audit row. A crash at any point leaves the person wholly before or wholly after. The trigger in 0012 refuses any version move other than +1 and does not interfere with `rewrap`, which leaves the version alone.
* `rewrap` keeps the DEK, so stale caches in other processes stay valid. `seal` confirms `dek_version` under the lock before using a cached key. `open` retries once when it is one version behind.
* The 0012 grant (UPDATE on four columns of `user_keys` to `afterme_api`) gives nothing the role could not already do with DELETE + INSERT. The worker has no `user_keys` privilege and an `UnavailableKms`. INV-1 is unaffected.
* Logs: `httpx` and `httpcore` are at WARNING. The KMS adapter logs operation and code only, and `ServiceAccountTokens` errors carry no values. Nothing else on the KMS path logs a URL.

### K-1 (S3, CONFIRMED). First key creation during a KMS error returns 500

`_lookup` → `_create` → `self._kms.wrap(...)` (`vault.py:123`) is not wrapped. A `KmsError` (timeout, 403, breaker open) therefore escapes as `KmsError`, not `VaultUnavailableError`. `InstructionService._warm` catches only `VaultUnavailableError` and `DBAPIError` (`service.py:395-397`), so the request ends in the middleware's generic 500.

The person affected is anyone saving their **first** instruction, which is onboarding step 7. The 503 + Retry-After contract the app relies on is lost.

`tests/engine/test_kms.py:205` tests "create" for a person who already has a key, so this path is untested. Fix: catch `KmsError` around `wrap` in `_create` and raise `VaultUnavailableError`.

### K-2 (S3, CONFIRMED path). Some KMS failures produce no log and no page

`GcpKms._failed` (the only `kms.call_failed` emitter) is used for HTTP errors and exhausted retries. It is not used for `unknown_key` (`gcp_kms.py:209`), `integrity` (192, 196, 223), `bad_response` (118-132, 274-276), `key_mismatch` (199) or `recently_unavailable` (230). The vault turns each into a silent `VaultUnavailableError`.

Scenario: the owner points `KMS_KEY_NAME` at a new key ring or region, or makes a typo that still matches the regex. Every stored DEK carries `gcp:<old name>`, so every instruction read and every contact's portal view answers "temporarily unavailable". There is no `kms.call_failed`, no KMS page, and probably no 5xx page either, because instruction traffic is far below 2% of requests.

During a real outage on a low-traffic beta, the breaker also suppresses the repeat logs. The 3-in-5-minutes threshold may never be reached, and contacts reading a release are the people who notice. Fix: log every `KmsError` code at the vault boundary (`vault.py:114`) under the same event, and consider a threshold of 1 for `unknown_key` / `integrity`.

### K-3 (S3, CONFIRMED). The KMS operator commands cannot be run in the deployed system

`ops/kms.py` says the commands run "as the API role (`DATABASE_URL`)" and need the KMS. In Terraform:

* only the `api` service account has `cryptoKeyEncrypterDecrypter` (`kms/main.tf:48-53`);
* the `afterme-admin` job runs as `admin` with `AFTERME_DATABASE_URL` set to the placeholder (`run/main.tf:73-80`) and no KMS role;
* the admin VM's service account has no KMS role (`admin_vm/main.tf:19-25`).

So `kms check`, `kms rewrap` and `kms rotate-user` all fail safely. As a result, KEK versions accumulate (automatic rotation every 90 days) and can never be disabled. A per-user rotation after a suspected exposure would need someone to hand-grant KMS and the API database URL during an incident.

`docs/DEPLOYMENT.md:217` and `docs/SECURITY.md:125` still describe `KMS_LOCAL_KEY_PREVIOUS` and say a cloud adapter "must exist", and the commands' runbook ("DEPLOYMENT §9") does not exist. Fix: add a dedicated, non-scheduled Cloud Run job (`afterme-kms`) running as the api service account with `database-url`, executable only by the owner, and document it.

### K-4 (S4, PLAUSIBLE). Race between `open` and `rotate-user`

The request reads the instruction row (`content_key_version = v`) before the rotation commits. Then either (a) it has no cache entry and `_lookup` reads `user_keys` after the commit (v+1), or (b) its cache was refreshed to v+1. Either way `key_version != version` and the result is `DecryptionError`. The app shows "cannot be opened" (`ContentUnavailableError`), not "temporarily unavailable". This is rare, since rotation is an incident-only command, and transient.

## 3. Migrations 0011 and 0012 (priority 3)

* Revision chain: 0010 → 0011 → 0012, with `down_revision` strings right and a single head. `tests/security/test_migrations.py` lists 0012, 0011 and 0010.
* Model drift: all 13 indexes of 0011 exist with the same names, columns and partial predicates in the models (`incidents/models.py:57,98`, `plans/models.py:78`, `notifications/models.py:67-79`, `checkins/models.py:85-95`, `auth/models.py:115,145`, `audit/models.py:27`).
* 0012: the trigger is created before the grant, and the downgrade revokes then drops. Both are guarded on the role existing.
* **M-1 (S4, PLAUSIBLE).** The docstring's advice for a live database ("create the indexes with CONCURRENTLY first … `IF NOT EXISTS` makes this migration a no-op") has a known trap. A failed or cancelled `CREATE INDEX CONCURRENTLY` leaves an INVALID index under that name, and `IF NOT EXISTS` then silently accepts it. The planner ignores it, so the hot path silently reverts to the scans 0011 exists to remove. Add a check of `pg_index.indisvalid` to the runbook (or the migration).

## 4. Legal and support pages (priority 4)

No finding. Checked:

* Every settings value goes through Jinja autoescape, and the `mailto:` hrefs have a fixed scheme, so there is no XSS from settings.
* `Cache-Control: public, max-age=300` is used only on four routes that render settings and static text, set no cookie and read no session. There is no Cloud CDN on the backend (no `enable_cdn` in `infra/`), so the per-response CSP nonce is only ever reused from one browser's own cache.
* The draft banner shows unless `LEGAL_DOCUMENTS_FINAL`.
* Spot-checked statements against the code: check-ins kept 400 days, delivery records 90 days, sessions and tokens 30 days after expiry, audit retention from settings, "no cookies on /legal and /support", "alerts never carry instruction text", "contacts get nothing until they accept" (`require_verified=True` for escalation and releases). All agree.

## 5. Infrastructure (priority 5)

### INF-1 (S2, CONFIRMED). The readiness check makes rollback impossible after a migration, and blocks scale-out during a deploy

`/health/ready` returns 503 unless `alembic_version == expected_heads()` of **this image** (`health.py:46-52`). It is the API's startup probe (`run/main.tf:198-206`, 24 × 5 s).

1. **Automatic rollback in `deploy.yml`.** After `afterme-migrate` moved the database to head N+1, the previous image expects head N. Its revision never passes the startup probe, `gcloud run services update --image $PREVIOUS` fails, and traffic stays on the release whose smoke test just failed.
2. **`infra/scripts/rollback.sh`** fails at its first command for the same reason. With `set -e` it also never rolls back the worker pool or the jobs. `docs/DEPLOYMENT.md:136` promises that rollback works because "schema remains compatible".
3. **During every migrating deploy**, from the end of `afterme-migrate` until the new API revision is ready, the old revision cannot start a new instance: autoscaling, a crashed instance or platform maintenance. If the new revision then fails to become ready (a bad image), the API can run down to zero ready instances. Check-ins become impossible; the ingestion Hold protects contacts, but "check-in impossible" is in the S1 column of TEST_PLAN §11. Rated S2 because it needs a second failure.

Fix: have readiness accept "database at or ahead of my head, within the known chain" (expand-only migrations), or compare against a minimum compatible revision. Keep "behind my head" as not ready.

### INF-2 (S3, PLAUSIBLE). The staging WIF condition trusts a check the attacker controls

The staging provider condition is: repository, environment `staging`, `ref == main || ref.startsWith('refs/tags/v')`, and `job_workflow_ref` starting with `.../deploy.yml@`. For a tag push, the `deploy.yml` that runs is the one **in the tagged commit**. The "only code on main" check (`git merge-base --is-ancestor`) lives in that file.

So anyone who can push a `v*` tag can put any commit, with a modified `deploy.yml`, behind the staging cicd service account. That account has `run.developer` + `serviceAccountUser` on the api service account, so it can deploy a job or revision as the **api** service account: KMS decrypt plus every staging secret, and the staging data of the game days. The comment in `iam/main.tf` ("It cannot read a secret, cannot touch the key") is not true transitively. Production is limited to `main` plus a reviewed `production` environment, which is sound if `main` is protected.

Fix: a tag-protection ruleset (only admins create `v*`) and deployment-tag rules on the `staging` environment, or drop tags from the staging condition. Document that CI is effectively equivalent to the api service account.

### INF-3 (S3, CONFIRMED). The bounce/complaint notification can never fire on a complaint

The app emits `kind` values `delivered | hard_bounce | soft_bounce | failed | complaint | other` (`webhooks.py:52-58`). The policy matches `(complained|bounced|hard_bounce|soft_bounce|spam_complaint)` with `threshold_value = 9`. A spam complaint is never counted, and the documented "any spam complaint" would need its own condition with threshold 0. `failed` is also excluded.

### Checked and sound

* Alert event names: all 26 names referenced by the monitoring module exist in `backend/app`, `workers` or `cli` (grep), including the `http.request` fields `route`/`method`/`status` and `jsonPayload.kind`. No policy filters on `severity`, so the new field changes nothing for alerting. **D-1 (S4):** `docs/INFRASTRUCTURE.md:308` still says the app writes no `severity`.
* Absence alerts exist for the watchdog job, the uptime check and the backup job. The uptime check posts through the public domain, accepts only 204, and keeps the token out of Terraform (placeholder + `ignore_changes` + `set_probe_header.sh` via stdin).
* `TRUSTED_PROXY_HOPS=2`: the reasoning matches `core/net.py` (entry `len-N`, fall back to the peer when the header is short). It is verified on every staging deploy (`verify_client_ip.sh spoof`). The `run.app` URL is disabled and ingress is restricted to the load balancer.
* Deploy ordering: backup (prod), then migrate and **wait**, then API by digest, then smoke, then the worker and jobs. A failed migration stops everything before traffic changes. GitHub's implicit `success()` skips the worker and job deploys after a smoke failure.
* KMS IAM: only the api service account can encrypt or decrypt. The worker, maintenance, admin and CI accounts have no KMS role. KMS data-access audit logs are on. The key ring and key have `prevent_destroy`, and destruction of a scheduled version can be cancelled for 30 days.
* On-call `afterme-admin` with overrides: the command is fixed (`python -m cli.admin`); arguments and env are overridable. It runs as the worker role, with no KMS and the API database URL replaced by a placeholder, so the `kms` subcommands fail closed. Execution is recorded in Cloud Audit Logs under the caller's Google identity (`--operator` is free text, so the CLI's own audit label can be spoofed). Not a new hole. Note: the JWT signing keys and the pepper are mounted into the worker, maintenance and admin jobs; the comment in `secrets/main.tf` acknowledges this.

## 6. Mobile Phase 11 (priority 6)

* `start.dart`: the splash shows first and the provider tree appears only after `requirePackage`. A failure still fails closed (`MisconfiguredBuildApp`). Nothing reads storage or the network before the check.
* `ForegroundTicker`: cancelled on `paused`/`hidden`, restarted on `resumed` with `onForeground`, and `inactive` is ignored. Home's own 30 s ticker now also polls about once a minute while the deadline has passed with no incident and while a service interruption is on. That is wider than before, not narrower.
* `homeInputChangesProvider`: each former Home listener moved into the controller as a `listenSelf` with the same comparison (schedule version/status, plan version, contacts list, profile timezone or name). A controller that never loaded cannot have changed what Home shows. Home's name now comes from the aggregate and is re-read when the profile bumps the counter.
* `PendingCheckInStore`: another account's unsent tap is parked under `checkin.pending.<id>` instead of being overwritten, read back only for its own account, and removed by `clearFor`. `clearAll` sweeps parked records and isolates each failure. No pending tap is lost by the change. `checkin_controller.dart` (the I'M OK retry) is not modified in this diff.
* **MOB-1 (S4).** `SetupController._created` is in memory only, so after a restart mid-onboarding the instruction step shows nothing saved. The person may save a duplicate. Nothing is lost.
