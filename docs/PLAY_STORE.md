# AfterMe — Google Play Release Plan

| | |
|---|---|
| **Status** | Draft v0.1 — awaiting product-owner approval |
| **Verified against** | Google Play requirements as published on 2026-10-08. Re-check all policy items in Play Console at Phase 13; policies change. |
| **Related** | [PRD](PRD.md) · [SECURITY §14](SECURITY.md#14-privacy) · [DEPLOYMENT §5.1](DEPLOYMENT.md#51-mobile-build-and-signing) |

---

## 1. Critical path and timeline

The Play Store side has **long lead times that don't depend on code**. Start them early.

| Item | Lead time | Start by |
|---|---|---|
| Domain + application ID decision (permanent) | 1 day | **Now** (Phase 1) |
| Play Console developer account + identity verification | Days to weeks | Phase 1–2 |
| D-U-N-S number (organization account only) | Up to ~30 days | Phase 1 if going the organization route |
| **Closed testing: ≥ 12 opted-in testers for 14 continuous days** (personal accounts created after 13 Nov 2023) | ≥ 14 days, plus recruiting | Recruit during Phase 8; start the test as soon as the beta is stable (Phase 10) |
| Production access application + review | Typically days | After the closed test |
| App review per release | Hours to days | Every release |

**Personal vs organization account (PRD D2):**
- **Personal:** the 12 testers × 14 days closed-test rule applies. If active testers drop below 12 at any point, the 14-day count restarts.
- **Organization:** exempt from that rule; needs a legal entity and a D-U-N-S number; the developer name shown on Play is the organization.

## 2. App identity

| Field | Value |
|---|---|
| Application ID | **Pending D1.** Reverse of a domain you control, e.g. `app.afterme.android`. **Cannot be changed after the first upload.** |
| App name (Play title, ≤ 30) | **AfterMe: Safety Check-In** (24 chars) — pending D11 |
| Default language | English (en-US or en-IN, decided by the launch market) |
| Category | Lifestyle (alternative: Tools) |
| Contact email | `support@<domain>` (must be monitored) |
| Website | `https://<domain>` |
| Privacy policy | `https://<domain>/legal/privacy` |
| Account deletion | In-app (Settings → Delete account) **and** `https://<domain>/a/delete` |

## 3. Technical requirements

| Requirement | AfterMe |
|---|---|
| Format | **Android App Bundle (AAB)** for Play. APKs only for local/sideload testing. |
| Target SDK | **API 36 (Android 16)**: required for new apps and updates since **31 Aug 2026** |
| Min SDK | 26 (Android 8.0) |
| ABIs | arm64-v8a, armeabi-v7a, x86_64 (Flutter default); 64-bit required |
| 16 KB memory page size | Required for apps targeting Android 15+. Verify with Android Studio's APK Analyzer / Play Console bundle explorer. All native libraries (Flutter engine, plugins) must be 16 KB-aligned. |
| Signing | **Play App Signing** (Google holds the app key; we keep the upload key) |
| Obfuscation | `--obfuscate --split-debug-info`; symbols kept privately |
| Permissions | `INTERNET`, `POST_NOTIFICATIONS`, `USE_BIOMETRIC` (+ FCM-merged `WAKE_LOCK`, `RECEIVE_BOOT_COMPLETED` if added by the library). **Not used:** contacts, location, SMS, phone, exact alarms, foreground services, camera, storage. |
| Advertising ID | **Not used.** Check the merged manifest to confirm no dependency adds `com.google.android.gms.permission.AD_ID`; remove it with `tools:node="remove"` if one does. Declare "no advertising ID" in Play Console. |
| Backup | `android:allowBackup="false"` |
| Network | `network_security_config`: cleartext disabled (prod/staging) |
| Adaptive icon | Foreground + background layers + **monochrome** layer (themed icons) |
| Splash | Android 12+ SplashScreen API (via `flutter_native_splash` or native config), calm and brief |

## 4. Store listing (draft)

**Title (24/30):** AfterMe: Safety Check-In

**Short description (71/80):**
> Check in daily. If you don't, the people you choose get what they need.

**Full description (draft):**
> **If you can't answer, your instructions can.**
>
> AfterMe helps you prepare the information the people around you might need if you're ever unexpectedly unreachable: in hospital, travelling without signal, or just with a lost phone.
>
> **How it works**
> • **Check in** with one tap on a schedule you choose, for example once a day by 8 PM.
> • **Miss a check-in?** We remind you first. Nobody else hears anything during your grace period.
> • **Still no answer?** AfterMe follows the plan you set: it notifies the trusted contacts you chose and, later, shares the specific information you prepared for each of them.
> • **Back and safe?** Tap I'M SAFE. Everyone who was told gets an all-clear.
>
> **You're in control**
> • Decide who gets what, and when: a different plan for your partner, your brother, or your employer.
> • Contacts must accept your invitation first. They don't need to install anything.
> • See exactly what will happen before it happens, and stop it any time.
>
> **Private by design**
> • Your instructions are encrypted in transit and at rest, and never appear in emails or notifications.
> • Contacts verify with a one-time code before they can see anything you shared with them.
> • No ads. We don't sell your data. Export or delete your data at any time.
>
> **Good to know**
> • AfterMe does not contact emergency services. In an emergency, call your local emergency number.
> • AfterMe can't know why a check-in was missed. It only follows your instructions.
> • Instructions in AfterMe are not a legal will.
>
> Free: 1 trusted contact, 3 instructions, a 2-stage plan. Premium: more contacts, more instructions and fully custom plans.

Copy rules: never "end-to-end encrypted", never "zero-knowledge", no death imagery ([SECURITY §6.4](SECURITY.md#64-honest-limitation-not-end-to-end-encrypted)).

## 5. Graphics

| Asset | Spec | Plan |
|---|---|---|
| App icon | 512 × 512, 32-bit PNG, ≤ 1 MB | Simple calm mark (e.g. a soft check inside a rounded shape), teal on warm white; also the adaptive/monochrome versions in-app |
| Feature graphic | 1024 × 500, JPG or 24-bit PNG (no alpha) | Tagline + phone silhouette showing I'M OK |
| Phone screenshots | 2–8; JPG or 24-bit PNG; each side 320–3840 px; aspect ratio ≤ 2:1 | 1) Home "You're checked in" 2) One-tap I'M OK 3) Plan timeline 4) Who gets what (instruction + recipient + stage) 5) Grace state "We'll remind you first" 6) Contact accepted 7) Privacy summary |
| Tablet screenshots | Optional | Skip unless tablets are supported well |

Screenshots are captured from the **staging/screenshot flavor** (FLAG_SECURE off) with fictional demo data. Never real user data.

## 6. App content declarations (Play Console → App content)

| Declaration | Answer (draft) |
|---|---|
| Privacy policy | URL above |
| **App access** | Login required → provide a **reviewer demo account** (pre-seeded staging-like data on prod: a verified contact that is our own test inbox, and sample instructions) plus written steps. Login is email + password only (codes are needed only at signup), so a pre-verified reviewer account works with **no bypass of any kind**. |
| Ads | No ads |
| Content rating (IARC) | Utility/lifestyle; no violence, sexual content, gambling or drugs. Answer the user-interaction questions truthfully: users **share information privately** with contacts they choose. |
| Target audience | **18+ only**. Not designed for children (keeps the app out of the Families program). |
| News app | No |
| Government app | No |
| Financial features | None |
| Health | No health features (answer the health-apps declaration accordingly) |
| Data safety | §7 |
| Account deletion | In-app path + web URL |

## 7. Data safety form (draft — final review with legal)

**Collected data:**

| Data type (Play category) | What | Required? | Purposes | Shared? * |
|---|---|---|---|---|
| Personal info → Name | User's display name; trusted contacts' names | Required | App functionality, Account management | Yes, the user's name is shown to their contacts |
| Personal info → Email address | User email; contacts' emails | Required | App functionality, Account management, Developer communications (security emails) | Yes, the user's email is shown to their contacts |
| Personal info → Phone number | User's and contacts' phone (optional) | Optional | App functionality | No |
| App activity → Other user-generated content | Instructions (title/body) | Optional | App functionality | Yes, released only to contacts the user chose |
| App activity → Other actions | Check-in events, incident history | Required | App functionality | No |
| App info & performance → Crash logs, Diagnostics | Scrubbed crash reports | Required (not user-optional) | Analytics (stability) | No |
| Device or other IDs | Push token / Firebase installation ID | Required | App functionality (notifications) | No |
| Financial info → Purchase history | Subscription status (if billing is enabled) | Optional | App functionality | No |

\* Play exempts some user-initiated transfers from "sharing". Releases to contacts are configured by the user but executed later automatically, so **declaring them as shared is the conservative choice.** Service providers (hosting, email delivery, FCM, crash reporting) acting on our behalf are processors, not "sharing".

**Security practices:** encrypted in transit ✓ · users can request deletion ✓ (in-app + web) · independent security review: only if completed (e.g. MASA) · no data sold.

**Not collected:** location, device contacts list, photos/files, audio, calendar, health/fitness, web history, installed apps, advertising ID.

## 8. Legal documents (needed before closed testing)

**Privacy policy** must cover: controller identity and contact; data inventory ([SECURITY §14.1](SECURITY.md#141-data-inventory)); purposes and legal bases; contacts' data (provided by users, invitation consent, opt-out); release mechanism; processors and countries; retention and backups (≤ 35 days); security measures (honest: not E2EE); user rights and how to exercise them; account deletion (in-app + web); children (18+); changes; regional sections (DPDP / GDPR / US states) as applicable.

**Terms of service** must cover: not an emergency service; no guarantee of delivery or timing (best effort, with the safeguards described); not a legal will or estate instrument; 18+; the user's responsibility for the accuracy and lawfulness of instructions and for having the right to share contacts' details; acceptable use (no harassment or spam); subscriptions via Google Play; termination; limitation of liability; governing law.

Both need **review by a lawyer** in the launch jurisdiction. This is a sensitive-information product.

## 9. Testing tracks

| Track | Use | Notes |
|---|---|---|
| Internal testing | Owner + small team; every build | Up to 100 testers; available within minutes |
| **Closed testing** | Beta; **satisfies the 12 × 14-day rule** | Testers opt in via a link with a Google account; keep ≥ 12 active (aim for 20+ for margin); collect feedback in a simple form |
| Open testing | Optional | Only if a public beta is wanted |
| Production | Staged rollout 10% → 25% → 50% → 100% | Halt on crash/ANR spikes or any S1 |

Tester recruitment ideas: friends/family (they double as trusted contacts for each other), colleagues, local community groups. Every tester must actually stay opted in for 14 days.

## 10. Pre-submission checklist (Phase 13)

- [ ] Application ID final; prod Firebase project configured
- [ ] Target SDK 36; 16 KB page-size check passed; release AAB signed with the upload key
- [ ] Merged manifest reviewed (permissions, exported components, no AD_ID)
- [ ] Pre-launch report (Play's automated device tests) reviewed: no crashes, accessibility warnings addressed
- [ ] Store listing, graphics and screenshots uploaded (en)
- [ ] Privacy policy, terms, deletion page live on the production domain
- [ ] Data safety, content rating, target audience (18+), ads, app access (reviewer account) completed
- [ ] Support email monitored; FAQ page live
- [ ] Backend production deployed; alerts tested; backup restore tested; Hold game day passed
- [ ] Closed test 12 × 14 complete (personal account) → apply for production
- [ ] Release notes written; staged rollout plan agreed

## 11. After launch

- Monitor Android vitals (crash rate, ANR rate) and the review inbox; respond to reviews within 48 h.
- **Every August:** a new target-API requirement. Plan an update before the deadline (an extension to 1 November is usually available on request).
- Watch Play policy updates (developer emails, Policy Center) and re-check the Data safety form whenever data handling changes.
