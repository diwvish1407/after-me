# AfterMe — Roadmap

| | |
|---|---|
| **Status** | Phase 0 approved 2026-10-08 · Phases 1–3 built, reviewed and signed off · Phase 4 built, owner decisions applied (sign-off implied by the Phase 5 instruction, 2026-10-10) · Phase 5 built and independently reviewed (17 findings: all dispositioned, 16 fixed or by owner decision implemented, 1 not a defect, see ESCALATION_ENGINE §13.2; the owner's decisions of 2026-10-10 on F-03, F-12, F-05a and the Home gap banner are implemented); awaiting owner review (the engine walkthrough is part of it) |
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

## Phase 6 — Instructions, recipients & release · L

- Categories; instructions with envelope encryption (local KMS provider in dev, KMS interface); recipients with release stages; release events; portal access, tokens, OTP, the viewing page; revocation paths; the Instructions screens (FLAG_SECURE) and starter templates.
- **Exit:** INS-*, REL-* and the related SEC-* (ciphertext swap, portal scope, XSS) tests pass; the lifecycle test includes a real release view.

## Phase 7 — Connect the complete Flutter UI · M

- Replace every fake with the real API; incident timeline UI; the I'M SAFE flow; Plan screen preview; Activity feed; Settings (export, delete); offline/pending behaviour; error mapping; `426` upgrade handling.
- **Exit:** MOB-* tests pass; MOB-61…65 integration tests pass against the dev backend with the test clock.

## Phase 8 — Notifications · M

- **Owner actions:** create Firebase projects (dev/staging/prod); choose the email provider (+ fallback); domain DNS for SPF/DKIM/DMARC; a staging cloud environment (minimal).
- FCM provider (HTTP v1), email provider(s) with idempotency keys, templates (all from [USER_FLOWS §13](USER_FLOWS.md#13-message-copy-10-templates)), the dispatcher's retry/backoff/fallback, bounce/complaint webhooks, notification logs, lock-screen privacy on Android.
- **Exit (M2):** NOT-* tests pass; E2E-01/02/03 pass in staging with real email and push.

## Phase 9 — Security audit · M

- Threat-model review against the built system; the full SEC-* suite; mobile checks (MASVS L1 list); dependency and secret scans; log-leak test; decisions on certificate pinning, device-bound biometric step-up, and an AfterMe PIN for devices with no screen lock; fix every finding of S1/S2 severity.
- Recommended: an external penetration test before public launch (budget permitting).
- **Exit:** A written security review report; zero open S1/S2 findings.

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

- **Not assigned to a phase yet:** web check-in and web I'M SAFE for a lost phone (FR-CHK-07; `/a/login`, `/a/checkin`, `/a/safe`). Proposed: Phase 7, next to the I'M SAFE flow, because I'M SAFE needs the incident model from Phase 5. The owner decides.
- **Decisions taken at Phase 4 review (2026-10-10):** a pending check-in older than 12 h is dropped by the app with a notice (ESCALATION_ENGINE §9.1); lengthening the interval of an active schedule needs the password (SECURITY §7); the `timezone` package is accepted; web check-in is still unassigned.
- **Phase 5 → 6 hand-off:** the engine already handles releases end to end behind two seams (`app/engine/releases.py`, `app/plans/releases.py`): Phase 6 supplies the instruction-backed implementations, adds the `release_events`/`portal_*` tables (their foreign keys point at `escalation_incidents` and `incident_actions`), creates the releases inside `_stage`, and turns `contact_release` messages and the final warning's real content on. `release_count` is `0` and G8 reports `instructions_unavailable` until then. The mobile app got only the plan wiring in Phase 5 (so onboarding can activate); the incident timeline UI, the I'M SAFE flow and `safe_required` handling are Phase 7.
- **Phase 4 → 5 hand-off:** the activation requirement is "at least one live contact" until the plan exists (`no_contacts`), and `POST /checkins` has no incident branch. Phase 5 replaces the first with `no_stages` and adds the second at the marked line in `app/checkins/service.py`.

- The brief's advice to *start with the escalation engine and its failure scenarios* is honoured on paper in Phase 0 ([ESCALATION_ENGINE](ESCALATION_ENGINE.md)). In code, the engine comes as soon as its inputs exist (contacts → check-in → engine). Nothing user-facing depends on it before Phase 5, so its design can't be bent by UI shortcuts.
- Realistic "today" scope: Phase 0 (this documentation) and, once approved and once Flutter is installed, the start of Phase 1. The Play Store side has a hard minimum of 14 days of closed testing for a personal developer account, so **production on Play cannot happen today**. Starting the owner actions early (domain, Play account, testers) is the best way to shorten the overall path.
