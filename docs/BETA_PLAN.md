# AfterMe — Closed beta plan

| | |
|---|---|
| **Status** | Draft v0.1 (Phase 10), awaiting product-owner approval |
| **Audience** | The product owner, who is also the operator and the person on call |
| **Related** | [TEST_PLAN §7, §8, §11, §12](TEST_PLAN.md#7-end-to-end-and-operational-tests-staging) · [PLAY_STORE §9](PLAY_STORE.md#9-testing-tracks) · [DEPLOYMENT §7, §9](DEPLOYMENT.md#7-monitoring-and-alerting) · [MANUAL_TEST_SHEET](MANUAL_TEST_SHEET.md) · [TESTER_GUIDE](TESTER_GUIDE.md) · [GAMEDAYS](GAMEDAYS.md) |

The beta exists to answer one question with evidence: **does AfterMe do exactly what it says, to the right people, at the right time, and nothing else?** Everything below serves the two acceptance rules of [TEST_PLAN §12](TEST_PLAN.md#12-release-acceptance-criteria): *zero open S1/S2* and *zero wrongful contact messages, with every escalated incident reviewed*.

---

## 1. The sequencing problem you need to decide first

Google Play closed testing belongs to **one application**, the one with the production application ID (`app.afterme`, the `prod` flavor). The `staging` flavor has a different application ID (`app.afterme.staging`) and can never be uploaded to that listing. So:

| What | Build | Reaches | Distributed by |
|---|---|---|---|
| Staging tests: manual checklist on real phones, game days, E2E-01…03 | `staging` flavor (`app.afterme.staging`) | the **staging** backend | APK installed directly by you (sideload) |
| **Play closed testing (the 12 testers × 14 days)** | `prod` flavor (`app.afterme`) | whatever `config/prod.json` says: **the production backend** | Play closed testing track |

The 14-day clock only counts for the real app, so **the beta runs on the production deployment**, with beta users on it. The ROADMAP currently puts "Production deployment" in Phase 12, after the beta starts. That order cannot work.

**Recommendation: split the work in three stages and move the core of Phase 12 in front of the Play closed test.**

| Stage | Purpose | Needs | Exit |
|---|---|---|---|
| **A. Staging** | Manual checklist on ≥ 3 OEMs, game days OPS-01…03, E2E-01…03, defect fixing | Staging backend (small, "same shape as prod"), real email provider on a test domain, staging Firebase project, 2–4 phones | Zero open S1/S2; checklist signed on 3 OEMs; game days passed |
| **B. Production, small** | The production backend that the beta will run on: HA database with PITR, KMS (the cloud adapter does not exist yet), two workers, uptime probe, alerting to your phone, backup restore proven (OPS-05) | Cloud account with billing, production domain, production Firebase project, **the cloud KMS adapter** | "Production is running and empty; alerts verified end to end" (Phase 12's exit) |
| **C. Closed test** | The 12 × 14 rule, real-time behaviour, real inboxes | Play Console account (identity verified), legal pages live, ≥ 12 (aim 20+) testers | The production acceptance list in §9 |

Stages A and B can overlap. **Stage C must not start before B**, and it must not start before the entry checklist in §3 is fully ticked.

The beta users' accounts are then production accounts. Decide up front whether they are kept at launch or deleted (§10, decision 2).

## 2. What can be proven where

| Claim | Proven by | Where |
|---|---|---|
| The engine does the right thing across time, failure and concurrency (T0–T8, INV-1…10) | `make engine-gate` (100×), the lifecycle, invariant, stateful and concurrency suites | CI, nightly |
| The whole stack agrees: app → API → worker → mail → portal → app | `mobile/tool/integration.sh` (MOB-61…68) on an emulator with the test clock | CI (weekly) and before each build |
| The operational runbooks work with real processes | `make gameday` (OPS-01…03 rehearsal against a throwaway database) | Your machine, before staging |
| The same, with real providers, real DNS, real ingress | GAMEDAYS.md procedure | **Staging** |
| It works on real phones, networks and mail clients | MANUAL_TEST_SHEET.md | **Real devices** |
| Real people can use it, and it behaves in real time | The closed test | **Production** |

The first three rows are done by the build (the emulator suite and the nightly job exist as workflows that have not yet run on a hosted runner: their first run is part of the entry checklist). The last three need your accounts, your phones and your testers; nothing in the repository can substitute for them.

## 3. Entry checklist (before the first tester is invited)

**Backend and operations**
- [ ] Stage B complete: production backend running; `python -m cli.admin status` clean; uptime probe arriving; an alert routed to your phone and acknowledged (page yourself on purpose).
- [ ] OPS-01, OPS-02, OPS-03 passed in staging ([GAMEDAYS.md](GAMEDAYS.md)); OPS-05 (restore) passed; OPS-04 passed or consciously deferred.
- [ ] `KMS_PROVIDER` is the cloud adapter (`local` is refused in production, so this is a start-up blocker); a DEK/KEK rotation drill done.
- [ ] Email: sending domain verified (SPF, DKIM, DMARC), the primary **and** the fallback provider configured, webhooks verified with a real bounce to a dead mailbox you own and a real complaint test where the provider allows it.
- [ ] Push: production Firebase project, a real token registered on a real phone, delivery verified with the app killed.
- [ ] Nightly 100× lifecycle job green for 7 consecutive nights (`.github/workflows/nightly.yml`).
- [ ] `python -m cli.admin beta-report` runs against production and shows no incident you cannot explain.
- [ ] Hold: you have entered and exited it by hand once in staging, and you know the three kinds ([ESCALATION_ENGINE §7](ESCALATION_ENGINE.md)).

**Product and legal**
- [ ] Privacy policy and terms **reviewed by counsel** and live at `<PUBLIC_BASE_URL>/legal/privacy` and `/legal/terms` (drafts: [legal/](legal/)). **Nothing in the backend serves these paths yet:** the app (About, sign-up consent) and the Play listing link to them, so publish the final texts there as static pages (the website or the web server) before the first tester, or they are dead links.
- [ ] The account-deletion page `/a/delete` works on production and the in-app path works.
- [ ] A support address that you actually read (`support@…`) and an abuse address (see SECURITY_REVIEW F-09: not yet in every contact email).
- [ ] The email copy reviewed by you against [USER_FLOWS §15](USER_FLOWS.md#15-wording-rules): withdrawn alert, contact unreachable, deletion notices, the alert to contacts.
- [ ] The Play listing exists in draft; Data safety form completed **and consistent with what the app really does** (no crash-reporting SDK is integrated in 1.0, which the draft form still assumes).

**Builds and devices**
- [ ] A signed `prod` AAB from `mobile/tool/build_release.sh` (upload key, not the debug key), symbols and the R8 mapping archived privately per version.
- [ ] MANUAL_TEST_SHEET passed on ≥ 3 OEMs (Pixel, Samsung, one of Xiaomi/Oppo/OnePlus) plus the low-end and Android 8 devices; every S1/S2 closed.
- [ ] The Play pre-launch report reviewed.

## 4. Who does what

| Role | Who | Responsibilities |
|---|---|---|
| **Operator and on-call** | You | Daily check (§6), every incident review (§7), stop-the-line decisions (§8), tester communication, S1/S2 triage |
| **Developer** | You and the build assistant | Fixes, builds, the weekly release train |
| **Testers** | ≥ 12 opted in, aim for 20+ | Use the app for 14 days as in TESTER_GUIDE.md; report problems |
| **Testers' trusted contacts** | People the testers choose | Agree to be contacts **before** being added; receive real emails |

**One person is a single point of failure for a safety product.** During the beta, name a second person who can read the alert and enter Hold. Without one, tell testers honestly that alerts are watched by one person and that AfterMe is not an emergency service.

## 5. Cohort and consent

- **Size:** recruit 20 or more so that ≥ 12 stay opted in for the 14 days. If active testers fall below 12 at any point, the Play count restarts ([PLAY_STORE §1](PLAY_STORE.md#1-critical-path-and-timeline)).
- **Mix:** at least 4 Android makes (including one aggressive battery manager), at least 3 testers on Android 8–10, two on slow or flaky mobile data, at least 2 who use TalkBack or large text if you can find them, and a few who are not technical.
- **Contacts:** every tester must add only people who have **agreed in advance** to receive test emails from AfterMe, including the possibility of an alert and a message with a link to shared information. The invitation flow gives each contact consent and an opt-out, but a stranger who gets an alert about a person they do not know is a harm we caused. Testers who want a safer rehearsal use a second mailbox of their own as the contact.
- **Content:** tell testers to put **fictional or low-sensitivity** text in instructions during the beta. The content is encrypted and never appears in mail or push, but the beta is also the period in which defects are found.
- **Informed consent:** every tester gets TESTER_GUIDE.md and replies once that they understood: this is a test, the person is still responsible for their safety, AfterMe does not call emergency services, and data may need to be reset.
- **18+ only.** Ask for it at recruitment.

## 6. Operating rhythm

| When | What | Command / place |
|---|---|---|
| **Every morning (5 min)** | Is anything paging or warning? Yesterday's incidents reviewed? | `python -m cli.admin status`; `python -m cli.admin beta-report --since <yesterday>` |
| **Within 24 h of any incident that reached a contact** | Review it (§7) and record the verdict | the report's `NEEDS HUMAN REVIEW` blocks |
| **Weekly (30 min)** | Metrics table (§9), tester count still ≥ 12 (Play Console), open defects, the nightly job history | Play Console, `beta-report --since <monday>`, GitHub Actions |
| **Weekly** | Release train: one build per week at most, with the manual sheet's "regression" rows; never change engine behaviour in the last 3 days before a tester's planned dry run | `mobile/tool/build_release.sh` |
| **On every new build** | Smoke: install, onboarding, check-in, I'M SAFE path | MANUAL_TEST_SHEET §A–C |

## 7. Reviewing an escalated incident

**Definition.** A **wrongful contact message** is any message to a contact (alert, release, all-clear, withdrawal) that was sent although, by the rules the person set, it should not have been, or that was caused by a fault in AfterMe. It is **not** wrongful when the person really missed their check-ins under their own plan, including a rehearsal that the tester announced in advance.

For each incident in `beta-report` that reached a contact:

1. **Intended?** Did the tester announce a rehearsal (the feedback form's "I am testing a missed check-in today" entry)? If yes: expected; check only the timing and delivery below.
2. **Timing.** Compare the report's timeline with the plan: first message not before the grace period ended plus the settle delay; stage offsets honoured; a stage that ran late was delayed and the person was told (`incident_delayed`), not run early.
3. **Cause of the miss.** Was the app reachable? Look for: a Hold shortly before (`opened_within_24h_of_hold_exit`), a check-in that the server received late (offline tap, the 12 h pending rule), a time zone change, a restored phone, notification permission revoked, the 426 upgrade gate.
4. **Delivery.** Did every contact get exactly one alert? Duplicates are an S1. A contact whose message failed is an S2 (the person was told `contact_unreachable`).
5. **Resolution.** If the person was fine, how long until the all-clear reached every contact? (The all-clear is queued at the moment of I'M SAFE; minutes, not hours.)
6. **Verdict.** `expected`, `expected, copy or timing issue (S3)`, `wrongful: user error that the product invited (S2: fix the product)`, or `wrongful: system fault (S1)`.

Write the verdict, the incident id and one sentence in the beta log (a spreadsheet is fine). **Never paste names, addresses or instruction text into the log or into a bug ticket**: the report does not contain them on purpose; if you need to talk to the tester, use the user id to find them.

## 8. Stop-the-line

Stop inviting testers, freeze builds and **enter Hold** (`python -m cli.admin hold enter --reason "…"`) when any of these is true, then investigate before anything else:

| Trigger | Why |
|---|---|
| A confirmed wrongful contact message (S1), or two unexplained ones in a week | The product's promise is broken |
| A contact received a message twice for one event | Duplicate effects violate INV-5 |
| Instruction content, a link or a code in a log, an email subject, a push or a ticket | Privacy failure |
| A person was shown, or could read, another person's data | Cross-user exposure |
| An escalation message failed for every provider and nobody was told | The silent-failure case |
| The worker heartbeat or the probe is red and you cannot fix it within 30 minutes | The engine cannot be trusted; the Hold is the safe state |
| Crash-free sessions < 99% over a day, or a crash on launch for a whole device family | Check-ins impossible = S1 |

**While in Hold**, reminders to the people continue; contact-facing messages wait and deadlines are shifted when the Hold ends. Tell testers in plain words that an interruption happened and that nothing was sent to their contacts. **Resume** (`hold exit`) only with a written cause and a regression test or a configuration fix.

## 9. What the beta must show (production acceptance)

| Criterion | Source | How it is measured |
|---|---|---|
| ≥ 12 testers opted in for ≥ 14 continuous days | Play (personal account) | Play Console → Closed testing |
| **Zero** wrongful contact messages; every escalated incident reviewed | TEST_PLAN §12 | `beta-report` + the beta log |
| Zero open S1/S2 | TEST_PLAN §11/§12 | issue list |
| Crash-free sessions ≥ 99.5%, ANR below Play's bad-behaviour thresholds | TEST_PLAN §12 | Play Console → Android vitals |
| Reminder and alert delivery healthy | DEPLOYMENT §7 | `python -m cli.admin status` (provider errors, bounces, complaints, backlog) |
| OPS-04 and OPS-05 passed; alerts reach a person | TEST_PLAN §12 | game-day records |
| Data safety form and store listing complete and truthful | PLAY_STORE §10 | checklist |
| Manual checklist repeated on the release candidate | TEST_PLAN §8 | MANUAL_TEST_SHEET |

**Weekly metrics table** (from `beta-report`, copy into the beta log): active testers; check-ins per day (app/web); missed check-ins; incidents opened; incidents that reached contacts (rehearsed vs unannounced); I'M SAFE time-to-all-clear; Hold minutes; message delivery rate by template; bounces and complaints; `incident_delayed` count; tickets by severity.

## 10. Decisions for the owner

| # | Decision | Recommendation |
|---|---|---|
| 1 | **Re-sequence**: production backend before Play closed testing (§1) | **Decided by the owner, 2026-10-12: yes.** Run staging tests and stage B in parallel; start the 14-day clock only when both are done |
| 2 | What happens to beta accounts at launch | **Decided 2026-10-12: keep them.** Keep them (testers keep their setup) **if** the beta ran on the final production database and the legal pages cover it; otherwise reset with notice. Tell testers which at the start |
| 3 | A second person on call | **Decided 2026-10-12: yes, someone is in mind** (runbook for them to be written; the entry checklist blocks the 14-day clock until they have access) |
| 4 | Personal vs organization Play account (PRD D2) | **Decided 2026-10-12: personal.** The personal account forces 12 × 14; an organization account does not. If a legal entity exists or is planned within weeks, the D-U-N-S route can save the whole recruiting exercise |
| 5 | Staged beta size | Start with 5 (including you) for 3 days to catch what the manual sheet missed, then grow to 20+ |
| 6 | How to grant Premium during the beta | `python -m cli.admin user set-tier <user_id> premium --reason beta` (audited); Play Billing stays off until D5 |
| 7 | Crash reporting | **Decided 2026-10-12: none for the beta, Play vitals only.** None is integrated; Play Console's Android vitals are the only crash data. Decide whether a scrubbed crash reporter is wanted before launch (it changes the Data safety form) |

## 11. Message templates

**Invitation (to a tester).** *"Thank you for helping to test AfterMe, an app that tells people you choose, and shares information you choose, if you stop checking in. It is a test: please read the guide first, use only contacts who agreed to receive test emails, and put made-up information in instructions. It is not an emergency service. Install from this link (Google account required): …. Reply 'understood' to this message."*

**Weekly note.** What changed in this build; what to try this week (one scenario from TESTER_GUIDE §5); known issues; how to reach you.

**Interruption notice.** *"On <date> we paused AfterMe's notifications to contacts for <n> minutes while we fixed a problem. Nobody was told anything that was not true, and your check-in deadlines were moved so that you were not penalised for the pause. If you saw anything unexpected, please tell us."* (Send only when it is true: read the Hold history first.)

**Wrongful-message apology to a contact.** Plain, brief, says what was sent, why it was wrong, that the person is fine, who to write to. Send within the day of the verdict.

## 12. After the beta

When the §9 table is met for 14 continuous days: apply for production access in Play Console; write the beta report (metrics, incidents and verdicts, defects found and fixed, what changed because of testers); freeze a release candidate; repeat the manual sheet and the game days on it; then Phase 13.
