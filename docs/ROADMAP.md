# AfterMe — Roadmap

| | |
|---|---|
| **Status** | Phase 0 approved 2026-10-08 · Phases 1–3 built, reviewed and signed off · Phase 4 built, owner decisions applied (sign-off implied by the Phase 5 instruction, 2026-10-10) · Phase 5 built, independently reviewed and decisions implemented (owner approved 2026-10-10: "yes start phase 6") · Phase 6 built and independently reviewed (ESCALATION_ENGINE §13.3), awaiting owner review · Phase 7 built, both halves independently reviewed and fixed, MOB-61…65 pass on an emulator against the real backend; awaiting owner review (2026-10-11) · Phase 8 built up to the owner's accounts (provider adapters, fallback, webhooks, push, retention; independently reviewed and fixed); E2E-01/02/03 and the M2 exit wait for Firebase projects, an email provider, DNS and a staging environment (2026-10-12) · Phase 9 built: four independent reviews, no S1, three S2 fixed, written report in SECURITY_REVIEW.md; awaiting owner review (2026-10-12) |
| **Working agreement** | One phase at a time. Each phase ends with format, lint, tests and a written report (commands run, structure, open issues, how to run). The next phase starts **only** on the product owner's instruction. |
| **Related** | [PRD](PRD.md) · [TEST_PLAN §12](TEST_PLAN.md#12-release-acceptance-criteria) · [PLAY_STORE §1](PLAY_STORE.md#1-critical-path-and-timeline) |

---

## Milestones

| Milestone | Reached when | Meaning |
|---|---|---|
| **M0 — Design approved** | Phase 0 signed off | Architecture and decisions agreed |
| **M1 — Engine proven** | End of Phase 5 | The T0–T8 lifecycle, invariant and failure-scenario tests pass against the real engine |
| **M2 — Feature complete** | End of Phase 8 | Every **M** requirement works end to end in staging |
| **M3 — Closed beta** | During Phase 10 | Play closed testing running (the 14-day clock starts) |
| **M4 — Launch** | End of Phase 13 | Production on Google Play (staged rollout) |

Size: **S** ≈ a few focused sessions · **M** ≈ a week of sessions · **L** ≈ multiple weeks. These are for sequencing, not commitments.

## Phase 0 — Product & architecture documentation *(approved 2026-10-08)*

- **Deliverables:** PRD, ARCHITECTURE, ESCALATION_ENGINE, DATABASE, API_SPEC, SECURITY, USER_FLOWS, TEST_PLAN, DEPLOYMENT, PLAY_STORE, ROADMAP.
- **Exit:** The owner approves the documents and answers the decisions in [PRD §15](PRD.md#15-decisions-needed-from-the-product-owner) (at minimum D1 domain/app ID, D2 account type, D7 fail-safe defaults).

## Phase 1 — Development foundation · M

Scope (from the Phase 1 brief):
- Monorepo structure; `.gitignore`, `.editorconfig`, README, PR template, CI workflows.
- **Backend:** uv project (Python 3.13); FastAPI app factory; `pydantic-settings` config with prod-safety validation; structlog with redaction; problem+json errors; request-ID middleware; async SQLAlchemy + Alembic with the naming convention; `Clock` abstraction; **initial migration**: identity and access tables + `checkin_configurations` + `audit_logs` + reference data (later phases add their own tables through their own migrations); DB roles script; auth foundation (signup start/verify with the console email provider, login, refresh rotation, logout, session check, `CurrentUser` + ownership dependency, reauth); rate-limit foundation; audit writer; health endpoints; tests.
- **Mobile:** Flutter app with dev/staging/prod flavors, minSdk 26 / target 36; app shell; go_router with guards; Riverpod; dio client with auth/idempotency/client-info interceptors; secure-storage abstraction; theme and design-system components (tokens from USER_FLOWS §1); l10n scaffold; initial unit/widget tests.
- **Owner actions first:** install Flutter + Android Studio ([DEPLOYMENT §2.1](DEPLOYMENT.md#21-what-this-machine-has-today-checked-2026-10-08)); decide D1 (application ID); choose git hosting.
- **Exit:** All checks green locally (and in CI if hosting is ready); backend runs and passes auth tests on local Postgres; app builds and runs on an emulator with the dev flavor; Phase 1 report delivered.

## Phase 2 — Authentication & onboarding experience · M

- Signup with code, login, forgot/reset (web pages), change password/email, sessions list, logout-all, reauth sheet.
- App lock (biometric with device-credential fallback), notification-permission pre-prompt.
- The complete onboarding flow UI ([USER_FLOWS §3](USER_FLOWS.md#3-onboarding-target-a-working-plan-in-under-5-minutes)). Steps whose backend lands later use typed fakes behind repository interfaces.
- **Exit:** AUTH-* and MOB auth/onboarding tests pass; onboarding is walkable end to end on a device; accessibility checks on these screens pass.

## Phase 3 — Trusted contacts · M *(built, signed off 2026-10-10)*

- Contacts CRUD with ownership + validation; tier limits; invitations; portal pages for accept/decline/opt-out (fragment-token exchange, CSRF, headers); global suppression list; People screens.
- **Exit:** CON-* and the related SEC-* tests pass; the authorization-matrix test covers the contact routes; invitation emails render (console provider).

## Phase 4 — Check-in system · M *(built, owner decisions applied)*

- Schedule model, `compute_next_due` with the **verified vectors and Hypothesis properties**, activation/deactivation, `POST /checkins` with idempotency and the per-user lock, history, the `/home` aggregate; Home screen states (active / due soon) with the real API.
- **Exit:** CHK-*, ENG-PBT-01 and the DST/timezone tests pass; check-in works from the app against the local backend.

## Phase 5 — Escalation engine · L · ⚠ most critical *(built, independently reviewed, awaiting owner review)*

- Plans/stages API and editor validation; incidents, snapshot, timeline materialisation; the worker tick (open → execute → reminders → dispatch skeleton with recording providers); the full **safety gate**; settle delay; **Hold** (probes, anomaly, operator CLI) with rollback/shift; I'M OK resolution and I'M SAFE cancellation with the all-clear; DB role grants (`afterme_api` vs `afterme_worker`); observability metrics.
- **Exit (M1):** ENG-LC-*, ENG-INV-*, ENG-FS-*, ENG-PBT-02/03 and ENG-CONC-* all pass; the T0–T8 test passes 100× consecutively; an engine walkthrough is reviewed with the owner.

## Phase 6 — Instructions, recipients & release · L *(built, independently reviewed, awaiting owner review)*

- Categories; instructions with envelope encryption (local KMS provider in dev, KMS interface); recipients with release stages; release events; portal access, tokens, OTP, the viewing page; revocation paths; the Instructions screens (FLAG_SECURE) and starter templates.
- **Exit:** INS-*, REL-* and the related SEC-* (ciphertext swap, portal scope, XSS) tests pass; the lifecycle test includes a real release view.

## Phase 7 — Connect the complete Flutter UI · M *(built, independently reviewed, awaiting owner review)*

- Replace every fake with the real API; incident timeline UI; the I'M SAFE flow; Plan screen preview; Activity feed; Settings (export, delete); offline/pending behaviour; error mapping; `426` upgrade handling.
- **Exit:** MOB-* tests pass; MOB-61…65 integration tests pass against the dev backend with the test clock.
- **Backend work this phase needed (built):** `GET /v1/activity`; `POST /v1/me/export`; `DELETE /v1/me` and the public `/a/delete` page with the 30-day retention job (`workers.maintenance`, migration `0007`); the owner's view of what was released and viewed in the incident; the lost-phone pages (`/a/login`, `/a/checkin`, `/a/safe`); and the test clock and mail reader (`/test/*`, off by default, refused in production) that MOB-61…65 need.

## Phase 8 — Notifications · M *(built except what needs your accounts; independently reviewed; awaiting owner review and the owner actions)*

- **Owner actions:** create Firebase projects (dev/staging/prod); choose the email provider (+ fallback); domain DNS for SPF/DKIM/DMARC; a staging cloud environment (minimal).
- FCM provider (HTTP v1), email provider(s) with idempotency keys, templates (all from [USER_FLOWS §13](USER_FLOWS.md#13-message-copy-10-templates)), the dispatcher's retry/backoff/fallback, bounce/complaint webhooks, notification logs, lock-screen privacy on Android.
- **Exit (M2):** NOT-* tests pass; E2E-01/02/03 pass in staging with real email and push.

## Phase 9 — Security audit · M *(built; four independent reviews; awaiting owner review)*

- Threat-model review against the built system; the full SEC-* suite; mobile checks (MASVS L1 list); dependency and secret scans; log-leak test; decisions on certificate pinning, device-bound biometric step-up, and an AfterMe PIN for devices with no screen lock; fix every finding of S1/S2 severity.
- Recommended: an external penetration test before public launch (budget permitting).
- **Exit:** A written security review report; zero open S1/S2 findings.
- **Status (2026-10-12):** **[SECURITY_REVIEW](SECURITY_REVIEW.md)** is the written report. Four independent read-only reviews (authentication and web; data, crypto and engine; mobile MASVS with a real release APK; threat-model and SEC-* coverage), no S1, **three S2, all fixed with regression tests**: a stranger could lock the owner out of sign-in, the lost-phone page and recovery; a stolen access token read every decrypted instruction silently; the API database role could make the worker send a forged "X has not checked in" email (migration `0009`). 15 cheap S3 findings fixed, the rest recorded in SECURITY §18. All 26 SEC-* rows have a test shown able to fail; the threat table grew to T1–T41. Dependencies (pip-audit, OSV) and the secret scan are clean; a lifecycle log-leak test passes. Gates: backend 2055 passed, 96.35%; mobile 3415 passed, 98.6%.
- **Decisions put to the owner (recommendations, [SECURITY_REVIEW §7](SECURITY_REVIEW.md#7-decisions-for-the-owner)):** no certificate pinning in 1.0; no bespoke device-bound biometric key (passkeys with TOTP in 1.1); no AfterMe PIN. And one **taken on the owner's behalf and to be confirmed**: reading instructions now needs the password entered in the last five minutes (the open Phase 6 decision; both backend reviews rated the old behaviour S2; revert is two lines).
- **Owner actions:** confirm or revert the read step-up; commission the external penetration test for staging with real providers (scope in SECURITY_REVIEW §9); the Phase 8 owner actions are still open (email provider, DNS, Firebase projects, staging).

## Phase 10 — End-to-end testing & closed beta · M (+ ≥ 14 days)

- The manual checklist across OEMs; accessibility pass (TalkBack, 200% text); game days OPS-01…03 in staging; defect fixing.
- **Owner actions:** Play Console account ready; ≥ 12 testers recruited (aim for 20+); privacy policy and terms drafted and legally reviewed.
- Start **Play closed testing** as soon as the beta is stable (M3). The 14-day minimum runs while Phases 11–12 proceed.
- **Exit:** The [beta acceptance criteria](TEST_PLAN.md#12-release-acceptance-criteria) met; closed test running.

## Phase 11 — Performance & UX optimisation · S–M

- PERF-01…05; query plans for the hot paths; API call consolidation; app start time; battery (no background work); copy and UX polish from beta feedback; tuning defaults (grace, reminders) from incident data.
- **Exit:** Performance targets met; the beta feedback backlog triaged.

## Phase 12 — Production deployment · M

- **Owner actions:** a production cloud account with billing; production domain live.
- Infrastructure as code; prod Cloud SQL (HA, PITR), Cloud Run API, always-on workers ×2, KMS, Secret Manager, uptime probe, alerting to the owner's phone, dashboards; CI/CD with Workload Identity; backup restore test (OPS-05); failover test (OPS-04).
- **Exit:** Production is running and empty; alerts verified end to end; runbooks rehearsed.

## Phase 13 — Google Play release · S–M

- Production AAB (target 36, 16 KB check), listing and graphics, Data safety, content rating, app access (reviewer account), legal pages live, the [pre-submission checklist](PLAY_STORE.md#10-pre-submission-checklist-phase-13); Play Billing integration if D5 chooses it for 1.0; apply for production access after 12 × 14; staged rollout.
- **Exit (M4):** Live on Google Play; the first 48 h post-launch review done.

---

## After 1.0

| Version | Candidates |
|---|---|
| **1.1** | AI Instruction Assistant (opt-in, review-before-save); SMS/WhatsApp to contacts; TOTP/passkeys; Google Sign-In; pause mode with a mandatory end date; contact acknowledgement ("I'm on it"); attachments (Premium); profile photo; Hindi and other locales; device-bound biometric step-up for I'M SAFE; Play Integrity for signup abuse |
| **1.2** | Multiple contingency plans (Premium); per-contact timezone in emails; richer instruction formatting (safe Markdown subset) |
| **2.x** | iOS; optional end-to-end-encrypted mode (contacts on the app); user web app; organisation/family plans |

## Notes on sequencing

- **Web check-in and web I'M SAFE for a lost phone (FR-CHK-07; `/a/login`, `/a/checkin`, `/a/safe`)** were unassigned until Phase 7, where they were built next to the I'M SAFE flow (the proposal in the Phase 6 report). The owner can still move them; nothing else depends on them.
- **Decisions taken at Phase 4 review (2026-10-10):** a pending check-in older than 12 h is dropped by the app with a notice (ESCALATION_ENGINE §9.1); lengthening the interval of an active schedule needs the password (SECURITY §7); the `timezone` package is accepted; web check-in is still unassigned.
- **Phase 9 → 10 hand-off:** what the review could **not** check needs a physical phone and a deployed environment, and belongs to Phase 10's manual checklist: FLAG_SECURE in recents and screenshots (now also on password and export screens), the SAF export picker, BiometricPrompt across OEMs, push delivery and lock-screen rendering, `adb` launches with route extras against a signed-in dev build (the activity must ignore them; M-02), cold launch of the hand-written `createFlutterFragment` on dev and prod builds, database TLS, trusted-proxy hop count and uvicorn proxy flags, CAA records, the first live Resend/Postmark/FCM error names. **Planning items:** end-to-end tests in staging cannot use the test clock (test support is refused with real providers, F-19), so E2E-01…03 run in real time with short stage offsets; there is no screenshot flavor with FLAG_SECURE off for the Play listing; the Instructions tab asks for the password on first open per five minutes and Home's start-up read answers `403` once per cold start (harmless; could be lazy). **Left open on purpose, all in SECURITY §18:** a persistent multi-network attacker can still degrade *password* sign-in from a new browser in 15-minute windows; stolen-session password guessing has no account-level cap (F4); instruction text edits need no password (F8); the API role can write engine inputs (BD-3) and the worker role is broader than it needs (BD-5); no crash-reporting SDK; `abuse@` is not yet in every contact email (needs the domain); no `suspend` operator command; the two sets of SEC-21/22/23/26 tests overlap and can be merged. **Carried from earlier phases:** cloud KMS adapter and key rotation (production cannot start without it), the Phase 8 owner actions, review of the new email copy.
- **Phase 8 → 9 hand-off:** everything that can be built and tested without the owner's accounts is built: the FCM v1, Resend, Postmark and SMTP adapters with a fallback chain, the delivery/bounce/complaint webhooks, the "contact could not be reached" notices, retention, the device registration endpoint, and on the phone the FCM integration behind interfaces (channels, foreground display, tap routing, token life). **Never run against a real provider or a real phone.** To close M2 the owner provides what DEPLOYMENT §10 lists; then `afterme-admin email-test` / `push-test`, a smoke on the emulator and on a real phone with the dev Firebase project, then E2E-01/02/03 and OPS-03 in staging. Left for Phase 9 (security audit): an opaque per-user id for Activity entries; making direct-send mail durable through the outbox if the owner wants codes to survive a crash between commit and send; the stage summary ("Mom has been notified") that can precede "we couldn't reach Mom" when a provider refuses; counting Hold time in the 24-hour give-up; the remaining retention rows (auth tokens, sessions) which need grants; honouring the plan editor's unsaved-changes guard when a notification is tapped.
- **Phase 7 → 8 hand-off:** providers are still recording/console only (Phase 8 brings FCM and the real email provider, bounce webhooks, notification logs and the user-facing "a contact could not be reached" message; until then Home polls about once a minute while an incident is open). What Phase 7 leaves for later phases: the **cloud KMS adapter** and DEK rotation (production cannot start without the adapter); the **real Android document picker and FLAG_SECURE on a physical phone** (manual checks, Phase 10); an **emulator job in CI** for `tool/integration.sh`; integration cases for instruction release to the portal, the Hold circuit breaker and multi-stage plans; a public `GET /v1/version` so the 426 gate can clear strictly on a 2xx; an opaque per-user id for Activity entries (today it is the platform audit sequence); the other retention jobs of DATABASE §5 (grants exist, jobs do not); Phase 8's staging must keep `TEST_SUPPORT_*` off unless isolated (configuration refuses it with a real email provider). **Decisions for the owner are listed in the Phase 7 report.**
- **Phase 6 → 7 hand-off:** the incident timeline UI, the I'M SAFE flow and `safe_required` handling are still Phase 7 (the backend and contract files exist since Phase 5), plus the plan editor. Phase 6 leaves these for the deployment phases: a **cloud KMS adapter** (`KmsProvider` is the interface; `local` is refused in staging and production, so production cannot start without it), **per-user DEK rotation and KEK re-wrap**, **export** and **account deletion** (the schema and the revocation paths are ready; the endpoints are not), and the push copy for "someone viewed your instruction" (the Activity feed shows `release.viewed` already). **Open owner decision:** whether reading an instruction in the app should need a recent password (ESCALATION_ENGINE §13.3).
- **Phase 5 → 6 hand-off:** the engine already handles releases end to end behind two seams (`app/engine/releases.py`, `app/plans/releases.py`): Phase 6 supplies the instruction-backed implementations, adds the `release_events`/`portal_*` tables (their foreign keys point at `escalation_incidents` and `incident_actions`), creates the releases inside `_stage`, and turns `contact_release` messages and the final warning's real content on. `release_count` is `0` and G8 reports `instructions_unavailable` until then. The mobile app got only the plan wiring in Phase 5 (so onboarding can activate); the incident timeline UI, the I'M SAFE flow and `safe_required` handling are Phase 7.
- **Phase 4 → 5 hand-off:** the activation requirement is "at least one live contact" until the plan exists (`no_contacts`), and `POST /checkins` has no incident branch. Phase 5 replaces the first with `no_stages` and adds the second at the marked line in `app/checkins/service.py`.

- The brief's advice to *start with the escalation engine and its failure scenarios* is honoured on paper in Phase 0 ([ESCALATION_ENGINE](ESCALATION_ENGINE.md)). In code, the engine comes as soon as its inputs exist (contacts → check-in → engine). Nothing user-facing depends on it before Phase 5, so its design can't be bent by UI shortcuts.
- Realistic "today" scope: Phase 0 (this documentation) and, once approved and once Flutter is installed, the start of Phase 1. The Play Store side has a hard minimum of 14 days of closed testing for a personal developer account, so **production on Play cannot happen today**. Starting the owner actions early (domain, Play account, testers) is the best way to shorten the overall path.
