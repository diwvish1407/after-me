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
| **staging** | Integration, beta backend, game days | Cloud (same shape as prod, smaller) | Managed PostgreSQL (single zone) | Real providers (sandbox/test domains), staging Firebase | `staging` |
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

# Mobile
cd mobile
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run --flavor dev --dart-define-from-file=config/dev.json
# The Android emulator reaches the host as http://10.0.2.2:8000 (cleartext allowed only in the dev flavor)
```

Exact commands are finalised and verified in Phase 1.

## 3. Hosting (proposed)

**Recommendation: Google Cloud**, because Firebase/FCM is already Google, and managed PostgreSQL with HA/PITR, KMS, Secret Manager, uptime checks and IAM come in one place. Owner decision: [PRD D12](PRD.md#15-decisions-needed-from-the-product-owner). **Region** follows the launch market (D3), e.g. `asia-south1` (Mumbai) for India-first, `europe-west*` for EU-first.

| Concern | Service | Prod | Staging |
|---|---|---|---|
| API + web pages | Cloud Run service `afterme-api`, custom domain, HTTPS | min 1 instance (no cold check-ins), max N; Cloud Armor / ingress protection when public | min 0–1 |
| Worker | Always-on container: Cloud Run worker pool (if GA in the region) **or** Cloud Run with CPU always allocated and min instances, **or** a small VM | **2 instances** (safe via `SKIP LOCKED`) | 1 |
| Database | Cloud SQL for PostgreSQL 16/17, private IP | **Regional HA**, automated backups, PITR | Single zone, backups |
| Keys | Cloud KMS keyring `afterme`, key `instruction-kek` (auto-rotation 90 days) | ✓ | ✓ (separate keyring) |
| Secrets | Secret Manager | ✓ | ✓ |
| Images | Artifact Registry | ✓ | ✓ |
| Probe / uptime | Cloud Monitoring uptime check → `POST /internal/probe` (through the public domain) every 60 s | ✓ | ✓ |
| Logs / metrics / alerts | Cloud Logging (30-day retention), log-based metrics, alerting policies | ✓ | ✓ |
| Push | Firebase project `afterme-prod` | ✓ | `afterme-staging` |
| Identity for CI | Workload Identity Federation (no long-lived keys) | ✓ | ✓ |

**Alternative (simpler, less integrated):** a container PaaS (Render/Fly/Railway) + managed Postgres + a standalone KMS. This is acceptable for staging, but production needs equivalent HA, PITR, KMS and uptime probing.

## 4. Configuration and secrets

All configuration comes from environment variables (prefix `AFTERME_`), validated at startup by `pydantic-settings`. **(S)** = secret, from Secret Manager in staging/prod.

| Variable | Notes |
|---|---|
| `APP_ENV` | `dev` · `test` · `staging` · `prod` |
| `PUBLIC_BASE_URL`, `API_BASE_URL` | HTTPS required outside dev |
| `DATABASE_URL` **(S)** | `afterme_api` role |
| `WORKER_DATABASE_URL` **(S)** | `afterme_worker` role |
| `MIGRATION_DATABASE_URL` **(S)** | `afterme_owner` role (migration job only) |
| `DB_POOL_SIZE`, `DB_STATEMENT_TIMEOUT_MS`, `API_LOCK_TIMEOUT_MS` | |
| `JWT_SIGNING_KEYS` **(S)**, `JWT_ACTIVE_KID`, `JWT_ISSUER`, `JWT_AUDIENCE` | Ed25519 keys as JSON `{kid: pem}` |
| `HMAC_PEPPER` **(S)**, `HMAC_PEPPER_PREVIOUS` **(S)** | Dual-check during rotation |
| `KMS_PROVIDER`, `KMS_KEY_NAME` | `local` is refused in prod |
| `LOCAL_KEK` **(S, dev/test only)** | |
| `EMAIL_PROVIDER`, `EMAIL_API_KEY` **(S)**, `EMAIL_FROM`, `EMAIL_WEBHOOK_SECRET` **(S)** | `console` is refused in prod |
| `EMAIL_FALLBACK_PROVIDER`, `EMAIL_FALLBACK_API_KEY` **(S)** | Optional |
| `FCM_PROJECT_ID` | Service identity via Workload Identity on GCP (no key file) |
| `PROBE_TOKEN` **(S)** | Uptime-check header |
| `SENTRY_DSN`, `SENTRY_TRACES_SAMPLE_RATE` | |
| `TRUSTED_PROXY_HOPS` | For client IP extraction |
| `TICK_SECONDS`, `SETTLE_DELAY_SECONDS`, `INGESTION_STALE_SECONDS`, `HOLD_*`, `ANOMALY_FLOOR_PER_HOUR`, `ACTION_MAX_ATTEMPTS`, … | All parameters in [ESCALATION_ENGINE §13](ESCALATION_ENGINE.md#13-configuration) (prefix `AFTERME_`); unsafe values refused at startup (`SETTLE_DELAY_SECONDS` must exceed `INGESTION_STALE_SECONDS`; in prod `MIN_RELEASE_OFFSET_MINUTES >= 1440` and `SETTLE_DELAY_SECONDS >= 300`). `WORKER_DATABASE_URL` and `PROBE_TOKEN` are required in staging and prod. |
| `TEST_ROUTER_ENABLED` | Staging only; startup fails if set in prod |
| `GOOGLE_PLAY_PACKAGE_NAME` | Billing (later) |
| `LOG_LEVEL` | Default `INFO` |

The mobile app has **no secrets**. `config/<env>.json` holds only the API base URL, environment name and the (public) Sentry DSN. Firebase `google-services.json` files are per flavor; they are public identifiers, but the repo is still kept private.

## 5. CI/CD

```
PR opened ─▶ backend checks + mobile checks (TEST_PLAN §10) ─▶ review ─▶ merge to main
main ──────▶ build image ─▶ migrate staging ─▶ deploy staging (api, worker) ─▶ smoke tests
tag vX.Y.Z ─▶ manual approval ─▶ backup snapshot ─▶ migrate prod ─▶ deploy api ─▶ deploy worker ─▶ smoke ─▶ watch
mobile tag ─▶ flutter build appbundle (prod) ─▶ upload symbols ─▶ Play internal track (manual promotion)
```

- Git hosting: GitHub recommended (Actions, Dependabot, branch protection). The repository is **private**.
- Migrations always run **before** new code. They are backward compatible with the currently running version (expand/contract, [DATABASE §8](DATABASE.md#8-migrations-policy)).
- Rollback: redeploy the previous image (schema remains compatible). Destructive migrations are never part of the same release.
- The backend stays compatible with the **two most recent app versions**. Older apps can be forced to update via `min_client_version` (→ `426`).

### 5.1 Mobile build and signing

```bash
flutter build appbundle --flavor prod --release \
  --obfuscate --split-debug-info=build/symbols \
  --dart-define-from-file=config/prod.json
```

- **Play App Signing**: Google holds the app signing key; we hold the **upload key**.
- The upload keystore lives in a password manager **plus** an offline backup. CI receives it as an encrypted secret. Losing it is recoverable via a Play support reset, but slowly.
- Versioning: `versionName` = semver; `versionCode` = monotonically increasing build number.
- Obfuscation symbols are uploaded to error monitoring and stored privately.

## 6. Backups and recovery

| Item | Target |
|---|---|
| Automated backups | Daily, retained 30 days |
| Point-in-time recovery | 7 days |
| **RPO** | ≤ 5 min |
| **RTO** | ≤ 1 h |
| Restore test | Quarterly (OPS-05), documented |
| Backup access | Restricted IAM; encrypted |
| Deleted-user data in backups | Ages out within ≤ 35 days (stated in the privacy policy) |

After any restore, the engine enters **operator Hold** automatically. A restored database may be missing recent check-ins, so an operator reviews before resuming (exit with shift).

## 7. Monitoring and alerting

Alerts go to the owner's phone (push/SMS from the monitoring service) and email. **Paging alerts:**

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

**Non-paging:** provider failure rate > 5%; bounce/complaint rates; p95 latency; certificate expiry (< 21 days); Play Android vitals (crash/ANR) thresholds.

Dashboards: check-ins/hour, incidents opened/resolved/escalated/cancelled, messages by template and status, Hold history, worker lag.

## 8. Release process

1. Changelog entry; version bump.
2. Staging deploy + automated e2e + manual checklist for the affected areas.
3. Production backend deploy (tag). Watch dashboards for 30 min.
4. Mobile: internal track → closed testing → production **staged rollout** (10% → 25% → 50% → 100%), each step after vitals and error checks.
5. Post-release review of incidents and alerts in the first 48 h.

## 9. Runbooks

| Situation | Steps |
|---|---|
| **Hold entered (ingestion)** | Check the uptime-check status and ingress; check the API health/logs; fix. Hold exits automatically after 10 min of fresh probes; verify `system.hold_exited` and the shift counts. |
| **Hold entered (anomaly)** | Inspect recent incidents (counts by app version, region, time); look for a bad app release or a push/email outage. If it's a bug: `afterme-admin incident void <incident-id>` for each affected incident (audited; the person's schedule restarts a full interval from then and they are told). Otherwise `afterme-admin hold exit` (shift applied; it will not re-enter over the same burst). |
| **Page: hold evaluation failing** | The worker ticks but cannot evaluate Hold, so it is treating the state as a Hold: no incidents open and no contact-facing message leaves; user reminders still go. Read `engine.hold_failed` (error class only) and fix the cause (a bad watermark row, a statement timeout, a missing grant). It clears by itself on the next good evaluation. |
| **Page: messages given up on** | A contact-facing message failed for 24 h from its first attempt. Find it with the audit event `notification.failed`; the person is not told automatically (Phase 8). Decide with the owner whether to contact the person or the contact another way. |
| **Worker down** | Restart; check heartbeats; confirm the catch-up behaviour (anchor rule) in logs; check for held actions. |
| **Email provider outage** | Confirm the fallback switched; if there is no fallback, consider entering operator Hold *only* if alerts would arrive misleadingly late. Communicate via status page. |
| **Push outage** | No action needed for safety (email in parallel); monitor reminder delivery. |
| **Held action / consistency violation** | Never "force execute". Investigate the data and fix the root cause. An action that failed only for its own reasons can be put back with `afterme-admin action retry <action-id>` (audited): it goes through the whole safety gate again and a stage that is by then overdue by more than the limit is held again rather than run. Infrastructure errors (connection loss, lock timeouts) never hold an action. |
| **Probe returns 429** | `POST /internal/probe` is rate limited per client address (10/min) *before* the token is checked. Run the monitor from a dedicated address and do not put it behind a shared NAT or proxy that other clients use, or stale probes will start a Hold. (`TRUSTED_PROXY_HOPS` must match the real proxy chain.) |
| **Suspected breach** | [SECURITY §17](SECURITY.md#17-incident-response-summary): Hold → revoke → rotate → assess → notify. |
| **Key rotation** | JWT: add a new key, switch active `kid`, remove the old one after 15 min plus the refresh window. Pepper: set `_PREVIOUS`, rotate, re-hash on use. KMS: enable a new version; run the re-wrap job. |
| **Database restore** | Restore to a new instance → point staging at it for verification → switch → **operator Hold** → review → exit. |

## 10. Domain and email deliverability

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
