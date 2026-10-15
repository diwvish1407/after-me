# AfterMe — Product Requirements Document

| | |
|---|---|
| **Status** | Draft v0.1 — awaiting product-owner approval |
| **Date** | 2026-10-08 |
| **Product owner** | Diwakar |
| **Tagline** | *If you can't answer, your instructions can.* |
| **Related** | [ARCHITECTURE](ARCHITECTURE.md) · [ESCALATION_ENGINE](ESCALATION_ENGINE.md) · [USER_FLOWS](USER_FLOWS.md) · [ROADMAP](ROADMAP.md) |

---

## 1. Summary

AfterMe is a personal contingency-planning app. The user checks in on a schedule they choose ("I'M OK"). If they miss a check-in, AfterMe reminds them during a grace period. If they still don't respond, it follows the escalation plan the user wrote in advance: it notifies chosen trusted contacts and, at later stages, shares specific instructions with specific people. The user can stop everything at any time by confirming "I'M SAFE".

The product's value is **controlled disclosure**: *who* gets *what* information, and *when*. Everything is decided by the user ahead of time and enforced by the server.

## 2. Problem

When someone becomes unexpectedly unreachable (hospitalised, travelling with no signal, phone lost, in an accident), the people around them often need information that only that person has:

- who to call and in what order
- how to handle the home, pets, bills, insurance
- where important documents are
- what to tell an employer or business partner
- personal messages

That information is usually scattered across chats, notes, email and memory. Nobody knows it exists until it's needed, and by then it can't be reached.

## 3. Positioning and language

AfterMe is an **emergency-preparedness** product. It is **not** a death-detection product, an emergency service, or a legal will.

| Use | Never use |
|---|---|
| Missed check-in | "We detected your death" / "deceased" / "passed away" |
| Escalation, stage | "Dead man's switch" (in user-facing copy) |
| Trusted contact | "Beneficiary", "heir" |
| Contingency plan, instructions | "Last will", "estate" |
| Release, share | "Unlock your secrets" |
| I'M OK / I'M SAFE | Skulls, cemeteries, candles, black-bordered imagery |

The system only knows one fact: **an expected check-in was not received.** All copy must be consistent with that. For example, a contact alert says *"Diwakar hasn't checked in since 8:00 PM yesterday. This doesn't necessarily mean anything is wrong."*

Required disclaimers (onboarding, terms, store listing):
- AfterMe does **not** contact emergency services. In an emergency, call your local emergency number.
- Instructions stored in AfterMe are **not** a legal will and are not legally binding.
- AfterMe cannot know why a check-in was missed.

> **Naming note for the owner:** "AfterMe" can be read as "after I'm gone", which pulls against the "not a death app" positioning. The tagline helps. Treat this as a conscious brand decision before the store listing and the application ID are fixed (see §15).

## 4. Users

### Primary user: the planner
An adult (18+) who wants to prepare information for others. Example personas:

| Persona | Situation | What they need |
|---|---|---|
| **Solo professional away from family** | Lives alone in another city or country; parents worry | Family alerted if they go quiet; parents know who to call (landlord, employer, a friend nearby) |
| **Household manager** | Handles bills, insurance and documents for the family | Spouse gets the "how our household runs" information only if it's really needed |
| **Key person at work / small-business owner** | Others depend on knowledge only they have | A colleague gets operational instructions after a set delay |
| **Traveller / solo adventurer** | Trekking, travelling alone | A shorter check-in window during the trip; family alerted quickly |

### Secondary user: the trusted contact (usually **not** an app user)
Receives an invitation, possible alerts, released instructions and an all-clear, all **through email and a secure web page**. They may be older, non-technical and on a phone. Every contact-facing surface must be understandable without installing anything.

## 5. Goals and non-goals

### Goals
- **G1 — Fast setup:** A new user reaches a working plan (verified email, a check-in schedule, at least one contact invited) in **≤ 5 minutes** (median).
- **G2 — No wrongful release (top priority):** Information is never released while the user has checked in, and never released because of a system fault. *Fail-safe, not fail-trigger.*
- **G3 — Reliable escalation:** When the conditions the user set are genuinely met, the defined actions happen on time.
- **G4 — Trust:** Users understand exactly what will happen, when, and to whom, and can stop it.

### Non-goals (1.0)
- Detecting death, injury or location
- Calling or dispatching emergency services
- Legal estate planning, wills, or asset transfer
- Acting as a password manager (we discourage storing passwords; see FR-INS-07)
- iOS (the architecture must allow it later)
- AI features (planned for 1.1, see §8.13)
- Social, community or sharing features

## 6. Glossary

| Term | Meaning |
|---|---|
| **Check-in** | The user pressing I'M OK (or I'M SAFE). It is recorded **server-side**, and only the server's timestamp counts. |
| **Deadline** (`next_due_at`) | The instant by which the next check-in must be received. |
| **Schedule** | The rule that produces deadlines, e.g. "every 1 day by 8:00 PM, Asia/Kolkata". |
| **Incident** | Opened when a deadline passes without a check-in. One incident per missed deadline; at most one open incident per user. |
| **Grace period** | The first part of an incident. Only the **user** is reminded; no one else is contacted. |
| **Escalation plan** | The grace period plus an ordered list of **stages**. |
| **Stage** | A point in time (an offset from the start of the incident) at which chosen contacts are notified and/or chosen instructions are released. |
| **Trusted contact** | A person the user invited. They must **accept** before they can receive anything. |
| **Instruction** | A piece of information the user wrote (title, body, category). Encrypted at rest. |
| **Recipient assignment** | One instruction → one contact → one stage. This is the "who gets what, when" rule. |
| **Release** | The moment a recipient assignment executes. The contact gets a secure link and verifies with a one-time code to view the instruction. |
| **Recipient portal** | The web pages contacts use (invitation, alert, viewing released information). There is no app install. |
| **All-clear** | The message sent to every contact who was alerted, once the user confirms I'M SAFE. |
| **Hold** | A system-wide safety state in which no contact-facing actions run (see [ESCALATION_ENGINE §7](ESCALATION_ENGINE.md#7-system-hold-the-circuit-breaker)). |

## 7. Scope

### 7.1 In MVP (1.0)

| Area | Included |
|---|---|
| Account | Register with emailed code verification, login, logout, logout all devices, forgot/reset password, change password, change email, delete account, export data |
| Profile | Name, email, phone, country, timezone, language |
| Trusted contacts | Add/edit/remove, relationship, priority, **invitation + acceptance (consent)**, opt-out |
| Check-in | Configurable schedule, I'M OK, pre-deadline reminder, check-in history |
| Escalation | Grace period, up to N stages (by tier), incident timeline, user reminders, final warning before any release |
| Instructions | 11 categories, title/body, active/inactive, per-recipient release stage |
| Release | Secure recipient portal with one-time code, revocation on cancellation |
| Cancellation | I'M SAFE with re-authentication, all-clear to alerted contacts, revoked access |
| Notifications | Push (user), email (user and contacts); a provider abstraction for push/email/SMS |
| Web | Recipient portal, **web check-in for users who lost their phone**, web account-deletion request, legal pages |
| Security | App lock (biometric with device-credential fallback), encrypted instructions, audit log, rate limiting |
| Activity | A user-visible activity log (check-ins, alerts sent, releases, views) |
| Monetization | Server-enforced tier limits. Whether Play Billing is wired in for 1.0 or 1.1 is an owner decision (§15) |

### 7.2 Deferred (with reason)

| Feature | Target | Reason |
|---|---|---|
| AI Instruction Assistant | 1.1 | Not core; needs privacy review (sends user text to an LLM) |
| SMS / WhatsApp to contacts | 1.1 | Cost and regulation (e.g. India DLT template registration, US 10DLC); email covers 1.0 |
| File attachments | 1.1 (Premium) | Needs object storage, malware scanning and encryption pipeline |
| Profile photo upload | 1.1 | Needs object storage; low value for 1.0 |
| Multiple contingency plans | 1.2 (Premium) | Schema allows it; UX is complex |
| Pause schedule ("vacation mode") | 1.1 | Risk of forgetting to un-pause; needs a mandatory end date |
| Google Sign-In / passkeys | 1.1 | Email and password first; add federated sign-in later |
| End-to-end-encrypted mode | 2.x | Requires contacts to install the app and exchange keys (see [SECURITY §6](SECURITY.md#6-cryptography)) |
| iOS | 2.x | Flutter makes it feasible; store work and push differ |
| Contact acknowledgement ("I'm handling this") | 1.1 | Useful coordination; not essential |

## 8. Functional requirements

Priority: **M** = must have for 1.0, **S** = should have, **C** = could have.

### 8.1 Authentication (FR-AUTH)

| ID | Requirement | P |
|---|---|---|
| FR-AUTH-01 | Register with email and password (min 10 chars, max 128, checked against a common-password blocklist, no composition rules). | M |
| FR-AUTH-02 | The register and forgot-password endpoints never reveal whether an email exists. | M |
| FR-AUTH-03 | Email verification by 6-digit code entered in the app during signup (15 min expiry, 5 attempts, resend after 60 s). The account is usable only after verification, so there are no half-verified accounts and contact invitations always come from a verified address. | M |
| FR-AUTH-04 | Login returns a short-lived access token and a rotating refresh token. Sessions survive long periods of normal daily use (see §9). | M |
| FR-AUTH-05 | Logout (this device) and logout of all devices. | M |
| FR-AUTH-06 | Forgot/reset password by single-use link (30 min expiry). A reset revokes all sessions. | M |
| FR-AUTH-07 | Change password; requires the current password and revokes other sessions. | M |
| FR-AUTH-08 | Re-authentication (password) is required within the last 5 min for: I'M SAFE, deactivate check-ins, make the interval of an active check-in schedule longer, delete account, export data, change email. | M |
| FR-AUTH-09 | Account deletion in-app **and** via a public web page (Play Store requirement). | M |
| FR-AUTH-10 | Login and other sensitive endpoints are rate-limited per IP and per account. | M |

### 8.2 Profile (FR-PROF)

| ID | Requirement | P |
|---|---|---|
| FR-PROF-01 | Display name (shown to contacts), phone (E.164, optional), country, language. | M |
| FR-PROF-02 | Timezone (IANA), detected from the device on signup and confirmed by the user. This is the timezone used for the schedule. | M |
| FR-PROF-03 | When the device timezone differs from the profile timezone, the app suggests updating it. It **never changes it automatically.** | S |
| FR-PROF-04 | Change email (re-auth + verification of the new address). | S |

### 8.3 Trusted contacts (FR-CON)

| ID | Requirement | P |
|---|---|---|
| FR-CON-01 | Add a contact: name, relationship (preset list + "Other"), email (required in 1.0), phone (optional, for the user's reference and future SMS), priority order. | M |
| FR-CON-02 | Adding a contact sends an **invitation** explaining what AfterMe is, who invited them and what they may receive. The contact must **accept** before receiving any alert or release. | M |
| FR-CON-03 | Contact states: `pending` → `verified` (accepted) / `declined`; `opted_out` (contact withdrew later); `bounced` (undeliverable). | M |
| FR-CON-04 | Every message to a contact has an opt-out link. A contact can also block **all** future AfterMe invitations to their address. | M |
| FR-CON-05 | Resend the invitation (rate-limited), edit details (changing the email resets verification), remove a contact. | M |
| FR-CON-06 | Add from the phone's contacts using the **system contact picker**, without the READ_CONTACTS permission. | S |
| FR-CON-07 | The dashboard warns when the plan depends on contacts who have not accepted. | M |

### 8.4 Check-in (FR-CHK)

| ID | Requirement | P |
|---|---|---|
| FR-CHK-01 | Schedule: "Check in every **N** day(s) by **HH:MM**" in the profile timezone (N = 1–30). Default: every 1 day by 20:00. | M |
| FR-CHK-02 | Pressing **I'M OK** records a check-in **on the server**. The app shows success **only after the server confirms**. | M |
| FR-CHK-03 | The next deadline is computed **server-side** (see [ESCALATION_ENGINE §3](ESCALATION_ENGINE.md#3-deadline-computation)). The client never sends deadlines or times that the server trusts. | M |
| FR-CHK-04 | Pre-deadline reminder (push), default 60 min before; options: off/30/60/120/240 min. | M |
| FR-CHK-05 | If the check-in request fails (offline or server error), the app shows "Not received yet", retries automatically with the same idempotency key, and keeps the user informed. | M |
| FR-CHK-06 | Check-in history (date/time, device, web or app). | S |
| FR-CHK-07 | Users can check in from the **web** (login required) if they lost their phone. | M |
| FR-CHK-08 | Schedule changes are not allowed while an incident is open (check in first). | M |

### 8.5 Escalation (FR-ESC)

| ID | Requirement | P |
|---|---|---|
| FR-ESC-01 | A grace period of 1–72 h (default 3 h) during which only the user is reminded: at the start, at the midpoint, and 15 min before the end. | M |
| FR-ESC-02 | Stages: each has an offset from the start of the incident (≥ the grace period), a set of contacts to **notify**, and the instruction releases assigned to it. | M |
| FR-ESC-03 | Stages are strictly ordered, at least 30 min apart, and at most 30 days after the start of the incident. | M |
| FR-ESC-04 | A stage that releases instructions must be **≥ 24 h** after the start of the incident (a fail-safe minimum; server-configured). | M |
| FR-ESC-05 | 60 min before any stage that releases instructions, the user gets a **final warning** listing what will be shared and with whom. | M |
| FR-ESC-06 | Each time a stage runs, the user is told what happened ("Mom has been notified"). | M |
| FR-ESC-07 | The plan editor shows a plain-language timeline: *"If you miss 8:00 PM: 11:00 PM — Mom is notified. Next day 8:00 PM — Brother is notified and receives 'House emergency'."* | M |
| FR-ESC-08 | During an incident, the home screen shows the live timeline, including what has happened and what happens next and when. | M |
| FR-ESC-09 | Recommended presets in onboarding ("Standard", "Traveller") that the user can edit. | S |
| FR-ESC-10 | The plan as it was when the deadline was missed governs the incident. Later edits can only **narrow** what happens (e.g. a deleted instruction is not released). | M |

### 8.6 Instructions (FR-INS)

| ID | Requirement | P |
|---|---|---|
| FR-INS-01 | Categories: Personal, Family, Home, Work, Business, Documents, Insurance, Pets, Travel, Digital Accounts, Other. | M |
| FR-INS-02 | Fields: title (≤ 120 chars), body (≤ 20,000 chars, plain text with line breaks), category, active/inactive, created/updated timestamps. | M |
| FR-INS-03 | Recipients: one or more contacts, each with its **own release stage**. | M |
| FR-INS-04 | Inactive instructions are never released. | M |
| FR-INS-05 | The title and body are encrypted at rest and never appear in notifications, emails, push payloads or logs. | M |
| FR-INS-06 | Instruction screens block screenshots and hide content in the app switcher. | M |
| FR-INS-07 | In Digital Accounts, guidance says: *don't paste passwords; say where they can be found* (e.g. a password manager's emergency-access feature). | M |
| FR-INS-08 | Tier limits are enforced server-side. | M |
| FR-INS-09 | Attachments: deferred. The schema reserves space for them. | C |

### 8.7 Release (FR-REL)

| ID | Requirement | P |
|---|---|---|
| FR-REL-01 | A release creates a revocable access record. The contact receives an email with a link but **no instruction content**. | M |
| FR-REL-02 | The portal asks for a 6-digit one-time code sent to the contact's verified email before showing content. | M |
| FR-REL-03 | One portal view per contact per incident shows every instruction released to them so far. | M |
| FR-REL-04 | Links expire after 30 days. While the release is still valid, the contact can request a fresh link (sent only to their verified address). | M |
| FR-REL-05 | Views are recorded, and the user sees them in Activity if they return. | M |
| FR-REL-06 | Released content is served with no-cache and no-index headers. | M |

### 8.8 Cancellation (FR-CAN)

| ID | Requirement | P |
|---|---|---|
| FR-CAN-01 | During the **grace period**, I'M OK resolves the incident. Nobody else ever knew. | M |
| FR-CAN-02 | After any contact was notified, the user confirms **I'M SAFE** (re-auth required). This cancels all pending actions, revokes every release from that incident, sends an all-clear to every contact who was messaged, and restarts the schedule. | M |
| FR-CAN-03 | Cancellation works from the app **and** from the web. | M |
| FR-CAN-04 | Audit history is preserved. | M |
| FR-CAN-05 | The user is told honestly that information already **viewed** by a contact cannot be "un-seen". | M |

### 8.9 Notifications (FR-NOT)

| ID | Requirement | P |
|---|---|---|
| FR-NOT-01 | Channels behind a provider abstraction: push (FCM), email, SMS (interface only in 1.0). | M |
| FR-NOT-02 | Every notification is written to an outbox and delivered by a background dispatcher with retries. Every attempt is logged. | M |
| FR-NOT-03 | User reminders go via push **and** email (push alone can be silently dropped). | M |
| FR-NOT-04 | Push payloads contain no sensitive data. | M |
| FR-NOT-05 | Email is sent from an authenticated domain (SPF, DKIM, DMARC). | M |
| FR-NOT-06 | A secondary email provider can be configured as a fallback. | S |

### 8.10 Audit and activity (FR-AUD)

| ID | Requirement | P |
|---|---|---|
| FR-AUD-01 | Append-only audit log of security-sensitive events (full list in [SECURITY §9](SECURITY.md#9-audit-logging)). | M |
| FR-AUD-02 | A user-visible Activity feed (a filtered view of their audit events). | M |
| FR-AUD-03 | Audit records never contain instruction content, passwords, tokens or one-time codes. | M |

### 8.11 Settings (FR-SET)

Profile · Security (app lock, change password, active sessions/devices) · Notifications · Timezone · Language · Subscription · Privacy policy · Terms · Export data · Delete account · Help/support · About/version. All **M** except Language (S, English only at launch).

### 8.12 Web surfaces (FR-WEB)

| ID | Requirement | P |
|---|---|---|
| FR-WEB-01 | Recipient portal: invitation accept/decline, view releases, opt-out. | M |
| FR-WEB-02 | User web check-in and I'M SAFE (for a lost or broken phone). | M |
| FR-WEB-03 | Account-deletion request page (public URL for the Play Store). | M |
| FR-WEB-04 | Privacy policy and terms pages. | M |
| FR-WEB-05 | Server-rendered pages with no third-party scripts. GET requests never change state (email link scanners must not trigger actions). | M |

### 8.13 AI Instruction Assistant (1.1, design only now)

The assistant may organise user text, suggest a category, suggest checklists and rewrite for clarity. It must **never** release instructions, change escalation rules, contact anyone, judge whether a person is alive or dead, or save anything without explicit user review. It is opt-in, with clear disclosure that the text is sent to an AI provider. The architecture reserves an `assistant` module and a review-before-save UI pattern.

## 9. Product rules and defaults

These live server-side in configuration. Values marked † are **proposals that need owner sign-off**.

| Rule | Value |
|---|---|
| Check-in interval | 1–30 days; default 1 |
| Default deadline time | 20:00 local |
| Minimum window between a check-in and the next deadline | 12 h (deadline moves to the next day if closer) |
| Pre-deadline reminder | default 60 min |
| Grace period † | min 1 h, max 72 h, default 3 h |
| Stage spacing | ≥ 30 min apart; max offset 30 days |
| Minimum offset for any release stage † | 24 h after the incident starts |
| Final warning before a release | 60 min |
| Re-auth window | 5 min |
| Access token / refresh session | 15 min / 60 days idle, 365 days absolute |
| Portal one-time code | 6 digits, 10 min, 5 attempts, 3 sends/hour |
| Portal link validity | 30 days (renewable while the release is valid) |
| Invitations | max 10 sends/day per user; 3 resends per contact per 7 days |

## 10. Free and Premium †

| | Free | Premium |
|---|---|---|
| Trusted contacts | 1 | Up to 25 (fair-use cap) |
| Instructions | 3 | Up to 200 (fair-use cap) |
| Escalation stages | 2 | Up to 10 |
| Custom stage timing | Presets only | Fully custom |
| Attachments, multiple plans, AI assistant (when shipped) | — | ✓ |
| Price to test † | — | ~US$9.99/year (regional pricing via Play) |

**Lapsed-subscription rule (recommended):** If Premium lapses, the **existing plan keeps working exactly as configured**. Adding or editing beyond free limits is blocked until the user renews or trims. A safety product must never silently disable someone's protections because a card expired, and an open incident is **never** affected by billing state.

On Android, Premium must be sold through **Google Play Billing**. The server verifies purchases. The billing module sits behind an interface so other platforms and providers can be added later.

## 11. Non-functional requirements

| Area | Requirement |
|---|---|
| **Correctness** | Invariants INV-1…INV-10 in [ESCALATION_ENGINE §2](ESCALATION_ENGINE.md#2-safety-invariants) must hold at all times and are covered by automated tests. |
| **Timeliness** | Under normal operation, scheduled actions execute within 2 min of their time (p99). |
| **Availability** | Check-in ingestion target 99.9% monthly. Outages must **not** cause escalation (the Hold mechanism). |
| **Performance** | `POST /v1/checkins` p95 < 500 ms server-side. App cold start < 2 s on a mid-range device. I'M OK is 1 tap after unlock. |
| **Battery** | No background polling. Push-driven. No exact-alarm permission. |
| **Security** | See [SECURITY.md](SECURITY.md). OWASP MASVS-L1 baseline for the app; OWASP ASVS L2 for the API. |
| **Privacy** | Data minimisation, no ads, no third-party analytics SDKs in 1.0, export and deletion in-app. |
| **Accessibility** | WCAG 2.2 AA equivalent: TalkBack labels, 48 dp minimum touch targets, text scale up to 200%, AA contrast, no colour-only status. |
| **Localisation** | English at launch. All strings externalised (ARB). Dates/times formatted by locale. RTL-safe layouts. |
| **Supportability** | Structured logs with request IDs, error monitoring, audit trail. |

## 12. Success metrics

| Metric | Target (first 90 days) |
|---|---|
| Onboarding completion (install → active plan) | ≥ 50% |
| Median time to active plan | ≤ 5 min |
| Users with ≥ 1 **accepted** contact within 7 days | ≥ 60% |
| Invitation acceptance rate | ≥ 50% |
| D30 users still checking in | ≥ 35% |
| Incidents resolved within grace (healthy reminder effect) | Tracked; high is good |
| Incidents escalated then cancelled (false alarms reaching contacts) | Tracked; drives default tuning |
| **Releases caused by system fault** | **0** |
| Crash-free sessions | ≥ 99.5% |

## 13. Assumptions

1. Android first; minimum Android 8.0 (API 26); target API 36 (Play requirement for new apps since 31 Aug 2026).
2. Contacts are reachable by email in 1.0. **This is a market risk** in regions where older relatives mostly use WhatsApp or SMS (see R2).
3. One escalation plan per user in 1.0. The schema supports more.
4. The user's profile timezone governs their schedule.
5. Adults only (18+). Not directed at children.
6. The backend is hosted in a single region chosen by the launch market.
7. Product owner = sole decision-maker. Documents are approved before each phase.

## 14. Risks

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | **Wrongful alert or release** (bug, outage, clock issue) | Severe trust and harm | Fail-safe invariants, Hold mechanism, 24 h minimum for releases, final warning, exhaustive engine tests |
| R2 | Contacts don't read email | Plan ineffective | Invitation acceptance step; dashboard warnings; SMS/WhatsApp in 1.1 |
| R3 | Push notifications delayed or killed by OEM battery savers | User misses reminders and false alarms rise | Email + push for reminders; generous grace defaults; onboarding battery-settings tip |
| R4 | Habit fatigue: users stop checking in and incidents fire | False alarms | Pre-deadline reminders, flexible intervals, clear grace messaging; pause mode in 1.1 |
| R5 | Sensitive-data breach | Severe | Encryption, least privilege, audit, no content in logs or notifications, security review phase |
| R6 | Abuse: spamming invitations to strangers | Reputation and email deliverability | Verified-email gate, invitation rate limits, global opt-out list |
| R7 | Play Store timeline: a new personal account needs a 14-day closed test with ≥ 12 testers | Launch date | Recruit testers early; or use an organization account (exempt) |
| R8 | "Death app" perception | Adoption | Calm design, careful copy, naming decision |
| R9 | Regulatory (India DPDP Act, GDPR, etc.) by market | Legal | Choose the launch market early; privacy policy legally reviewed; hosting region matched |

## 15. Decisions needed from the product owner

| # | Decision | Recommendation |
|---|---|---|
| D1 | **Domain and Android application ID** (the ID is permanent after the first upload) | Register a domain now; use `app.<domain>` reversed, e.g. `app.afterme.android` (pending availability) |
| D2 | **Play developer account type**: personal (closed-test rule applies) or organization (exempt, needs a D-U-N-S number) | Organization if you have a legal entity; otherwise start recruiting 12+ testers now |
| D3 | **Launch market(s)** → hosting region, privacy law, whether SMS/WhatsApp is essential | Decide before Phase 12 |
| D4 | Contact channel for 1.0: email only, or email + SMS | Email only for 1.0; SMS/WhatsApp in 1.1 |
| D5 | **Decided 2026-10-15: no Play Billing in 1.0; Premium only granted by the operator; billing in 1.1.** Monetization at 1.0: free with tier limits and Play Billing, or free closed beta with billing in 1.1 | Build entitlements in 1.0; wire Play Billing just before public production launch |
| D6 | Lapsed-Premium behaviour | Grandfather the existing plan (§10) |
| D7 | Fail-safe defaults: grace 1 h minimum; releases ≥ 24 h | Accept |
| D8 | Web check-in page for users who lost their phone in 1.0 | Include (small, high value) |
| D9 | Profile photo deferred to 1.1 | Accept |
| D10 | Data retention for users who never return after an escalation (open incident, no activity) | Keep releases viewable for 12 months, then notify contacts and purge; needs legal input |
| D11 | **Decided 2026-10-15: Play title "AfterMe" (brand only).** Brand name vs positioning (§3 note) | Decide before the store listing |
| D12 | Hosting provider | Google Cloud (Firebase is already Google; see [DEPLOYMENT](DEPLOYMENT.md)) |
| D13 | Transactional email provider | Choose one with strong transactional deliverability and idempotency support; configure a second provider as fallback |
