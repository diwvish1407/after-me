# AfterMe — Architecture

| | |
|---|---|
| **Status** | Draft v0.1 — awaiting product-owner approval |
| **Related** | [PRD](PRD.md) · [ESCALATION_ENGINE](ESCALATION_ENGINE.md) · [DATABASE](DATABASE.md) · [API_SPEC](API_SPEC.md) · [SECURITY](SECURITY.md) · [DEPLOYMENT](DEPLOYMENT.md) |

---

## 1. Principles

1. **The backend is authoritative.** The app displays state and sends user intent ("I'm OK"). The server decides deadlines, incidents, escalation, releases and notifications. Business-critical logic never lives only in Flutter.
2. **Fail-safe, not fail-trigger.** Uncertainty means *don't contact, don't release* ([ESCALATION_ENGINE §2](ESCALATION_ENGINE.md#2-safety-invariants)).
3. **One source of truth for state and time.** PostgreSQL holds all authoritative state, and its clock is the escalation clock.
4. **Every external effect goes through an outbox.** Database state and side effects can't diverge. Messages are sent by a dispatcher that re-checks state before sending.
5. **Least data, least privilege.** Sensitive content is encrypted at rest and never put in notifications or logs. Database roles are scoped.
6. **Small number of moving parts.** For 1.0, Postgres is the only stateful dependency. No Redis, no message broker.
7. **Swappable providers.** Email, SMS, push, KMS and billing sit behind interfaces.

## 2. System context

```
                         ┌────────────────────────────────────────────────────────────┐
                         │                     AfterMe backend                        │
  ┌───────────────┐ HTTPS│  ┌──────────────────────┐        ┌──────────────────────┐  │
  │ Android app   │─────▶│  │ api (FastAPI)        │        │ worker               │  │
  │ (Flutter)     │◀─────│  │  • JSON API  /v1     │        │  • escalation engine │  │
  └───────┬───────┘      │  │  • web pages /c,/a   │        │  • outbox dispatcher │  │
          │ push         │  │  • /internal/probe   │        │  • hold evaluator    │  │
          │              │  └──────────┬───────────┘        └──────────┬───────────┘  │
  ┌───────┴───────┐      │             │      SQL (TLS)                │              │
  │ FCM           │◀─────┼─────────────┼───────────────────────────────┤              │
  └───────────────┘      │             ▼                               ▼              │
                         │        ┌────────────────────────────────────────┐          │
  ┌───────────────┐ HTTPS│        │ PostgreSQL (state, outbox, audit, clock)│          │
  │ Trusted       │─────▶│        └────────────────────────────────────────┘          │
  │ contact (web  │◀─────│                                                            │
  │ browser/email)│      │   KMS (key wrapping)   Secret store   Error monitoring    │
  └───────────────┘      └────────────────────────────────────────────────────────────┘
          ▲                         │                         │
          │ email                   ▼                         ▼
  ┌───────┴────────┐       ┌────────────────┐        ┌──────────────────┐
  │ Email provider │◀──────│ (dispatcher)   │        │ Uptime monitor   │──▶ POST /internal/probe
  │ (+ fallback)   │       └────────────────┘        │ (external)       │    (feeds Hold)
  └────────────────┘                                 └──────────────────┘
```

| Component | Responsibility | Scaling |
|---|---|---|
| **Android app** | UI, local app lock, secure token storage, push receipt | — |
| **api** | JSON API, recipient portal and user web pages, probe endpoint, provider webhooks | Stateless; 1..N replicas |
| **worker** | Escalation engine tick, outbox dispatch, Hold evaluation, pre-deadline reminders | 1–2 replicas (safe via `SKIP LOCKED`); dispatcher can be split out later |
| **PostgreSQL** | All state, the outbox, audit, rate-limit counters, **the clock** | Managed, HA in prod, PITR backups |
| **KMS** | Wraps per-user data-encryption keys | Managed |
| **Email provider (+ fallback)** | Transactional email | External |
| **FCM** | Push to the user's devices | External |
| **Uptime monitor** | External probe of the public ingress → Hold detection | External |
| **Error monitoring** | Exceptions (PII-scrubbed) | External |

## 3. Repository layout (monorepo)

```
AfterMe/
├── README.md
├── docs/                         # these documents
├── backend/
│   ├── pyproject.toml  uv.lock  .python-version  alembic.ini  .env.example
│   ├── app/
│   │   ├── main.py               # create_app(): routers, middleware, handlers
│   │   ├── core/                 # config, logging, errors, clock, db/session, pagination, ids
│   │   ├── api/                  # v1 router assembly, shared dependencies (auth, reauth, rate limit)
│   │   ├── auth/                 # register, login, sessions, tokens, verification, reset
│   │   ├── users/                # profile, timezone, export, deletion
│   │   ├── contacts/             # trusted contacts, invitations, consent
│   │   ├── checkins/             # schedule, deadline computation, check-in service
│   │   ├── escalation/           # plans, stages, incidents, engine, gate, hold
│   │   ├── instructions/         # categories, instructions, recipients, encryption use
│   │   ├── releases/             # release events, portal access, OTP
│   │   ├── notifications/        # outbox, templates, dispatcher, providers/{fcm,email_*,sms_*,console}
│   │   ├── audit/                # append-only audit writer, activity feed
│   │   ├── billing/              # entitlements, tiers, google_play (later)
│   │   ├── security/             # envelope crypto, KMS providers, passwords, rate limiting, tokens
│   │   ├── web/                  # Jinja2 templates + routes: portal (/c), account (/a), legal
│   │   └── assistant/            # reserved for 1.1 (AI Instruction Assistant)
│   ├── workers/                  # engine.py, dispatcher.py (entry points)
│   ├── cli/                      # afterme-admin: hold, key rotation, maintenance
│   ├── migrations/               # Alembic
│   └── tests/                    # unit/, integration/, engine/, security/, e2e/
├── mobile/
│   ├── pubspec.yaml  analysis_options.yaml  l10n.yaml
│   ├── config/                   # dev.json, staging.json, prod.json (non-secret build config)
│   ├── lib/
│   │   ├── main.dart
│   │   ├── app/                  # App widget, router, theme
│   │   ├── core/                 # api client, session, secure storage, app lock, errors, l10n, design system
│   │   └── features/             # onboarding, auth, home, checkin, contacts, instructions,
│   │                             #   plan, activity, settings, notifications
│   ├── android/                  # flavors: dev, staging, prod
│   ├── test/                     # unit + widget tests
│   └── integration_test/
└── infrastructure/               # Dockerfiles, CI workflows, IaC (Phase 12)
```

The mobile feature folders follow the module list in the brief (auth, profile, contacts, checkin, instructions, escalation→`plan`, notifications, settings) under `features/`, with `home` and `onboarding` added.

*Implemented in Phase 3 (contacts):* `features/contacts` has `data/` (the `ContactsRepository` interface, the Dio implementation, freezed `TrustedContact` / `Entitlements` models), `application/` (`ContactsController`, the single source of truth for the list; `entitlementsProvider`; the readiness rules) and `presentation/` (People, Add, Edit, Detail, the status chip and the plan-limit sheet). The onboarding `SetupController` mirrors the contacts controller for the Home checklist. Failures from the contacts API are typed `AppFailure` subtypes (`PlanLimitFailure` carrying `limit`/`current`/`resource`, `ContactDuplicateFailure`, `CannotBeOwnEmailFailure`, `InvalidStateFailure`, `RateLimitedFailure` with the retry time) and are shown with the app's own calm copy, never the server's `detail`. Writes carry no `Idempotency-Key` and are never retried automatically (the server does not replay them); reads are retried. The in-memory contacts fake lives in `test/helpers` only; the schedule, plan and instruction stand-ins remain until Phases 4-6. The contact picker is the Phase 2 `ACTION_PICK` channel in `MainActivity` (no plugin, no `READ_CONTACTS`).

## 4. Backend architecture

### 4.1 Stack

| Concern | Choice |
|---|---|
| Language/runtime | Python 3.13 (uv-managed; pinned in `.python-version`) |
| Web framework | FastAPI (async), served by Uvicorn |
| Validation | Pydantic v2, `extra="forbid"` on all request models (blocks mass assignment) |
| ORM / SQL | SQLAlchemy 2.x (asyncio) + psycopg 3 |
| Migrations | Alembic (one migration per change, reviewed, reversible where practical) |
| Passwords | Argon2id (argon2-cffi) |
| Tokens | Short-lived JWT (EdDSA) access tokens + opaque rotating refresh tokens |
| Crypto | `cryptography` (AES-256-GCM), KMS for key wrapping |
| Templates | Jinja2 (email and web pages, autoescape on) |
| Logging | structlog → JSON to stdout, with a redaction processor |
| Errors | RFC 9457 `application/problem+json` |
| Tests | pytest, pytest-asyncio, Hypothesis, httpx ASGI transport, real PostgreSQL |
| Quality | ruff (lint + format, incl. security rules), mypy (strict on `app/`), pip-audit |

### 4.2 Process types

| Process | Entry point | Notes |
|---|---|---|
| `api` | `uvicorn app.main:app` | Stateless; any number of replicas |
| `worker` | `python -m workers.engine` | Runs the engine tick, Hold evaluation, pre-deadline reminders and the outbox dispatcher as separate async loops. Safe with several replicas. |
| `migrate` | `alembic upgrade head` | Runs as a release step before new code goes live; uses the migration DB role |

### 4.3 Layering inside each module

```
router.py      HTTP only: parse/validate, auth dependencies, call service, map to response schema
schemas.py     Pydantic request/response models (API contract; never ORM models)
service.py     Business rules, authorization by ownership, audit events, transaction boundaries
repository.py  SQL. Every method for an owned resource REQUIRES owner_id and filters by it.
models.py      SQLAlchemy ORM models
```

**Ownership rule.** Repositories for user-owned data have no `get(id)`. They only have `get(owner_id, id)`. A resource that isn't owned is indistinguishable from one that doesn't exist (`404`), which avoids an existence oracle. A test enforces this convention, and an **authorization-matrix test** exercises every route with a second user's IDs ([TEST_PLAN §5](TEST_PLAN.md#5-security-and-authorization-tests)).

### 4.4 Request lifecycle

```
request
  → RequestID middleware (X-Request-ID; generated if absent)
  → security headers / body-size limit
  → client version check (X-AfterMe-Client; 426 if below minimum supported)
  → router dependency: authenticate (JWT → session row active?) → rate limit → reauth (if required)
  → service (one DB transaction per request via UnitOfWork; commit at end)
  → response model (explicit fields only)
  → structured access log (method, route template, status, latency; NO query string, NO body)
```

### 4.5 Time

A `Clock` interface supplies `now()`:
- `DbClock` (staging/prod): `SELECT now()` once per transaction. That value is used for every comparison and timestamp in the transaction.
- `FrozenClock` (tests): advanced explicitly by the test.

Engine SQL takes `:now` as a parameter instead of calling `now()` inline, so tests can drive time deterministically while production still uses the database clock (INV-3).

### 4.6 Background work

There is no task broker. The worker polls Postgres:

- Due work is found with indexed queries (`next_due_at`, `scheduled_for`, `send_after`).
- Concurrency control uses `SELECT … FOR UPDATE SKIP LOCKED` on the per-user row.
- Every side effect goes through the outbox (`notifications`) and is sent by the dispatcher.

This handles far more than 1.0 needs: thousands of users per tick with indexed batches. It can be split into separate processes, or moved onto a queue, when scale requires. Details: [ESCALATION_ENGINE §6](ESCALATION_ENGINE.md#6-worker-algorithm).

### 4.7 Provider abstractions

```python
class EmailProvider(Protocol):
    name: str
    async def send(self, msg: EmailMessage, *, idempotency_key: str) -> ProviderResult: ...

class PushProvider(Protocol):
    async def send(self, msg: PushMessage, *, idempotency_key: str) -> ProviderResult: ...

class SmsProvider(Protocol):            # interface only in 1.0
    async def send(self, msg: SmsMessage, *, idempotency_key: str) -> ProviderResult: ...

class KeyProvider(Protocol):            # wraps/unwraps per-user DEKs
    async def wrap(self, dek: bytes, *, context: dict[str, str]) -> WrappedKey: ...
    async def unwrap(self, wrapped: WrappedKey, *, context: dict[str, str]) -> bytes: ...

class BillingProvider(Protocol):        # google_play first
    async def verify_purchase(self, token: str, product_id: str) -> PurchaseState: ...
```

Implementations:

| Interface | Environments |
|---|---|
| Email | `console` (dev only; never enabled in prod), a primary provider, an optional fallback |
| Push | `fcm` (HTTP v1 API via a service account), `noop` (tests) |
| KMS | `local` (dev/test: key from env; refused in prod), `gcp_kms` (or the equivalent for the chosen cloud) |

### 4.8 Configuration

- `pydantic-settings` reads environment variables (prefix `AFTERME_`). `.env` files are for local development only.
- `APP_ENV ∈ {dev, test, staging, prod}`. Production startup **fails** if insecure settings are present: debug on, `local` KMS, `console` email, HTTP base URLs, missing secrets, or engine parameters that violate safety constraints.
- Secrets come from the cloud secret manager in staging/prod and are never committed. Full variable list: [DEPLOYMENT §4](DEPLOYMENT.md#4-configuration-and-secrets).

### 4.9 Logging, errors and monitoring

- **Structured logs** carry `request_id`, `user_id` (UUID only), `route`, `status`, `latency_ms`, `event` and `outcome`.
- A **redaction processor** drops or masks known-sensitive keys (`password`, `token`, `authorization`, `otp`, `title`, `body`, `email`, `phone`, `cookie`). Request and response bodies are never logged.
- **Error monitoring** (e.g. Sentry) with `send_default_pii=False`, a scrubbing `before_send`, no request bodies, and environment and release tags.
- **Metrics/alerts**: [ESCALATION_ENGINE §12](ESCALATION_ENGINE.md#12-observability) and [DEPLOYMENT §7](DEPLOYMENT.md#7-monitoring-and-alerting).

## 5. Mobile architecture

### 5.1 Stack (candidates; versions pinned and checked for compatibility at the start of each phase)

| Concern | Package / approach |
|---|---|
| Framework | Flutter (latest stable at Phase 1), Dart 3, Material 3 |
| State / DI | Riverpod (`flutter_riverpod`) |
| Navigation | `go_router` with redirect guards (auth state, onboarding state); the app lock is an overlay above the navigator (§5.5) |
| HTTP | `dio` with interceptors |
| Models | `freezed` + `json_serializable` (code generation) |
| Secure storage | `flutter_secure_storage` (Android Keystore-backed) |
| Biometrics | `local_auth` (biometric with device-credential fallback) |
| Push | `firebase_core`, `firebase_messaging`; `flutter_local_notifications` for foreground display |
| Device timezone | `flutter_timezone` (IANA name) |
| Time zones for display | `timezone` (pure Dart, `latest_all` data, about 445 KB): shows times in the **profile** timezone, which the platform cannot do for a zone other than the device's. Added in Phase 4. |
| Connectivity | `connectivity_plus` (as a hint only; the real test is the request) |
| i18n | `flutter_localizations` + `intl` + gen-l10n (ARB files) |
| Errors | `sentry_flutter` (PII scrubbing on) |
| Lints | `flutter_lints` or `very_good_analysis` (decided at Phase 1) |
| Tests | `flutter_test`, `mocktail`, `integration_test` |

### 5.2 Layers per feature

```
features/<name>/
  data/          DTOs, API calls, repository implementation
  domain/        immutable models, repository interfaces (thin; no business-critical rules)
  presentation/  screens, widgets, Riverpod controllers (AsyncNotifier), view state
```

### 5.3 API client

- `AuthInterceptor` attaches the access token, which is held **in memory only**. On `401 token_expired` it runs a **single-flight refresh**: one refresh at a time, and other requests wait. The rotated refresh token is persisted to secure storage **before** the original request is retried, and each request is retried at most once. A **rejected** refresh (`400`/`401`/`403`/`422`), a missing or unreadable refresh token, an unusable `2xx` body, or a `401 session_revoked` / `unauthenticated` on any authenticated call clears the session and sends the user to login. A **transient** refresh failure (offline, timeout, `5xx`, `429`) keeps the session and fails only that request, so a network blip never signs someone out or stops a check-in; the next request tries the refresh again.
- `IdempotencyInterceptor` adds an `Idempotency-Key` (UUID v4) to requests marked as needing one. The key is generated **once per user intent** and reused on retries.
- `ClientInfoInterceptor` sends `X-AfterMe-Client: android/<version>+<build>`.
- **Server clock offset (Phase 4).** The app never computes a deadline and never trusts the phone's clock alone: it keeps `offset = server_time - device_now` from the last `GET /v1/home` and compares the server's `next_due_at` with `device_now + offset` (Due soon, Overdue). A replayed check-in response (`Idempotent-Replayed: true`) carries an old `server_time` and never moves the offset.
- Retries happen only for idempotent requests or requests with an idempotency key, using exponential backoff with jitter.
- Errors are mapped to a sealed `AppFailure` hierarchy (network, unauthorized, validation, conflict(code), rateLimited, server, upgradeRequired).

### 5.4 Local data

| Data | Where | Why |
|---|---|---|
| Refresh token, session ID, device ID | `flutter_secure_storage` | Keystore-backed |
| Pending check-in (opaque account id, idempotency key, tap time) | `flutter_secure_storage` (`checkin.pending`) | Survives process death; retried with the same key. Bound to the account that tapped; a record of another account is never sent. No names, addresses or schedule. |
| App-lock settings, onboarding progress, last-known home summary (times and counts only) | `shared_preferences` | Non-sensitive |
| Instruction content | **Never persisted** | Fetched on demand, held in memory |

Android `allowBackup="false"`. Secure storage is device-bound and must not be restored to other devices.

### 5.5 App lock

- Enabled during onboarding (recommended). Locks on cold start and after a configurable background timeout (immediately / 1 / 5 min; default 5).
- Uses `BiometricPrompt` (BIOMETRIC_STRONG) with **device credential** (PIN/pattern/password) as the fallback. If the device has no screen lock, the app recommends setting one; an AfterMe-specific PIN is a Phase 9 decision.
- App lock is a **client-side** protection. Server-sensitive operations additionally require server re-authentication (FR-AUTH-08).
- *Implemented in Phase 2:* the lock is an overlay above the `Navigator` (`MaterialApp.builder`), not a route, so it also covers open sheets and dialogs; the app below is kept alive but hidden (offstage, excluded from semantics). While the lock is enabled, `MainActivity` sets `FLAG_SECURE` in `onPause` so the recents thumbnail is blank. System dialogs (unlock prompt, permission dialog, contact picker) do not count as leaving the app. A device that lost its screen lock gets an explanation and the person's explicit choice to turn the lock off.

### 5.6 Screen protection

`FLAG_SECURE` is set through a small platform channel in `MainActivity` while instruction view/edit screens and the export screen are visible. This blocks screenshots, screen recording and the app-switcher preview. Store screenshots are taken in a build flavor with this disabled.

### 5.7 Push and reminders

- The FCM token is registered on login and on token refresh (`POST /v1/devices`).
- Payloads carry only `{type, incident_id?}` and generic text; the app fetches details over the API.
- The app does **not** schedule exact alarms or run background jobs to decide anything. Reminders come from the server (push + email).

### 5.8 Offline behaviour

- The home screen shows the last-known schedule with an "Offline — showing last known status" banner.
- Pressing I'M OK offline creates a *pending* check-in (status: "Not received yet — will retry"). It is retried on connectivity change and on app resume. Success is shown **only** after the server confirms.
- No editing offline in 1.0. Forms say clearly that a connection is needed.

### 5.9 Flavors

| Flavor | Application ID | API | Firebase project |
|---|---|---|---|
| `dev` | `<appId>.dev` | local / dev | afterme-dev |
| `staging` | `<appId>.staging` | staging | afterme-staging |
| `prod` | `<appId>` | production | afterme-prod |

Build-time configuration goes through `--dart-define-from-file=config/<env>.json` (API base URL, environment name, Sentry DSN). There are **no secrets** in the app.

## 6. Web surfaces (server-rendered)

| Path prefix | Audience | Pages |
|---|---|---|
| `/c/…` | Trusted contacts | Invitation (accept/decline), release viewing (OTP), opt-out, request a fresh link |
| `/a/…` | Users | Login, check-in / I'M SAFE (lost phone), email verification landing, password reset, account-deletion request |
| `/legal/…` | Public | Privacy policy, terms |

Rules:
- Server-rendered Jinja2, minimal CSS, one small first-party script per page where needed. **No third-party scripts.** A strict CSP with nonces.
- **GET never changes state.** Every action is a POST with a CSRF token, so email link scanners can't accept invitations or check anyone in.
- Bearer tokens in email links go in the **URL fragment** (`/c/open#<token>`). Fragments are never sent to servers, so tokens stay out of server, load-balancer and proxy logs. A first-party script posts the fragment and exchanges it for a short-lived, `__Host-` prefixed, `HttpOnly`, `Secure`, `SameSite=Strict` cookie, then clears the URL.
- `Referrer-Policy: no-referrer`, `Cache-Control: no-store`, and `X-Robots-Tag: noindex` on every portal page.

## 7. Key flows (sequence)

### 7.1 Check-in

```
App                         api                                  Postgres
 │  POST /v1/checkins        │                                      │
 │  Idempotency-Key: K ─────▶│ BEGIN                                │
 │                           │ SELECT … checkin_configurations      │
 │                           │   FOR UPDATE (lock_timeout 5s) ─────▶│
 │                           │ key K seen? → return stored result   │
 │                           │ open incident? messaged? → 409       │
 │                           │ INSERT checkin_events                │
 │                           │ resolve incident (if any)            │
 │                           │ next_due_at = compute_next_due(now)  │
 │                           │ INSERT audit_logs                    │
 │                           │ COMMIT ─────────────────────────────▶│
 │◀──── 200 {next_due_at}  ──│                                      │
 │ (UI shows ✓ only now)     │                                      │
```

### 7.2 Contact views a released instruction

```
Contact (browser)                 api (/c)                         Postgres / KMS
 │ opens email link /c/open#T ──▶ page (no state change)            │
 │ script POSTs T ──────────────▶ hash(T) → portal_tokens valid? ──▶│
 │◀── Set-Cookie (portal session, unverified); redirect /c/release   │
 │ "Send a code to d•••@gmail.com" → POST /c/release/otp ──────────▶ OTP hash stored; email queued
 │ enters code → POST /c/release/verify ───────────────────────────▶ attempts ≤ 5, not expired
 │◀── session elevated (15 min) → GET /c/release/view                │
 │                                   load visible, unrevoked releases│
 │                                   unwrap DEK (KMS) → decrypt ─────▶│
 │◀── content (no-store, noindex)    audit release.viewed            │
```

## 8. Technology decisions

| ID | Decision | Alternatives considered | Rationale |
|---|---|---|---|
| ADR-01 | **Flutter** for mobile | Native Kotlin; React Native | One codebase for Android now and iOS later; mature Material 3; good accessibility support |
| ADR-02 | **FastAPI + SQLAlchemy 2 (async) + PostgreSQL** | Django; Node/NestJS | Typed request validation, OpenAPI for free, strong Python ecosystem; Postgres gives transactions, row locks, `SKIP LOCKED`, JSONB |
| ADR-03 | **Postgres-only state; no Redis/Celery in 1.0** | Celery+Redis, a cloud task queue | The escalation clock and its side effects must be transactional with state. One fewer system to fail. Revisit at scale. |
| ADR-04 | **Server-rendered portal** | SPA (React/Flutter web) | Contacts need a simple, fast, script-light, secure page. Small attack surface. |
| ADR-05 | **JWT access (15 min) + opaque rotating refresh; session checked per request** | Long-lived JWT; stateless only | Instant revocation, reuse detection, simple key rotation |
| ADR-06 | **Server-side envelope encryption** of instructions (per-user DEK, KMS-wrapped) | End-to-end encryption | Contacts don't have the app, and the server must deliver content at release time while the user is unreachable. E2EE is a 2.x option ([SECURITY §6](SECURITY.md#6-cryptography)). |
| ADR-07 | **Database clock as the only clock** | App-server clocks; client clocks | Removes skew between replicas; one ordering of events |
| ADR-08 | **Email-only to contacts in 1.0** | SMS/WhatsApp at launch | Regulation and cost; validate first ([PRD D4](PRD.md#15-decisions-needed-from-the-product-owner)) |
| ADR-09 | **Google Cloud** hosting (proposed) | AWS; PaaS (Render/Fly/Railway) + managed Postgres | FCM/Firebase is already Google; managed Postgres with HA/PITR, KMS, Secret Manager and uptime checks in one place ([DEPLOYMENT §3](DEPLOYMENT.md#3-hosting-proposed)) |
| ADR-10 | **Riverpod + go_router + dio** | Bloc; Provider; http | Testable DI, compile-safe providers, mature routing with guards, interceptors |
| ADR-11 | **Monorepo** | Separate repos | One place for the API contract, docs and CI; atomic changes across client and server |

## 9. Assumptions

1. A single backend region; data residency is decided by the launch market (PRD D3).
2. Scale at launch is under 10k users; the design holds to roughly 100k+ with the same architecture (indexed batched polling).
3. Contacts receive email; the portal works on any modern mobile browser.
4. Users keep an authenticated session on their device for long periods (sessions up to 365 days with rotation).
5. The development machine needs Flutter, Android Studio/SDK and JDK 17+ installed before mobile work. None are installed today ([DEPLOYMENT §2](DEPLOYMENT.md#2-local-development-setup)).

## 10. Risks (technical)

| Risk | Mitigation |
|---|---|
| A bug in the engine causes a wrongful alert or release | Invariants + gate + Hold + settle delay; exhaustive and property-based tests; staged rollout; operator kill switch |
| A worker outage delays escalation | Heartbeat paging; multiple replicas; anchor rule keeps grace fair |
| Email deliverability (spam folder) | Dedicated sending domain with SPF/DKIM/DMARC; plain, consistent templates; contact acceptance warms reputation |
| OEM battery optimisation delays push | Email in parallel; reminders well ahead of deadlines |
| Dependency churn (Flutter/FastAPI ecosystem) | Pin versions; Renovate/Dependabot; upgrade on a schedule; avoid niche packages |
| Postgres-only background processing at scale | Indexed batches; split the dispatcher; move to a queue when metrics say so |

## 11. External dependencies (accounts to create)

| Dependency | Needed by |
|---|---|
| Domain name + DNS | Phase 1 (application ID), Phase 8 (email domain) |
| Firebase projects (dev/staging/prod) | Phase 7–8 |
| Transactional email provider (+ fallback) | Phase 8 |
| Cloud account (proposed GCP) with billing | Phase 12 (staging can start earlier) |
| Error monitoring account | Phase 1 (dev DSN) |
| Google Play Console developer account | Phase 10 (closed testing), 13 |
| Git hosting (e.g. GitHub) for CI | Phase 1 |

## 12. Security concerns (summary)

See [SECURITY.md](SECURITY.md) for the threat model and controls. The headline concerns:

1. **Unauthorized release** (via bugs, API manipulation or account takeover). Controls: INV-1, the gate, re-auth for I'M SAFE, OTP on the portal.
2. **Cross-user data access (IDOR).** Controls: owner-scoped repositories, 404 semantics, the authorization-matrix test.
3. **Sensitive data leakage** (logs, notifications, backups, screenshots). Controls: redaction, content-free notifications, encryption at rest, FLAG_SECURE.
4. **Account takeover.** Controls: Argon2id, rate limits, refresh rotation with reuse detection, security emails on login and password change.
5. **Abuse of invitations** (spam). Controls: verified-email gate, limits, global opt-out.

## 13. Future extensions (designed for, not built)

| Extension | Hook in the architecture |
|---|---|
| iOS | Flutter codebase; APNs via FCM; provider interfaces |
| AI Instruction Assistant (1.1) | `app/assistant` module; returns *suggestions only*; the client shows a review-and-approve UI; nothing is saved without an explicit user action; never touches the engine |
| SMS / WhatsApp | `SmsProvider` (and a future `WhatsAppProvider`); contact phone stored; consent extended per channel |
| Attachments | `instruction_attachments` table reserved; object storage with per-object encryption; malware scanning |
| Multiple plans | `escalation_plans` one-per-user constraint relaxed; incidents already reference `plan_id` |
| E2EE mode | Contact app installs + key exchange during acceptance; server stores ciphertext it cannot read |
