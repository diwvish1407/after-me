# AfterMe — Deployment & Operations

| | |
|---|---|
| **Status** | Draft v0.1 — awaiting product-owner approval |
| **Related** | [ARCHITECTURE](ARCHITECTURE.md) · [ESCALATION_ENGINE §12–13](ESCALATION_ENGINE.md#12-observability) · [SECURITY §16](SECURITY.md#16-operational-security) |

---

## 1. Environments

| Env | Purpose | Backend | Database | Providers | App flavor |
|---|---|---|---|---|---|
| **dev** | Local development | Laptop (`uvicorn --reload`, worker) | Local PostgreSQL | `console` email, `local` KMS, FCM dev project (optional) | `dev` |
| **test** | CI | Ephemeral | PostgreSQL service container | Recording fakes | — |
| **staging** | Integration, game days, the manual device sheet (sideloaded `staging` flavor); **not** the Play beta, which runs on production ([BETA_PLAN §1](BETA_PLAN.md#1-the-sequencing-problem-you-need-to-decide-first)) | Cloud (same shape as prod, smaller) | Managed PostgreSQL (single zone) | Real providers (sandbox/test domains), staging Firebase | `staging` |
| **prod** | Users | Cloud | Managed PostgreSQL (HA, PITR) | Real providers, prod Firebase | `prod` |

Each environment has **separate** credentials, keys, Firebase projects and databases. No production data ever goes to dev or staging.

## 2. Local development setup

### 2.1 What this machine has today (checked 2026-10-08)

| Tool | Status | Action |
|---|---|---|
| Python | 3.12.12 and 3.14.6 present | Project uses uv-managed **3.13** (`uv python install 3.13`) |
| uv | 0.9.3 present | Upgrade: `uv self update` |
| PostgreSQL | 14.19 (Homebrew) present | Works. Recommended: install the same major version as production (`brew install postgresql@17`) |
| git | 2.52 present | — |
| **Flutter SDK** | **missing** | Install the latest stable (official macOS instructions). The version is pinned in the repo at Phase 1. |
| **Android Studio + SDK + emulator** | **missing** | Install Android Studio; SDK Platform 36, build-tools, platform-tools, an emulator image (API 36 and API 26) |
| **JDK 17+** | **missing** | Use the JDK bundled with Android Studio (Flutter detects it) |
| Docker | missing | **Optional.** Not required for development (local Postgres is used); CI uses containers. |
| GitHub CLI | missing | Optional (`brew install gh`) if GitHub is used |

Then run `flutter doctor` and `flutter doctor --android-licenses` until Android is all green.

### 2.2 Running locally (after Phase 1)

```bash
# Backend (verified in Phase 1; details in backend/README.md)
cd backend
make setup                                 # uv sync; scripts/dev_db_setup.sh (roles, afterme_dev,
                                           # afterme_test); .env from .env.example + fresh dev
                                           # secrets; uv run alembic upgrade head
make run                                   # uv run uvicorn app.main:app --reload → http://127.0.0.1:8000
make check                                 # format, lint, mypy, tests, dependency audit
make migrate-check                         # migration round trip on a throwaway database (CI runs it too)
# Worker (Phase 5+): uv run python -m workers.engine in a second terminal
# Retention (Phase 7): make maintenance   # finishes account deletions; run every ~15 minutes
# Integration tests (Phase 7): AFTERME_TEST_SUPPORT_ENABLED=true AFTERME_TEST_SUPPORT_TOKEN=<32+ bytes>
#   for BOTH `make run` and the worker (they must share the test clock); see backend/README.md

# Mobile
cd mobile
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run --flavor dev --dart-define-from-file=config/dev.json
# The Android emulator reaches the host as http://10.0.2.2:8000 (cleartext allowed only in the dev flavor)
```

Exact commands are finalised and verified in Phase 1.

## 3. Hosting (decided, Phase 12)

**Google Cloud, region `asia-south1` (Mumbai)**, one project per environment (`afterme-staging`, `afterme-prod`; also the Firebase projects). Domains `afterme.app` (public pages), `api.afterme.app` (API), staging `staging.afterme.app` / `api.staging.afterme.app`; DNS on Cloudflare with the proxy off. The code is in [`infra/`](../infra/README.md) (Terraform, bring-up sequence, cost estimate); the architecture, trust boundaries, service accounts, the `TRUSTED_PROXY_HOPS` analysis and disaster recovery are in [INFRASTRUCTURE.md](INFRASTRUCTURE.md).

| Concern | Service | Prod | Staging |
|---|---|---|---|
| Front door | Global external Application Load Balancer, Google-managed certificate, static IPv4 (not a Cloud Run domain mapping) | ✓ | ✓ |
| API + web pages | Cloud Run service `afterme-api`; ingress from the load balancer only; CPU always allocated (the API sends mail from background tasks after the response) | min 1, max 7 | min 1, max 3 |
| Worker | Cloud Run **worker pool** `afterme-worker` (`python -m workers.engine`; a service cannot run it: no HTTP port) | **2 instances** (safe via `SKIP LOCKED`) | 1 |
| Retention | Cloud Run **job** `afterme-maintenance` (`python -m workers.maintenance`) run every 15 min by Cloud Scheduler | ✓ | ✓ |
| Migrations | Cloud Run job `afterme-migrate` (`alembic upgrade head` as `afterme_owner`), run and awaited by CI before any new code | ✓ | ✓ |
| Database | Cloud SQL for PostgreSQL 17 (Enterprise), private IP only, TLS required | **Regional HA**, PITR 7 days, 30 daily backups, deletion protection | Single zone, backups |
| Keys | Cloud KMS keyring `afterme`, key `instruction-kek` (auto-rotation 90 days, `prevent_destroy`); usable by the API's service account only | ✓ | ✓ (own project) |
| Secrets | Secret Manager (values added out of band, never in Terraform) | ✓ | ✓ |
| Images | Artifact Registry `afterme` (deploys are by digest) | ✓ | ✓ |
| Probe / uptime | Cloud Monitoring uptime check → `POST /internal/probe` through the public domain every 60 s from three regions | ✓ | ✓ |
| Watchdog | Cloud Run job `afterme-status-check` runs `python -m cli.admin status` every 2 min; a failed run pages | ✓ | ✓ |
| Logs / metrics / alerts | Cloud Logging (30-day retention), log-based metrics, 18 alert policies, one dashboard | ✓ | ✓ |
| Operator access | Cloud Run jobs `afterme-oncall-*` and `afterme-admin` ([ONCALL.md](ONCALL.md)) | ✓ | ✓ |
| Push | Firebase project `afterme-prod` (FCM with the worker's own identity) | ✓ | `afterme-staging` |
| Identity for CI | Workload Identity Federation (no long-lived keys) | ✓ | ✓ |

**Alternative (simpler, less integrated):** a container PaaS (Render/Fly/Railway) + managed Postgres + a standalone KMS. This is acceptable for staging, but production needs equivalent HA, PITR, KMS and uptime probing. Not used.

## 4. Configuration and secrets

All configuration comes from environment variables (prefix `AFTERME_`), validated at startup by `pydantic-settings`. **(S)** = secret, from Secret Manager in staging/prod.

| Variable | Notes |
|---|---|
| `APP_ENV` | `dev` · `test` · `staging` · `prod`. **Must be set** (a process with neither this nor a `.env` file refuses to start). Staging and prod also refuse: `LOG_LEVEL=DEBUG`; any of the three database URLs without `sslmode=require` (or stronger) unless it points at a loopback proxy; a Postmark webhook password under 32 characters |
| `PUBLIC_BASE_URL`, `API_BASE_URL` | HTTPS required outside dev |
| `DATABASE_URL` **(S)** | `afterme_api` role |
| `WORKER_DATABASE_URL` **(S)** | `afterme_worker` role |
| `MAINTENANCE_DATABASE_URL` **(S)** | `afterme_maintenance` role (the retention job, Phase 7); required in staging and production |
| `ACCOUNT_DELETION_DAYS` | How long a closed account's remaining rows are kept before the hard delete; default 30 |
| `TEST_SUPPORT_ENABLED`, `TEST_SUPPORT_TOKEN` **(S)** | Movable clock and mail reader for integration tests. **Never in production** (refused). In staging only for the end-to-end suite, with the token. |
| `MIGRATION_DATABASE_URL` **(S)** | `afterme_owner` role (migration job only) |
| `DB_POOL_SIZE`, `DB_STATEMENT_TIMEOUT_MS`, `API_LOCK_TIMEOUT_MS` | |
| `JWT_SIGNING_KEYS` **(S)**, `JWT_ACTIVE_KID`, `JWT_ISSUER`, `JWT_AUDIENCE` | Ed25519 keys as JSON `{kid: pem}` |
| `HMAC_PEPPER` **(S)**, `HMAC_PEPPER_PREVIOUS` **(S)** | Dual-check during rotation |
| `KMS_PROVIDER`, `KMS_KEY_NAME` | `local` is refused in prod |
| `LOCAL_KEK` **(S, dev/test only)** | |
| `EMAIL_PROVIDER` (`resend`, `postmark`, `smtp`; `console` and `recording` are refused in prod), `EMAIL_API_KEY` **(S)**, `EMAIL_FROM` (an address on the verified sending domain), `EMAIL_WEBHOOK_SECRET` **(S)** | Resend: the signing secret `whsec_…` of the webhook; Postmark: the password of the webhook URL's Basic auth. Required in staging/prod for `resend` and `postmark` |
| `EMAIL_FALLBACK_PROVIDER` (a different provider), `EMAIL_FALLBACK_API_KEY` **(S)**, `EMAIL_FALLBACK_WEBHOOK_SECRET` **(S)** | Optional (FR-NOT-06); `afterme-admin status` warns when absent |
| `POSTMARK_MESSAGE_STREAM` | Default `outbound` (use a transactional stream) |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` **(S)**, `SMTP_IMPLICIT_TLS` | Only for `smtp`; STARTTLS by default |
| `PUSH_PROVIDER` (`fcm` in staging/prod; `log`, `noop` for dev/tests), `FCM_PROJECT_ID` | Service identity via Workload Identity on GCP (no key file) |
| `FCM_CREDENTIALS_JSON` **(S)** | A service-account key, only where Workload Identity is not available (staging on a laptop-sized host, CI) |
| `PROBE_TOKEN` **(S)** | Uptime-check header |
| `SENTRY_DSN`, `SENTRY_TRACES_SAMPLE_RATE` | |
| `TRUSTED_PROXY_HOPS` | For client IP extraction |
| `TICK_SECONDS`, `SETTLE_DELAY_SECONDS`, `INGESTION_STALE_SECONDS`, `HOLD_*`, `ANOMALY_FLOOR_PER_HOUR`, `ACTION_MAX_ATTEMPTS`, … | All parameters in [ESCALATION_ENGINE §13](ESCALATION_ENGINE.md#13-configuration) (prefix `AFTERME_`); unsafe values refused at startup (`SETTLE_DELAY_SECONDS` must exceed `INGESTION_STALE_SECONDS`; in prod `MIN_RELEASE_OFFSET_MINUTES >= 1440` and `SETTLE_DELAY_SECONDS >= 300`). `WORKER_DATABASE_URL` and `PROBE_TOKEN` are required in staging and prod. |
| `TEST_SUPPORT_ENABLED` / `TEST_SUPPORT_TOKEN` | Development and CI only (API_SPEC §17). Refused in production, **and unusable in staging**: it needs a development email provider, and staging refuses those, because moving the clock opens incidents and alerts contacts for every account in the database. End-to-end tests in staging therefore run in real time with real providers and short stage offsets, not with the test clock (Phase 9, F-19; a Phase 10 planning item) |
| `GOOGLE_PLAY_PACKAGE_NAME` | Billing (later) |
| `LOG_LEVEL` | Default `INFO` |

The mobile app has **no secrets**. `config/<env>.json` holds only the API base URL, environment name and the (public) Sentry DSN. Firebase is configured from the four public `FIREBASE_*` keys in each `config/<env>.json` (API key, app id, sender id, project id: one Android app per flavor id; **no** `google-services.json` and no Google Services Gradle plugin); they are public identifiers, but the repo is still kept private.

## 5. CI/CD

```
PR opened ─▶ backend checks + mobile checks (TEST_PLAN §10) + infra.yml (terraform fmt/validate) ─▶ review ─▶ merge to main
tag vX.Y.Z ─▶ deploy.yml → staging: build image ─▶ migrate (job, awaited) ─▶ deploy api ─▶ smoke ─▶ deploy worker + jobs ─▶ client-address check
manual "Run workflow", environment=production, from main ─▶ required reviewers ─▶ backup snapshot ─▶ migrate ─▶ deploy api ─▶ smoke (auto-rollback) ─▶ deploy worker + jobs ─▶ watch
mobile tag ─▶ flutter build appbundle (prod) ─▶ upload symbols ─▶ Play internal track (manual promotion)
```

- Git hosting: GitHub (Actions, Dependabot, branch protection). The repository is **private**.
- **`.github/workflows/deploy.yml`** builds the image, pushes it to Artifact Registry, runs the `afterme-migrate` job and **waits for it before any new code runs**, deploys the API **by image digest** (its startup probe is `/health/ready`, so a revision that cannot reach the database or whose code is ahead of the schema never gets traffic), runs `infra/scripts/smoke.sh` through the public domain and, if it fails, **rolls everything back automatically** (`rollback.sh`: the API, the worker pool and every job, to the previous digest), then deploys the worker pool and the jobs by the same digest. Production runs from `main` only, behind the GitHub Environment `production` (required reviewers), and takes an on-demand Cloud SQL backup first. Google access is Workload Identity Federation (`id-token: write` only in the deploy job); the pool accepts this repository (name and numeric id), this workflow file, `main` (or `v*` tags for staging) and **only a job running in that project's GitHub Environment** (`staging` / `production`), whose deployment branch and tag rules are part of the gate ([infra/README.md](../infra/README.md), "GitHub repository settings"). No secret is read or printed; CI never holds the probe token. Details: [INFRASTRUCTURE §10](INFRASTRUCTURE.md#10-cicd).
- Migrations always run **before** new code. They are backward compatible with the currently running version (expand/contract, [DATABASE §8](DATABASE.md#8-migrations-policy)).
- **The expand/contract rule (required; rollback depends on it).** A migration must keep the **previous release** working on the new schema, because between the migrate step and the new API being ready the previous revision still serves (and may start new instances), and because a rollback runs the previous image on the migrated schema. So a migration is **additive only**: new tables, new nullable columns or columns with a default, new indexes, new constraints the previous release already satisfies, new grants. A column or table the previous release reads is **dropped or renamed one release later** (the "contract" step), after no running code uses it; that migration carries a `# contract-step: <why the previous release no longer needs it>` comment, and `tests/security/test_migration_expand_contract.py` fails on any `DROP COLUMN`, `DROP TABLE`, `RENAME`, `op.drop_column`, `op.drop_table`, `op.rename_table` or `new_column_name=` in an upgrade without one. A rename is done as add-new, write-both, backfill, switch reads (release N), then drop-old (release N+1).
- **Readiness follows the same rule** (`backend/app/api/health.py`): the API is ready when the database revision is its own Alembic head, and **also when the revision is unknown to the image's migration scripts** (the schema is ahead: a rollback, or an old revision scaling out mid-deploy; a warning `health.schema_ahead` is logged once per process). It is **not** ready when the revision is a known, older one (the code is ahead: the migration has not run) or when there is none.
- Rollback: `infra/scripts/rollback.sh <project> <region> <previous image digest>` (the digest is in every run's summary) moves the API, the worker pool and every job (`afterme-migrate` and `afterme-kms` included) back to the previous image, **together**. It attempts every one even when one fails, prints what was and was not rolled back, and exits non-zero if anything was not: re-run it after fixing the cause (moving a resource to the image it already runs is harmless). The schema stays as migrated (expand-only, above). Running the previous `afterme-migrate` image against the newer schema fails without changing anything (Alembic does not know the revision), which is the right outcome.
- **Migrations that build indexes on a populated database** (e.g. 0011): `CREATE INDEX` without `CONCURRENTLY` blocks writes to the table while it builds. Build each index first with `CREATE INDEX CONCURRENTLY <name> ON <table> ...` outside a transaction, then **check `pg_index.indisvalid`** for every name (`SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname IN (...) AND NOT (i.indisvalid AND i.indisready);` must return nothing) **before** running the migration. A failed or cancelled concurrent build leaves an INVALID index under the name, which the planner ignores and `IF NOT EXISTS` would accept: drop it with `DROP INDEX CONCURRENTLY` and build it again. Migration 0011 refuses to run while one of its index names exists but is invalid.
- The backend stays compatible with the **two most recent app versions**. Older apps can be forced to update via `min_client_version` (→ `426`).

### 5.1 Mobile build and signing

```bash
cd mobile && tool/build_release.sh            # an .aab; --apk for an APK
```

`tool/build_release.sh` builds the prod flavor with `--obfuscate --split-debug-info`, refuses to run without `android/key.properties` (CI passes `--allow-debug-signing` and gets a loud warning), requires `APP_ENV=prod` and an https API URL in `config/prod.json`, and runs the merged-manifest check afterwards. Do not run `flutter build` by hand for a store upload.

- **Play App Signing**: Google holds the app signing key; we hold the **upload key**.
- The upload keystore lives in a password manager **plus** an offline backup. CI receives it as an encrypted secret. Losing it is recoverable via a Play support reset, but slowly.
- Versioning: `versionName` = semver; `versionCode` = monotonically increasing build number.
- Build-time defines (`mobile/config/*.json`): `API_BASE_URL`, `PUBLIC_BASE_URL` and, since Phase 7, `PLAY_STORE_URL` (an `https` link used by the blocking *Update AfterMe* screen; defaults to the app's Play page, so the prod value must be checked once the application ID is final).
- Obfuscation symbols are uploaded to error monitoring and stored privately.

## 6. Backups and recovery

| Item | Target / setting |
|---|---|
| Automated backups | Daily (window 21:00 UTC), **30 retained**, stored in `asia-south1` |
| Point-in-time recovery | **7 days** of write-ahead logs |
| Zone failure | Regional HA failover, RPO 0, about 1 to 2 minutes (game day OPS-04) |
| **RPO** (corruption, wrong delete) | ≤ 5 min (PITR) |
| **RTO** | ≤ 1 h (clone, verify, switch; measured in OPS-05) |
| Backup freshness | Cloud Run job `afterme-backup-check` every 6 h: newest successful backup ≤ 26 h and PITR on, else a PAGE |
| Restore test | Quarterly ([GAMEDAYS OPS-05](GAMEDAYS.md#8-ops-05-backup-restore-into-a-scratch-instance-and-the-switch-over)), documented |
| Backup access | Restricted IAM (the CI account may only create and list backups); encrypted |
| Deleted-user data in backups | Ages out within ≤ 35 days (stated in the privacy policy) |
| Region loss | Not covered in 1.0 (see [INFRASTRUCTURE §12](INFRASTRUCTURE.md#12-disaster-recovery)) |

After any restore, the engine enters **operator Hold** automatically. A restored database may be missing recent check-ins, so an operator reviews before resuming (exit with shift).

## 7. Monitoring and alerting

Alerts go by e-mail and SMS to **two** people (variables `oncall_emails`, `oncall_phone_numbers` in Terraform); non-paging alerts go by e-mail only. Everything below is defined in `infra/terraform/modules/monitoring`; [INFRASTRUCTURE §11](INFRASTRUCTURE.md#11-monitoring-what-pages-whom) lists the source of each signal. The database-state pages (heartbeat, Hold evaluation, held actions, messages given up, consistency violations, overdue action or message) are judged by `python -m cli.admin status` run every 2 minutes by the watchdog job: its exit code is the page. **Paging alerts:**

| Signal | Threshold |
|---|---|
| Worker heartbeat age | > 2 min |
| Hold active | any |
| Held actions / consistency violations | > 0 |
| Oldest due action not executed | > 5 min |
| Oldest due notification not sent | > 5 min |
| Uptime check failing | 2 consecutive |
| API 5xx rate | > 2% over 5 min |
| `POST /v1/checkins` error rate | > 1% over 5 min |
| Database CPU/storage/connections | > 80% |
| KMS: `kms.call_failed` (one line per failure, every code, from the Cloud KMS adapter and the vault) | ≥ 3 in 5 min; **any** configuration or integrity failure (`unknown_key`, `integrity`, `key_mismatch`, `bad_response`, `invalid_argument`, `permission_denied`, `not_found`, `unauthenticated`) at once |

**Non-paging:** provider failure rate > 5%; **any** spam complaint (webhook kind `complaint`); 5 or more hard bounces or failed deliveries (`hard_bounce`, `failed`) in an hour; p95 latency; certificate expiry (< 21 days); Play Android vitals (crash/ANR) thresholds.

Dashboard (`AfterMe operations`, Terraform): check-ins/hour, incidents opened, e-mail delivery events by kind, Hold history, worker lag, watchdog results, API and database health. Incidents resolved/escalated/cancelled and messages by template and status are not emitted as metrics by the application: read them with `python -m cli.admin status` and `beta-report` ([INFRASTRUCTURE §11](INFRASTRUCTURE.md#11-monitoring-what-pages-whom)).

## 8. Release process

1. Changelog entry; version bump.
2. Staging deploy + automated e2e + manual checklist for the affected areas.
3. Production backend deploy (tag). Watch dashboards for 30 min.
4. Mobile: internal track → closed testing → production **staged rollout** (10% → 25% → 50% → 100%), each step after vitals and error checks.
5. Post-release review of incidents and alerts in the first 48 h.

**Release notes, Phase 11/12 (first deploy of the performance changes only).** The pre-deadline reminder's dedupe key changed from an ISO timestamp to epoch seconds, so on the first deploy of that change everyone inside their reminder window gets that one reminder a second time (the old-format row is not recognised). First deploy only, and harmless before launch: there are no production users yet. A later deploy is unaffected.

## 9. Runbooks

> `afterme-admin` below is shorthand for the operator CLI: `python -m cli.admin …` (from `backend/`, or the same command inside the image; `make admin ARGS="…"` locally). It is not a separate executable.

| Situation | Steps |
|---|---|
| **Hold entered (ingestion)** | Check the uptime-check status and ingress; check the API health/logs; fix. Hold exits automatically after 10 min of fresh probes; verify `system.hold_exited` and the shift counts. |
| **Hold entered (anomaly)** | Inspect recent incidents (counts by app version, region, time); look for a bad app release or a push/email outage. If it's a bug: `afterme-admin incident void <incident-id>` for each affected incident (audited; the person's schedule restarts a full interval from then and they are told). Otherwise `afterme-admin hold exit` (shift applied; it will not re-enter over the same burst). |
| **Page: hold evaluation failing** | The worker ticks but cannot evaluate Hold, so it is treating the state as a Hold: no incidents open and no contact-facing message leaves; user reminders still go. Read `engine.hold_failed` (error class only) and fix the cause (a bad watermark row, a statement timeout, a missing grant). It clears by itself on the next good evaluation. |
| **Page: messages given up on** | A contact-facing message failed for 24 h from its first attempt. Find it with the audit event `notification.failed`; the person is told by the `contact_unreachable` notice (Phase 8). Decide with the owner whether to contact the person or the contact another way. |
| **Account deletions are not finishing** | The retention job (`python -m workers.maintenance`, scheduled about every 15 minutes) scrubs the contacts of closed accounts once their all-clear has left and hard-deletes accounts 30 days after the request. Run it by hand (`make maintenance`); read `maintenance.failed` (error class only). A missing grant shows as a permission error: the role needs migration `0007`. Nothing safety-relevant waits on it: contact-facing effects of a closed account stopped in the request itself. |
| **Worker down** | Restart; check heartbeats; confirm the catch-up behaviour (anchor rule) in logs; check for held actions. |
| **Email provider outage** | `afterme-admin status` shows `fallback_sends_15m` (and `provider_errors_15m`, which stays 0 while the fallback carries everything because the chain hides the primary's failures) and warns "the fallback email provider is carrying messages" / "provider error rate above 5%". The fallback takes over by itself (a provider that failed twice is skipped for 60 s). Without a fallback, messages retry with backoff for 24 h and a **paging** "queued message past send_after for 5 minutes" appears: consider operator Hold *only* if alerts would arrive misleadingly late. Communicate via status page. |
| **Provider credentials invalid** (OPS-03) | Adapters answer `ProviderUnavailableError` (`resend_401`, `postmark_10`, `smtp_auth`, `fcm_unauthenticated`): messages are retried, the fallback carries them, the status warns. Fix the secret in the secret manager and restart; nothing is lost. Prove it with `afterme-admin email-test`. |
| **Bounce or complaint spike** | Notified on **any** spam complaint and on 5+ hard bounces or failed deliveries in an hour. `bounces_24h` / `complaints_24h` in `afterme-admin status`. A hard bounce marks the contact `bounced` and tells its owner; a complaint suppresses the address everywhere. A spike usually means a mass-invited list: check invitation volume in the audit log and the provider dashboard before the sender reputation suffers. |
| **Push outage** | No action needed for safety (email in parallel); monitor reminder delivery. A token FCM reports as unregistered is removed by the dispatcher by itself. |
| **A webhook is rejected (`401`)** | The signing secret or Basic-auth password in the provider and in `EMAIL_WEBHOOK_SECRET` differ, or the host clock is more than 5 minutes off (Svix). Bounces are not applied until fixed: events are retried by the provider for a while. |
| **Held action / consistency violation** | Never "force execute". Investigate the data and fix the root cause. An action that failed only for its own reasons can be put back with `afterme-admin action retry <action-id>` (audited): it goes through the whole safety gate again and a stage that is by then overdue by more than the limit is held again rather than run. Infrastructure errors (connection loss, lock timeouts) never hold an action. |
| **A contact says the link doesn't work** | Links last 30 days and stop working when the person checks in, the contact is removed or opted out, or the release is taken back. The contact can ask for a new link from the page itself (sent only to their verified address). Look at `release_events.revoke_reason` and `portal_access.revoked_at` for the incident; never re-enable a revoked release by hand. |
| **Key management** | Production and staging use **Cloud KMS** (`KMS_PROVIDER=gcp_kms`, `KMS_KEY_NAME` = the CryptoKey `instruction-kek`; `local` is refused there). The operator commands run as the Cloud Run job **`afterme-kms`**: the API image, the **API service account** (the only identity with KMS EncrypterDecrypter) and the API's `database-url` secret; its command is fixed to `python -m cli.admin kms`, so an execution can only choose the kms subcommand; only the on-call principals may execute it (`roles/run.jobsExecutorWithOverrides` on that job). Put your name on the audit record with `--update-env-vars USER=<you>`. **Check:** `gcloud run jobs execute afterme-kms --region asia-south1 --wait` (default args `check`: wrap and unwrap 32 random bytes; no database). **KEK rotation:** Cloud KMS rotates the key **automatically every 90 days** (a new primary version; old versions still decrypt, nothing in the app changes). After each rotation run `gcloud run jobs execute afterme-kms --region asia-south1 --wait --update-env-vars USER=<you> --args=rewrap,--dry-run` then the same with `--args=rewrap`; it rewrites each wrapped DEK under the current primary (the DEKs and the instruction ciphertext are untouched), skips users that are busy and is safe to interrupt and re-run; re-run until its JSON says `"complete": true`. **Never disable or destroy an old key version before a `rewrap` run reported `"complete": true` after that version stopped being primary**: a disabled version that still wraps someone's DEK makes their instructions unreadable (destruction is irreversible after the 30-day scheduled-destroy window; cancel it inside the window if in doubt). **Emergency, one account (suspected exposure of a DEK):** `--args=rotate-user,<user-id>,--reason,<why>`: a new DEK, every instruction of that person re-encrypted, `dek_version` +1, audited, all in one transaction; a refusal (the person's lock is busy, the KMS refused) changes nothing and exits 2: re-run. A failing KMS pages (`kms.call_failed`, Monitoring above): check the key is enabled, the API service account still has its role, and that `KMS_KEY_NAME` was not changed (`unknown_key` = stored keys name another CryptoKey: never point production at a new key without a migration plan). Losing every key version makes all instruction content unreadable by design. |
| **Probe returns 429** | `POST /internal/probe` compares the token **first**. A wrong or missing token spends its own budget (10 per minute per client network) and answers 401 until it is used up, then 429; the right token is counted separately (60 per minute) and is never starved by wrong ones. A 429 for the *right* token therefore means the monitor is probing far more often than once a minute, or `TRUSTED_PROXY_HOPS` is wrong and every client shares one address. Fix the hop count (`--no-proxy-headers` on uvicorn; the app trusts only the configured number of proxy hops from the right), and run the monitor once a minute. |
| **Suspected breach** | [SECURITY §17](SECURITY.md#17-incident-response-summary): Hold → revoke → rotate → assess → notify. |
| **Key rotation** | JWT: add a new key, switch active `kid`, remove the old one after 15 min plus the refresh window. Pepper: set `_PREVIOUS`, rotate, re-hash on use. KMS: automatic every 90 days; then `afterme-kms` `rewrap` until `"complete": true` (Key management above). |
| **Database restore** | Restore to a new instance → point staging at it for verification → switch → **operator Hold** → review → exit. |

## 10. Domain and email deliverability

**Owner checklist for Phase 8** (nothing below can be done by the build; each unlocks the E2E tests of [TEST_PLAN §7](TEST_PLAN.md#7-end-to-end-and-operational-tests-staging)):

1. **Choose the email provider and a fallback** (PRD D13). The code supports Resend, Postmark and plain SMTP (SES, Mailgun, SendGrid through their SMTP relays), any two different ones. Recommendation: one API provider as primary and a different one as fallback; Resend gives a native idempotency key, Postmark a strong transactional reputation with separate message streams.
2. **Sending domain**: a subdomain such as `mail.<domain>`; add the provider's SPF and DKIM records; DMARC `p=quarantine` with a report address, then `p=reject` after a clean fortnight; keep marketing mail off it.
3. **Webhooks**: in each provider add `https://api.<domain>/webhooks/email/resend` (or `/postmark`) for *delivered, bounced, complained* **and failed / suppressed** events (a message the provider accepted and then could not deliver is otherwise silent); **turn open and click tracking off** (the release link is in the body: tracking would rewrite it and tell the provider who opened it); put the signing secret (Resend) or a password in the URL's Basic auth (Postmark) into `EMAIL_WEBHOOK_SECRET`.
4. **Firebase projects** `afterme-dev`, `afterme-staging`, `afterme-prod` (DEPLOYMENT §3): enable Cloud Messaging (HTTP v1), register the Android app (`app.afterme` flavors), copy API key, app id, sender id and project id into `mobile/config/*.json` (`FIREBASE_*`; not secrets), and give the backend's service account the *Firebase Cloud Messaging API Admin* role (or set `FCM_CREDENTIALS_JSON`).
5. **A minimal staging environment** with the real providers and `TEST_SUPPORT_*` **off** (configuration refuses test support with a real email provider; E2E-01 uses the staging clock router only on an isolated database with a development email provider, or is driven in real time with a short schedule).
6. **Verify** before any user: `afterme-admin email-test --to you@…` and `afterme-admin push-test --token <token of your phone>` print `ok: provider=… message_id=…` or the failure *kind*.

- Register the product domain (PRD D1). Use subdomains: `api.<domain>`, `<domain>` (web), `mail.<domain>` or `notify.<domain>` (sending).
- Email authentication: SPF, DKIM (provider keys), **DMARC** starting at `p=quarantine` with reporting, moving to `p=reject`.
- Use a dedicated sending domain or subdomain for transactional mail. No marketing email from the same domain.
- Bounce/complaint webhooks → contact status + suppression list.
- Optional: MTA-STS and TLS-RPT; BIMI later.

## 11. Cost drivers (estimate in Phase 12 with the provider calculator)

1. Managed PostgreSQL with HA (largest fixed cost).
2. Always-on worker instances (×2) and min-1 API instance.
3. Transactional email volume (low: invitations, reminders, rare alerts).
4. KMS operations (cached DEKs keep this small).
5. Error monitoring and uptime checks (free/low tiers are likely enough at launch).

SMS and WhatsApp (1.1) would be the main **variable** cost later.

## 12. Bringing up staging (and, with the same steps, production) — Phase 10

The order below is the one that was rehearsed locally in Phase 10 (a scratch PostgreSQL server, the provisioning script, `alembic upgrade head` as the owner role, then the grant tests: 40 of 42 passed; the two that failed assert development-only facts, a `NOLOGIN` maintenance role and an owner that may `SET ROLE` to it, which staging must **not** have). What it cannot prove is the cloud part: that is the first thing to do on real infrastructure.

| # | Step | Command or place | Verify |
|---|---|---|---|
| 1 | Create the cloud project, network and database instance (PostgreSQL 16 or 17; PostgreSQL 14 also works if the provisioning script is run as the user that owns schema `public`) | cloud console / IaC (Phase 12) | `sslmode=require` reachable from the runtime only |
| 2 | Generate four database passwords and the application secrets (`JWT_SIGNING_KEYS`, `HMAC_PEPPER`, `PROBE_TOKEN`, the webhook secrets: Resend's is the `whsec_…` signing secret it issues, a Postmark password must be at least 32 characters) | `backend/scripts/generate_jwt_key.py`, a CSPRNG | in the secret manager, never in a file in the repository |
| 3 | Create the roles and the database, **once** | `psql -X -v ON_ERROR_STOP=1 -d postgres -v db=afterme_staging -v owner_pw=… -v api_pw=… -v worker_pw=… -v maintenance_pw=… -f backend/scripts/provision_roles.sql` | exit 0; it refuses development passwords, short passwords and missing variables with exit 3, and it is safe to run again (that is also how a password is rotated) |
| 4 | Migrate as the owner | `AFTERME_MIGRATION_DATABASE_URL=postgresql+psycopg://afterme_owner:…@…/afterme_staging uv run alembic upgrade head` | `alembic current` is `0009` (or later) |
| 5 | Build the image (CI does it: `.github/workflows/backend.yml`, job `docker`) and deploy **three** processes from it with different commands | API: `uvicorn app.main:app --no-proxy-headers --host 0.0.0.0 --port $PORT`; worker: `python -m workers.engine`; retention: `python -m workers.maintenance --every 900` | `GET /health/ready` is 200; `python -m cli.admin status` shows the worker heartbeat |
| 6 | Point the uptime check at `POST /internal/probe` with `X-Probe-Token`, once a minute, from a dedicated address | monitor | `ingestion_probes` fills; no Hold |
| 7 | Providers: verified sending domain (SPF, DKIM, DMARC), primary and fallback email provider, webhook endpoints, Firebase project | §10 | `python -m cli.admin email-test --to …` and `push-test --token …` succeed; a bounce to a dead mailbox you own marks a test contact `bounced` |
| 8 | Alerts to a person: heartbeat, probe, backlog, provider errors, Hold | §7 | page yourself on purpose |
| 9 | Game days OPS-01…03 | [GAMEDAYS.md](GAMEDAYS.md) | recorded |
| 10 | Seed the reviewer and tester accounts if needed | app sign-up, then `python -m cli.admin user set-tier <id> premium --reason …` for Premium | audited |

**Real-time rehearsals in staging take real time.** The shortest grace period is **60 minutes** (a database CHECK, and `GRACE_MIN_MINUTES` below 60 is refused at start-up in every environment), the settle delay is at least 5 minutes in staging and production, a release stage is at least 24 h out (`MIN_RELEASE_OFFSET_MINUTES` ≥ 1440), and `TEST_SUPPORT_*` is refused with a real email provider. So a missed-check-in rehearsal takes about 1 h 10 min **if the deadline is placed by a database UPDATE** (as GAMEDAYS.md does: the schedule itself enforces a 12 h minimum window) with a Premium test account (the free presets start at a 3 h grace), and a release rehearsal about a day. The test clock (emulator suite, `make gameday`) is where speed comes from.

**A word on flavors.** The `staging` Android flavor has its own application ID and can only be installed directly (sideload); Play closed testing is for the `prod` flavor and therefore for the production backend ([BETA_PLAN §1](BETA_PLAN.md#1-the-sequencing-problem-you-need-to-decide-first)).
