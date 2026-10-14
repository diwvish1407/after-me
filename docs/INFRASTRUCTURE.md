# AfterMe — Production infrastructure (Google Cloud)

| | |
|---|---|
| **Status** | Phase 12. Written and statically validated (`terraform fmt`, `terraform validate`); **never planned or applied**: the Google Cloud projects do not exist yet. Section 14 lists every assumption about Google Cloud that must be checked at the first apply |
| **Code** | [`infra/`](../infra/README.md) (Terraform, scripts, bring-up sequence and costs) · [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) · [`infra.yml`](../.github/workflows/infra.yml) |
| **Related** | [DEPLOYMENT](DEPLOYMENT.md) · [SECURITY §6, §12, §16, §17](SECURITY.md) · [ESCALATION_ENGINE §7, §12](ESCALATION_ENGINE.md) · [GAMEDAYS](GAMEDAYS.md) · [ONCALL](ONCALL.md) |

Principle for everything below: **fail-safe, not fail-trigger.** A wrongly sent alert to a contact is severity 1; an alert that silently never arrives is also a failure. So: every guard that can stop contact-facing effects (Hold) is easy to reach and loud; every monitor has a monitor watching it; nothing here may make a person's check-in fail.

---

## 1. Decisions

| Topic | Decision |
|---|---|
| Cloud, region | Google Cloud, **asia-south1 (Mumbai)**; one project per environment (`afterme-staging`, `afterme-prod`, which are also the Firebase projects) |
| Domains | `afterme.app` (public pages), `api.afterme.app` (API); staging `staging.afterme.app`, `api.staging.afterme.app`. DNS on **Cloudflare, proxy OFF** on every record that points at Google or at a mail provider |
| Front door | Global external **Application Load Balancer** + Google-managed certificate + serverless NEG → Cloud Run. **Not** a Cloud Run domain mapping (§7.4) |
| API | Cloud Run service `afterme-api`, ingress *internal and Cloud Load Balancing* only, `run.app` URL disabled, CPU **always allocated** (§4.1), min 1 / max 7 (prod) |
| Worker | Cloud Run **worker pool** `afterme-worker`, 2 instances (prod) / 1 (staging), `python -m workers.engine` |
| Retention | Cloud Run **job** `afterme-maintenance` started every 15 min by Cloud Scheduler (§4.3) |
| Migrations | Cloud Run job `afterme-migrate` (`alembic upgrade head` as `afterme_owner`), run and awaited by CI **before** any new code |
| Database | Cloud SQL for PostgreSQL 17, Enterprise edition, private IP only, TLS required; prod regional HA + PITR (7 days) + 30 daily backups + deletion protection |
| Keys | Cloud KMS keyring `afterme`, key `instruction-kek` (AES-256-GCM, software, rotation 90 days, `prevent_destroy`); only the API's service account may use it |
| Secrets | Secret Manager, regional (asia-south1), empty shells in Terraform, values added out of band |
| Watching | Uptime check + a Cloud Run **watchdog job** that runs `cli.admin status` every 2 minutes (§11) |
| CI identity | GitHub Actions through Workload Identity Federation; no service-account key exists |
| Email | Resend primary, Postmark fallback (the application already supports the pair) |

## 2. Architecture

```
                       Android app / browsers / contacts' mail clients
                                          │  HTTPS (TLS ≥ 1.2, HSTS)
                                          ▼
 Cloudflare DNS (proxy OFF) ──A──▶  static IPv4  ◀── uptime check (3 regions, POST /internal/probe, 60 s)
                                          │
                 ┌────────────────────────┴─────────────────────────┐
                 │  Global external Application Load Balancer        │  Google-managed certificate
                 │  (port 80 only redirects)   [Cloud Armor: off]    │  for api.* and the public host
                 └────────────────────────┬─────────────────────────┘
                                          │  serverless NEG (asia-south1)
 ┌────────────────────────────────────────▼─────────────────────────────────────────────────────────┐
 │ GOOGLE CLOUD PROJECT  afterme-prod                                                                  │
 │                                                                                                     │
 │  Cloud Run service  afterme-api  (sa: afterme-api)                                                  │
 │     ingress: load balancer only · min 1 · CPU always on · Direct VPC egress (private ranges only)   │
 │        │ TCP+TLS 5432 (private IP)            │ HTTPS: Cloud KMS wrap/unwrap (sa-api ONLY)          │
 │        ▼                                      ▼                                                     │
 │  ┌────────────────────┐              ┌──────────────────────────────┐                               │
 │  │ Cloud SQL PG 17    │◀── private ──│ Cloud KMS keyring afterme     │                               │
 │  │ regional HA + PITR │   services   │ key instruction-kek           │                               │
 │  │ no public IP       │   access     └──────────────────────────────┘                               │
 │  └─────▲─────▲────▲───┘                                                                             │
 │        │     │    │                                                                                 │
 │  Cloud Run worker pool  afterme-worker ×2 (sa: afterme-worker; no KMS; role afterme_worker)         │
 │        │  HTTPS out: Resend, Postmark, FCM (sa-worker has FCM send)                                 │
 │  Cloud Run jobs (sa per job, no HTTP):                                                              │
 │     afterme-migrate (afterme_owner) · afterme-maintenance (afterme_maintenance, every 15 min)       │
 │     afterme-status-check (watchdog, every 2 min) · afterme-backup-check (every 6 h)                 │
 │     afterme-admin + afterme-oncall-{status,hold-status,hold-enter,hold-exit} (worker role)          │
 │                                                                                                     │
 │  Secret Manager (12 shells)   Artifact Registry `afterme`   Cloud Scheduler (3 jobs)                │
 │  Cloud Monitoring: uptime check, 18 alert policies, dashboard · Cloud Logging (30 days)             │
 │  Workload Identity pool `github` ──▶ sa: afterme-cicd (deploy only)                                 │
 │  [optional, while provisioning] admin VM: no public IP, IAP SSH, Cloud NAT                          │
 └─────────────────────────────────────────────────────────────────────────────────────────────────────┘
        ▲                                                       │
        │ OIDC token (repo + workflow + ref)                    │ pages: e-mail + SMS (2 people)
   GitHub Actions: deploy.yml                                   ▼
                                                           on-call people → Cloud Run jobs (console / phone)
```

Staging is the same picture with `db-custom-1-3840` zonal, one worker, no HA.

## 3. Trust boundaries

1. **Internet → load balancer.** Everything from a client is untrusted (SECURITY §4). The load balancer terminates TLS; Cloud Run accepts requests **only** from it (ingress setting plus the disabled `run.app` URL), so there is exactly one path to the application and the client-address analysis in §7 holds.
2. **Load balancer → API → database.** The application connects with TLS over private IP as `afterme_api`; the API cannot insert incidents, actions or releases (grants). The database has no public address and is reachable only from the VPC (Cloud Run Direct VPC egress, the optional admin VM).
3. **API ↔ KMS.** Only `afterme-api` has `cryptoKeyEncrypterDecrypter`, on the one key. The worker decides releases without ever being able to open one ([SECURITY_REVIEW BD-5](SECURITY_REVIEW.md)). KMS calls are Data Access audit-logged.
4. **Worker → providers.** The worker is the only process that sends mail and push. FCM uses its own identity (no key file).
5. **Operators → jobs.** People never get a database credential or a shell. They run fixed Cloud Run jobs; the run is recorded in Cloud Audit Logs with their Google identity, which is the operator identity that [SECURITY_REVIEW F-08](SECURITY_REVIEW.md) asks for (`--operator` is only a label).
6. **GitHub → Google.** Keyless. A token is accepted only from this repository (by name, and by numeric id if configured), the workflow file `deploy.yml`, the allowed ref (prod: `main` only; staging: `main` or `v*` tags) and the matching GitHub Environment. CI can deploy and run jobs; it cannot read a secret, cannot use the key, cannot change IAM, and can act only as the five runtime accounts.
7. **Terraform → Google.** Run by a person on their own machine with their own credentials. No pipeline holds Owner.

## 4. Compute

### 4.1 The API: CPU always allocated

`cpu_idle = false` (CPU is not throttled between requests). The brief assumed this was not needed; it is, because the API sends mail from FastAPI **background tasks that start after the response** (`app/auth/router.py`, `app/contacts/router.py`, `app/web/router.py`: password reset, invitations, email-change codes). With request-based billing Cloud Run may throttle the CPU as soon as the response is out, and the mail then waits for the next request or never leaves: the "silently never arrives" failure, for a password-reset or an invitation. Cost: about USD 40 a month more per instance than request-based billing. It can be switched off (`api_cpu_always_allocated = false`) once those mails go through the outbox (README "Known limitations" already plans it).

Other settings, with reasons: concurrency 20 (login hashing is CPU-heavy: Argon2id 64 MiB), 1 vCPU / 1 GiB, request timeout 60 s, **startup probe `/health/ready`** (a revision whose database is unreachable or whose schema is behind never gets traffic, which is why migrations run first), **liveness probe `/health/live`** (never the database: an outage must not restart the API), uvicorn started exactly as the Dockerfile's `CMD` with `--no-proxy-headers`.

Connection budget: each process opens two pools of `DB_POOL_SIZE + DB_MAX_OVERFLOW` (main + bookkeeping). The API uses 3 + 1, so 8 connections per instance and `max 7 instances × 8 = 56`, plus 2 for the `afterme-kms` job = 58 ≤ 60, the `afterme_api` limit in `provision_roles.sql`. **Worker: a pool of 14 + 0** = `UNIT_CONCURRENCY` (4 units of a tick page) + dispatcher `CONCURRENCY` (8 concurrent sends) + 2 (the page reader / Hold evaluation / stuck-row recovery session, and a failed unit's attempt count or a replaced connection). Ticks and passes run one after the other today; sized for both at once, no unit and no settle (tx B) after a provider accepted ever waits for a connection (a settle that times out leaves the row `sending` and it is re-sent after 5 minutes: [ESCALATION_ENGINE §8.3](ESCALATION_ENGINE.md#83-retries-and-failure)). `workers/engine.py` **refuses to start** with less. The worker never uses its bookkeeping pool, so 2 instances × 14 = 28, plus the six operator/watchdog jobs on the same role (1 + 0, two pools: 12) = 40 ≤ 48, the `afterme_worker` limit (raised from 20; re-run `provision_roles.sql`). Maintenance: 1 + 0 pool, 2 connections ≤ 5. Terraform refuses a plan that breaks either role budget (`terraform_data.connection_budget` in `modules/run`) or whose peak (API + worker + retention 2 + owner 5 + 10 reserved for Cloud SQL and the administrator) exceeds 80% of `max_connections` (`modules/stack`): prod 58 + 40 + 17 = 115 ≤ 160 of 200, staging 26 + 26 + 17 = 69 ≤ 80 of 100.

### 4.2 The worker: a worker pool

`python -m workers.engine` opens no port, and a Cloud Run **service** must answer HTTP, so a service cannot run it. A Cloud Run **worker pool** (instance-billed, no ingress, manual instance count) is the product built for it. Two instances in production are safe by design (`SKIP LOCKED`, dedupe keys). Restart on crash is the platform's. If worker pools turn out to be unavailable in the region, the fallback is a two-instance managed instance group of Container-Optimized OS VMs running the same image; the Terraform for that is not written.

### 4.3 Maintenance: a scheduled job, not a third always-on instance

`python -m workers.maintenance --every 900` would be a permanent third instance (about USD 50 a month) whose death nobody notices. A **Cloud Run job** run by Cloud Scheduler every 15 minutes (`python -m workers.maintenance`, which runs once and exits) is cheaper, has a hard timeout of 10 minutes (two runs never overlap), and **a failed run is an alert** (`run.googleapis.com/job/completed_execution_count{result=failed}`, plus an absence alert when no run happened for an hour). Nothing safety-relevant waits on it ([DEPLOYMENT §9](DEPLOYMENT.md#9-runbooks)), so 15-minute granularity costs nothing.

### 4.4 The watchdog

Every paging condition that lives in the database (worker heartbeat > 2 min, Hold evaluation failing, held actions, messages given up, consistency violations, due action or queued message > 5 min late) is judged by `python -m cli.admin status`, which exits 1 exactly when something would page. The job `afterme-status-check` runs it every 2 minutes; a failed execution pages; no execution for 10 minutes pages. Detection latency is therefore the application's threshold plus at most 2 minutes. The thresholds live in one place (`app/ops/admin.py`) and cannot drift from the alert. Hold, consistency violations and held actions also page **immediately** from their critical log lines.

### 4.5 Jobs for people

`afterme-oncall-status`, `-hold-status`, `-hold-enter`, `-hold-exit` have their arguments fixed in Terraform, so a person taps *Execute* and nothing can be mistyped. `afterme-admin` takes its arguments at execution time (`incident void <id>`, `action retry <id>`) and is granted as `run.jobsExecutorWithOverrides`. All run as `afterme-admin`, which holds the worker database role only. See [ONCALL](ONCALL.md).

`afterme-kms` is the one job that runs as **`afterme-api`** with the API's `database-url`: the key commands (`kms check | rewrap | rotate-user`) need both the API database role (the only one with `user_keys`) and KMS EncrypterDecrypter, which only the API account has. Its command is fixed to `python -m cli.admin kms` (an execution chooses only the kms subcommand and its arguments), it is never scheduled, and only `oncall_principals` hold `run.jobsExecutorWithOverrides` on it. Procedure: [DEPLOYMENT §9](DEPLOYMENT.md#9-runbooks), Key management.

## 5. Service accounts

| Account | Runs | Can do | Cannot do |
|---|---|---|---|
| `afterme-api` | API service | read its secrets (database URL, JWT keys, pepper, probe token, provider keys); `cryptoKeyEncrypterDecrypter` on `instruction-kek` | send push; read the worker/owner/maintenance database URLs |
| `afterme-worker` | worker pool | read its secrets (worker database URL + the shared settings secrets); send FCM (`firebasecloudmessaging.admin`) | any KMS call; read the API/owner/maintenance URLs |
| `afterme-maintenance` | retention job | read its secrets (maintenance database URL + shared) | KMS, FCM, other URLs |
| `afterme-migrate` | migration job | read **one** secret: `migration-database-url` (`afterme_owner`) | everything else; nothing else ever holds the owner password |
| `afterme-admin` | operator jobs | like the worker (worker database URL, shared secrets, FCM for `push-test`) | KMS |
| `afterme-scheduler` | Cloud Scheduler | `run.invoker` on the three scheduled jobs | everything else |
| `afterme-backupcheck` | backup freshness job | read Cloud SQL backup and instance metadata (custom role) | everything else |
| `afterme-cicd` | GitHub Actions | `run.developer` (deploy services, worker pool, jobs; execute jobs); Artifact Registry writer on `afterme`; create/list Cloud SQL backups (custom role); `serviceUsageConsumer`; `serviceAccountUser` on the five runtime accounts | read any secret; use KMS; edit IAM; touch Cloud SQL beyond backups |
| admin VM account (only while the VM exists) | admin VM | add versions to the four database URL secrets | read them |

No service-account key is created by Terraform or by the runbooks. Humans: the Owner role belongs to the product owner; on-call people get only: run the on-call jobs, and view Cloud Run, logs and monitoring.

**Consequence of the single `Settings` class.** Every process loads and validates the same `Settings`; in staging/prod it insists on JWT keys, pepper, probe token, webhook secrets and all three database URLs *set explicitly with TLS or a loopback host*. So the worker, maintenance and admin jobs must hold the shared secrets although they do not use some of them, and each process receives an **unusable loopback placeholder** (`postgresql+psycopg://unused:unused@127.0.0.1:1/unused?sslmode=require`) for the two database URLs it does not own, so the worker never holds the API's database password. Splitting `Settings` per process in the backend would let both workarounds go; it is recommended, not required.

## 6. Secrets inventory

Created as empty shells, replicated to asia-south1 only. Nothing is read or written by Terraform. Variables marked (S) in [DEPLOYMENT §4](DEPLOYMENT.md#4-configuration-and-secrets):

| Secret | Variable | Read by | How it is made |
|---|---|---|---|
| `database-url` | `AFTERME_DATABASE_URL` | api | `db_bootstrap.sh` (role `afterme_api`) |
| `worker-database-url` | `AFTERME_WORKER_DATABASE_URL` | worker, admin | `db_bootstrap.sh` |
| `maintenance-database-url` | `AFTERME_MAINTENANCE_DATABASE_URL` | maintenance | `db_bootstrap.sh` |
| `migration-database-url` | `AFTERME_MIGRATION_DATABASE_URL` | migrate | `db_bootstrap.sh` |
| `jwt-signing-keys` | `AFTERME_JWT_SIGNING_KEYS` | api, worker, maintenance, admin | `generate_jwt_key.py` via `add_app_secrets.sh` |
| `hmac-pepper` | `AFTERME_HMAC_PEPPER` | same four | `add_app_secrets.sh` |
| `hmac-pepper-previous` | `AFTERME_HMAC_PEPPER_PREVIOUS` | same four, **mounted only during a rotation** (`hmac_pepper_previous_enabled`) | by hand |
| `probe-token` | `AFTERME_PROBE_TOKEN` | same four; the uptime check header | `add_app_secrets.sh`, then `set_probe_header.sh` |
| `email-api-key` | `AFTERME_EMAIL_API_KEY` | same four | Resend dashboard |
| `email-webhook-secret` | `AFTERME_EMAIL_WEBHOOK_SECRET` | same four | Resend: the `whsec_…` signing secret |
| `email-fallback-api-key` | `AFTERME_EMAIL_FALLBACK_API_KEY` | same four | Postmark server token |
| `email-fallback-webhook-secret` | `AFTERME_EMAIL_FALLBACK_WEBHOOK_SECRET` | same four | `add_app_secrets.sh` (32+ chars); you type it into Postmark's webhook URL |

Not created, and why: `TEST_SUPPORT_TOKEN` (refused in prod, unusable in staging), `LOCAL_KEK` (dev only), `FCM_CREDENTIALS_JSON` (the worker uses its own identity), `SMTP_PASSWORD` (SMTP is not used), `SENTRY_*` (no Sentry setting exists in the backend). Secrets are read at instance start (`version: latest`): after adding a version, **restart** (redeploy) the services that mount it.

**The one secret outside Secret Manager's reach: the uptime check header.** A Monitoring uptime check stores the `X-Probe-Token` value in its own configuration (masked in the console). Terraform creates the check with a placeholder and ignores the header; `infra/scripts/set_probe_header.sh` copies the token from Secret Manager into the check through the Monitoring API. The token therefore never enters Terraform state, but it does sit in the check's configuration; anyone with `monitoring.uptimeCheckConfigs.get` can read it. A leaked probe token lets someone feed fake probes (and so hide an outage from the Hold); rotate it as in [DEPLOYMENT §9](DEPLOYMENT.md#9-runbooks) if in doubt. Until the script has run, the probe answers 401, the check fails and the engine enters Hold: loud and safe.

## 7. The client address: `TRUSTED_PROXY_HOPS`

The application finds the client address itself (`app/core/net.py`): it takes `X-Forwarded-For`, splits it, and takes the entry **N places from the right**, where N is `AFTERME_TRUSTED_PROXY_HOPS`. Each trusted proxy appends the address it received the connection from, so the rightmost N entries were written by our own infrastructure, and entry `len − N` is the client. Anything left of it was written by the client and is ignored. If the header has fewer than N entries the code falls back to the socket peer. uvicorn runs with `--no-proxy-headers`, otherwise it would rewrite the peer from the header first.

### 7.1 What is in front of the application here

```
client ──▶ Google front end ──▶ global external Application Load Balancer ──▶ (serverless NEG) ──▶ Cloud Run instance
```

Google documents that an external Application Load Balancer sets the header to `<client-supplied value>,<client IP>,<load balancer's forwarding-rule IP>` when the client sent one, and `<client IP>,<load balancer IP>` when not. **The load balancer appends two entries.** The client is the **second from the right**. With nothing else in between (Cloud Run's own front end passes the header through, to the best of our knowledge) the correct value behind this stack is:

> **`TRUSTED_PROXY_HOPS = 2`** (set in `envs/*/variables.tf`, default 2).

### 7.2 If the stack were different

| Front end | Entries appended | Client is | Value |
|---|---|---|---|
| This stack: global external ALB → Cloud Run | 2 (client IP, forwarding-rule IP) | 2nd from the right | **2** |
| Cloud Run reached directly (`run.app` or a domain mapping), no load balancer | 1 (the client IP the Google front end saw) | the rightmost | 1 |
| This stack **with Cloudflare proxy ON** in front of the ALB | 3 (Cloudflare adds the client; the ALB adds the Cloudflare edge IP and its own) | 3rd from the right | 3. **Not used: the proxy is OFF**, and with it on the Google-managed certificate would not even issue |
| Cloud Armor attached to the backend service | no change (Armor does not touch the header) | — | unchanged |

### 7.3 What goes wrong when it is wrong

| Setting vs reality | Effect |
|---|---|
| **Too low** (1 behind the ALB) | The client address resolved is the load balancer's: **every client shares one address**. Per-IP limits (login, probe, `/c` pages) become global: ordinary users can be answered `429` because of each other. This is the dangerous direction for a safety product (a refused check-in is a missed deadline). The probe's wrong-token budget (10 a minute) is shared by everyone too. |
| **Too high** (3 behind the ALB) | A client who sends their own `X-Forwarded-For` chooses the address the application sees: rate limits are bypassed and `ip_hash` values are forged. Not a safety failure, but a security one. |
| Fewer entries than N | Falls back to the socket peer (a Google address): same as "too low". |

### 7.4 Why a load balancer and not a domain mapping

Cloud Run *domain mappings* are a Preview feature, limited to some regions (asia-south1 was **not** among them when this was written; **verify**), slower and without ingress restriction or Cloud Armor. With a mapping the value would be 1 and the `run.app` URL would stay reachable (a second path with a different header shape). The load balancer costs about USD 18 a month and gives one path in, a static IP, TLS policy and the OPS-01 ingress switch (GAMEDAYS).

### 7.5 Verification (required, in staging, before any user)

Documentation is not proof. `infra/scripts/verify_client_ip.sh` sends only wrong-token probes (their own budget; the real monitor is unaffected):

1. `… spoof` from your laptop: 13 requests, each with a different forged `X-Forwarded-For`. With the right value the forged entries are ignored and the 11th answer is `429`. **No 429 means the value is too high: FAIL.**
2. Immediately, from a phone on mobile data (a different network): `… plain`. It must answer `401` three times. **A 429 means both networks share one bucket: the value is too low: FAIL.**

Pass on both = correct (given that the two networks differ). If the pair fails, change `trusted_proxy_hops`, `terraform apply`, redeploy, repeat. `deploy.yml` runs step 1 on every staging deploy so a change to the front end cannot silently make the value too high. Step 2 needs a second network and is part of the bring-up and of every change to the load balancer.

## 8. Network and data flow

* One VPC `afterme-vpc`, one subnet `afterme-run` (10.10.0.0/24) for Cloud Run **Direct VPC egress** (no connector instances to pay for), egress `PRIVATE_RANGES_ONLY`: only private destinations (the database) go through the VPC; mail providers, FCM and Google APIs use Cloud Run's normal internet path, so there is no NAT to pay for or to fail.
* Private services access reserves a /24 for Cloud SQL. The instance has `ipv4_enabled = false`, `ssl_mode = ENCRYPTED_ONLY`, and the three application URLs carry `sslmode=require` (the application refuses anything weaker).
* The load balancer terminates TLS 1.2+ (policy MODERN); the hop to Cloud Run is Google-internal. HSTS comes from the application.
* **Data flow of a check-in:** app → LB → `afterme-api` → Cloud SQL. **Of an alert:** `afterme-worker` ticks → opens the incident → settle delay → dispatcher → Resend (or Postmark) → contact's mailbox → contact opens the portal link → LB → `afterme-api` → KMS unwrap → decrypt → page. Instruction text never appears in a log, an e-mail or a push.
* **Logs:** JSON on stdout (redacted by the application) → Cloud Logging `_Default`, retention **30 days**. The load balancer logs method, URL, status and sizes only (`EXCLUDE_ALL_OPTIONAL`); health and probe lines are excluded as noise; any entry carrying a `body`-like field is excluded from storage. Cloud SQL statements are **not** logged (`log_statement=none`; DDL logging would write `ALTER ROLE … PASSWORD` to the log).
* **Optional admin VM** (`admin_vm_enabled`): created only to run `provision_roles.sql` and look at a restored scratch instance. No public IP, SSH only through IAP with OS Login, Cloud NAT for apt. Destroy it afterwards.

## 9. DNS and mail (Cloudflare, by hand)

`terraform output dns_records` prints the exact web records. All **proxy OFF (DNS only)**.

| Record | Name | Value | Notes |
|---|---|---|---|
| A | `api.afterme.app` | the load balancer IP | TTL auto |
| A | `afterme.app` | the load balancer IP | the apex: Cloudflare "CNAME flattening" is not needed for an A |
| CAA | `afterme.app` | `0 issue "pki.goog"` | only if the zone has CAA records; keep the existing ones. Google issues the certificate |
| CAA | `afterme.app` | `0 iodef "mailto:security@afterme.app"` | optional |
| A | `api.staging.afterme.app`, `staging.afterme.app` | the staging load balancer IP | the staging project has its own IP |

The managed certificate becomes ACTIVE only after the names resolve to the IP (typically 15 to 60 minutes, up to a day); until then HTTPS fails. **No TXT domain-verification record is needed**: that exists only for Cloud Run domain mappings.

**Mail records are not in Terraform.** They come from the providers' dashboards (exact host names and keys differ per account); create exactly what each shows, DNS only:

* **Resend** (primary), for the sending subdomain `mail.afterme.app`: the SPF TXT, the DKIM TXT (`resend._domainkey…`) and the MX/return-path record it lists.
* **Postmark** (fallback), same subdomain: the DKIM TXT (`<selector>._domainkey…`) and the Return-Path CNAME (`pm-bounces…`) it lists. Both providers on one subdomain need **one** SPF record that includes both; check the merged record is a single TXT with one `v=spf1`.
* **DMARC**: TXT `_dmarc.afterme.app` = `v=DMARC1; p=quarantine; rua=mailto:dmarc@afterme.app`, then `p=reject` after a clean fortnight ([DEPLOYMENT §10](DEPLOYMENT.md#10-domain-and-email-deliverability)).
* **Webhooks** (provider dashboards): `https://api.afterme.app/webhooks/email/resend` and `…/postmark` (delivered, bounced, complained **and** failed/suppressed; **tracking off**).
* `support@afterme.app`, `abuse@afterme.app`, `security@afterme.app`, `dmarc@afterme.app` must be mailboxes someone reads (Cloudflare Email Routing is enough).

## 10. CI/CD

`deploy.yml`: tag `v*` → staging automatically; *Run workflow* → staging or production. Production runs from `main` only, behind the GitHub Environment `production` (required reviewers). Steps and their reasons:

1. `plan` job (no Google access): resolves the environment and the commit; refuses a commit that is not an ancestor of `origin/main`.
2. `deploy` job (`id-token: write`, the only one): authenticate through Workload Identity Federation; build the image; push; take the **digest**.
3. Production only: `gcloud sql backups create` (the custom role allows exactly this).
4. Run `afterme-migrate` and wait; a failure stops here with traffic untouched.
5. Deploy the API by digest; the startup probe gates the traffic.
6. `smoke.sh` through the public domain (`/health/live`, `/health/ready`, `/v1/version`, `POST /internal/probe` without a token → 401). **Automatic rollback of everything** (`rollback.sh`: the API, the worker pool and every job) to the previous digest if the smoke test fails; the step fails loudly, listing what was not rolled back, if any update fails.
7. Deploy the worker pool and the jobs by the same digest.
8. Staging: the client-address spoof check ([§7.5](#75-verification-required-in-staging-before-any-user)).

Rollback by hand: `infra/scripts/rollback.sh <project> <region> <previous image digest>`; the previous digest is printed in every run's summary. Schema stays as migrated: migrations are expand-only ([DEPLOYMENT §5](DEPLOYMENT.md#5-cicd), checked by `tests/security/test_migration_expand_contract.py`), and `/health/ready` accepts a schema that is *ahead* of the image (a revision the image does not know) while refusing one that is behind, so the previous image becomes ready.

Workload Identity: the provider of each project accepts a token only with `repository` and `repository_id` of this repository, `job_workflow_ref` = `deploy.yml`, ref `main` (staging also `refs/tags/v*`) **and `environment` = that project's GitHub Environment** (`staging` / `production`). A tag ref proves nothing about where the tag was cut, so the GitHub settings (environment deployment branch and tag rules, a `v*` tag ruleset restricted to the owner) are part of this boundary: [infra/README.md](../infra/README.md), "GitHub repository settings". `afterme-cicd` can deploy a revision or job that runs as `afterme-api`: treat it as equivalent to that account. No secret is read or printed in the workflow; the probe token is never given to CI (the smoke test relies on the 401 for a missing token, and the real probe is the uptime check's job). Third-party actions are pinned by commit SHA (resolved with `git ls-remote`); `infra.yml` runs `terraform fmt -check` and `validate` on every change to `infra/`.

GitHub Environment **variables** (not secrets) per environment: `GCP_PROJECT_ID`, `GCP_REGION`, `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT`, `API_URL`. Terraform prints the two WIF values.

## 11. Monitoring: what pages whom

Two tiers: **PAGE** = every e-mail address and every SMS number (the two on-call people); **notify** = e-mail only. The Google Cloud mobile app can also push incidents to a phone (each person turns that on in the app). SMS channels are created unverified; each number must be verified once (README step 12) or **nothing is sent, silently**. The `alert test` policy exists so that the path can be exercised on purpose.

| Alert | Source | Tier |
|---|---|---|
| Worker heartbeat > 2 min; Hold evaluation failing; held actions; messages given up; consistency violations; due action / queued message > 5 min late; database unreachable | `afterme-status-check` execution fails (`cli.admin status` exits 1) | PAGE |
| The watchdog stopped | no execution for 10 min | PAGE |
| Hold entered; consistency violation; action held | critical log events (immediate) | PAGE |
| Worker loop failing (`worker.tick_failed`, `worker.dispatch_failed`, `engine.hold_failed`) | log metric, ≥ 3 in 5 min | PAGE |
| Uptime check failing | `check_passed` false from ≥ 2 of 3 regions for 2 min | PAGE |
| Uptime check silent | no result for 10 min | PAGE |
| API 5xx > 2 % (5 min, ≥ 20 requests) | Cloud Run `request_count` ratio | PAGE |
| `POST /v1/checkins` error rate > 1 % (5 min, ≥ 20 requests) | log metric from `http.request` | PAGE |
| Database CPU > 80 % (10 min), disk > 80 %, connections > 80 % of `max_connections`, instance not up | Cloud SQL metrics | PAGE |
| KMS errors | `kms.call_failed` (one line per failure, any code, from the adapter and the vault) ≥ 3 in 5 min, or **any** configuration/integrity code (`unknown_key`, `integrity`, `key_mismatch`, `bad_response`, `invalid_argument`, `permission_denied`, `not_found`, `unauthenticated`) | PAGE |
| Backup stale (> 26 h) or PITR off, or the check not running | `afterme-backup-check` | PAGE |
| Alert path test | `gcloud logging write afterme-alert-test …` | PAGE (test) |
| p95 latency > 2 s (10 min) | Cloud Run | notify |
| Engine / dispatcher units failing | log metric | notify |
| Fallback e-mail provider carrying messages | `email.fallback_used` | notify |
| Spam complaint, or hard-bounce spike | `webhook.event` by `kind` (the app's values: `delivered`, `hard_bounce`, `soft_bounce`, `failed`, `complaint`, `other`): **any** `complaint`; `hard_bounce` + `failed` ≥ 5 in an hour | notify |
| Retention job failing / not running | job executions | notify |
| Certificate expires in < 21 days | uptime check metric | notify |

Minimum-traffic floors on the two ratio alerts keep a single failed request at 3 a.m. from paging. Play Android vitals are watched in the Play Console (not here).

**Dashboard** (`AfterMe operations`): check-ins/hour, incidents opened/hour, Hold history, e-mail delivery events by kind, worker lag (heartbeat age, oldest due action, oldest queued message, open incidents: read out of the watchdog's output), watchdog results, API requests by class, database CPU and connections. "Messages by status" is not emitted as a metric by the application (it lives in the database): use `cli.admin status` and `beta-report`.

## 12. Disaster recovery

| Scenario | Mechanism | RPO | RTO |
|---|---|---|---|
| Zone failure (prod) | Regional HA: synchronous standby in a second zone, automatic failover; Cloud Run instances are spread over zones | 0 | ≈ 1–2 min of database unavailability; engine treats unknown state as Hold-safe, nothing wrongly sent |
| Bad deploy | Redeploy previous digest | 0 | minutes |
| Data corruption, wrong delete, bad migration | Point-in-time recovery: clone the instance at a chosen second (7 days of logs) | **≤ 5 min** (continuous log archiving; the target) | **≤ 1 h** (clone + switch; measured in OPS-05, size-dependent) |
| Instance lost | Restore the newest of 30 daily backups, then PITR on top | ≤ 5 min with logs, else ≤ 24 h | ≤ 1 h |
| Region lost | **Not covered in 1.0.** Backups are stored in asia-south1 (`db_backup_location`) to keep personal data in India; a regional disaster takes them too. Setting `db_backup_location = "asia"` (multi-region) trades that for cross-region restore. Accepted residual risk, to be decided with counsel | — | — |
| Key destroyed | `prevent_destroy`; a version scheduled for destruction can be cancelled for 30 days | — | — |

How PITR gives RPO ≤ 5 min: Cloud SQL archives the write-ahead log continuously (`transaction_log_retention_days = 7`); a clone at timestamp T replays logs up to T. "≤ 5 min" is the target the drill must show (the newest recoverable timestamp is within minutes of now); measure it, do not assume it.

**After any restore** the engine must not alert on the strength of data that may be missing recent check-ins: enter operator Hold **first** (`afterme-oncall-hold-enter`), switch, review, then exit with the shift ([DEPLOYMENT §6, §9](DEPLOYMENT.md#6-backups-and-recovery)). Switching means writing the new instance's private IP into the four database secrets and redeploying (§GAMEDAYS OPS-05 has the commands). The drill is quarterly.

## 13. Cost

See the table in [`infra/README.md`](../infra/README.md#cost-estimate). The drivers, in order: Cloud SQL regional HA, the always-on CPU of the workers and the API, the load balancer. Estimates only; confirm with the Google Cloud pricing calculator.

## 14. Assumptions about Google Cloud that were not verifiable offline

Checked only by `terraform validate` (schema), never against a real project. The owner verifies these at the first apply:

1. `TRUSTED_PROXY_HOPS = 2` behind the external ALB and serverless NEG (§7). Verified only by `verify_client_ip.sh`.
2. `google_cloud_run_v2_worker_pool` and `gcloud beta run worker-pools update` work in asia-south1 and accept Direct VPC egress; `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER`, `default_uri_disabled` and `invoker_iam_disabled` combine as intended (and the organisation policy allows `invoker_iam_disabled`).
3. A Cloud Run service with ingress restricted to the load balancer accepts traffic from a *global external* ALB through a serverless NEG.
4. Cloud Scheduler can run a Cloud Run job through the `run.googleapis.com/v2/.../jobs/NAME:run` URL with `roles/run.invoker` on the job (the role contains `run.jobs.run`).
5. `roles/run.jobsExecutorWithOverrides` exists under that name; the Google Cloud mobile app may not expose *Execute with overrides* (the console in a phone browser does).
6. Cloud Run job metric `run.googleapis.com/job/completed_execution_count` with label `result` (`failed`) and resource type `cloud_run_job`; `alert_strategy.notification_channel_strategy.renotify_interval` accepted.
7. Uptime check: POST with an empty `URL_ENCODED` body and `accepted_response_status_codes` 204; `REDUCE_COUNT_FALSE` across three regions; the metric `time_until_ssl_cert_expires`; `PATCH …/uptimeCheckConfigs/ID?updateMask=httpCheck.headers` replaces the headers (the script sends both headers).
8. Cloud SQL: `ssl_mode = ENCRYPTED_ONLY`, `log_statement`, `log_min_duration_statement`, `log_lock_waits`, `max_connections` are accepted flags on PostgreSQL 17 Enterprise; the backup `location` accepts a single region; a clone of a private-IP instance keeps the private network.
9. Log-based metrics read numeric JSON fields (`jsonPayload.status>=500`) and the regular-expression value extraction works on the watchdog's pretty-printed JSON lines (one entry per line).
10. Log-based metrics and log-match alerts see entries that a `_Default` exclusion drops from storage.
11. Worker-pool logs carry `jsonPayload.event` as the services' do (structured stdout is parsed into `jsonPayload`). **The application's JSON carries an upper-case `severity`** (`DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL`, mapped from `level` by `add_severity` in `app/core/logging.py`) beside `level`, so Cloud Logging shows each line at its real severity and Error Reporting sees errors. The metrics and alerts here still filter on `jsonPayload.event`, never on severity, so the field changes no alert.
12. Managed certificate issuance for both names on one classic Google-managed certificate; SMS channels need verification before they send.
13. The custom roles list every permission their jobs use (`cloudsql.backupRuns.*`, `cloudsql.instances.get`, `cloudsql.operations.*`).
14. Resource names (`afterme-pg-<env>`, secret ids, job names) are used literally by the workflow and scripts.

## 15. Recommendations for the backend (not done here)

* Split `Settings` per process so the worker/maintenance/admin do not need the API's secrets or placeholder URLs (§5).
* ~~Write `severity` (not only `level`) in the JSON logs (§14.11).~~ Done (Phase 11).
* Move the background-task e-mails to the outbox; then the API can run with request-based CPU.
* Emit a periodic structured status snapshot (or expose `status` fields as metrics) so the dashboard needs no regular expressions.
