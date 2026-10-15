# AfterMe — Google Play submission

| | |
|---|---|
| **Status** | v1.0 — final answers for submission (Phase 13). The owner enters them in Play Console; every answer below was derived from the code as built, and says where. |
| **Verified against** | Google Play requirements as known on 2026-10-15. Play Console's wording and questions change: if a question differs from what is written here, answer it from §7.6 (what the code does), never from this text alone. |
| **Related** | [RELEASE](RELEASE.md) (release runbook, signing, rollout) · [PRD §10, §15](PRD.md) · [SECURITY §14](SECURITY.md#14-privacy) · [DATABASE §5](DATABASE.md#5-retention) · [BETA_PLAN](BETA_PLAN.md) · [legal/](legal/) |

Owner decisions this document applies: application ID `app.afterme`; domain `afterme.app`; Play title **AfterMe** (D11); **no Play Billing in 1.0** — Premium exists only when an operator grants it (D5), billing comes in 1.1; India first, then global (asia-south1, DPDP); personal developer account (12 testers × 14 days); **no crash-reporting SDK** (Play vitals only); beta accounts are kept at launch; the legal pages are served by the backend.

---

## 1. Critical path

| Item | Lead time | State |
|---|---|---|
| Domain + application ID (permanent after the first upload) | — | **Decided:** `afterme.app`, `app.afterme` |
| Play Console developer account (personal) + identity verification | Days to weeks | Owner |
| **Closed test: ≥ 12 opted-in testers for 14 continuous days** (personal accounts created after 13 Nov 2023). If active testers drop below 12, the count restarts | ≥ 14 days + recruiting | Owner ([BETA_PLAN](BETA_PLAN.md)) |
| Apply for production access (questions about the closed test) | Days | Owner ([RELEASE §2](RELEASE.md#2-applying-for-production-access)) |
| Review of each release | Hours to days | Every release |

## 2. App identity

| Field | Value |
|---|---|
| Application ID | `app.afterme` (the `prod` flavor; `app.afterme.staging` is never uploaded) |
| App name (Play title, ≤ 30) | **AfterMe** (7) |
| Default language | English (India), `en-IN`. Add `en-US` as a second listing language with the same text when going global |
| App or game / Category | App · **Lifestyle** |
| Free or paid | Free (no in-app purchases in 1.0) |
| Contact email | `support@afterme.app` (must be read: [RELEASE §5](RELEASE.md#5-the-first-48-hours)) |
| Website | `https://afterme.app` |
| Privacy policy | `https://afterme.app/legal/privacy` |
| Terms | `https://afterme.app/legal/terms` |
| Support page | `https://afterme.app/support` |
| Account deletion (web) | `https://afterme.app/a/delete` (and in the app: Settings → Privacy and data → Delete account) |

The legal pages are served by the backend (`app/web/legal_router.py`) from `docs/legal/*_DRAFT.md`. **Until `LEGAL_DOCUMENTS_FINAL=true` every legal page shows a "draft, not reviewed by counsel" banner.** A draft banner on the privacy policy is acceptable for internal testing but not for a production review: counsel's review, then the flag, then submission (and production refuses to start with the flag on while the operator's name, address and effective date are unset).

## 3. Technical requirements

| Requirement | AfterMe | State |
|---|---|---|
| Format | Android App Bundle, built only by `mobile/tool/build_release.sh` (CI: `.github/workflows/release.yml`) | Built |
| Target SDK | **36** (required for new apps and updates since 31 Aug 2026); `compileSdk 36` | Built (`mobile/README.md`) |
| Min SDK | 26 (Android 8.0) | Built |
| ABIs | arm64-v8a, armeabi-v7a, x86_64 (Flutter default); 64-bit present | Built |
| **16 KB memory page size** | Required for apps targeting Android 15+. The Flutter engine and the plugins' native libraries must be 16 KB-aligned | **Verify per release:** Play Console → App bundle explorer → the bundle's "Memory page size" / 16 KB compatibility, or `bundletool build-apks` + `zipalign -c -P 16 -v 4` on the arm64 split. A warning there blocks the release |
| Signing | **Play App Signing** (Google holds the app signing key); we hold the **upload key** ([RELEASE §3](RELEASE.md#3-the-signed-build)) | Pipeline built; key is an owner action |
| Obfuscation | `--obfuscate --split-debug-info`; R8 mapping and Dart symbols kept privately per version (workflow artifacts, 90 days, plus the release record) | Built |
| Permissions (merged manifest) | Exactly: `INTERNET`, `POST_NOTIFICATIONS`, `USE_BIOMETRIC`, `USE_FINGERPRINT` (maxSdkVersion 27 only), and what FCM adds: `WAKE_LOCK`, `ACCESS_NETWORK_STATE`, `com.google.android.c2dm.permission.RECEIVE`, plus AndroidX's signature-level `app.afterme.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`. `VIBRATE` is removed. **Refused by the checker:** AD_ID, READ_CONTACTS, RECEIVE_BOOT_COMPLETED, exact alarms, foreground services | Enforced on every build by `mobile/tool/check_manifest_permissions.dart` |
| Exported components | The launcher activity, the two FCM receivers (guarded by c2dm SEND), AndroidX's profile installer (guarded by DUMP) | Enforced by the same checker |
| Advertising ID | Not used; AD_ID is refused by the checker | Built |
| Backup | `allowBackup="false"`, data extraction rules exclude everything | Built |
| Network | HTTPS only (no cleartext in prod; checked) | Built |
| Contacts | System picker (`ACTION_PICK`): read access to the one chosen entry only, no READ_CONTACTS | Built |

## 4. Store listing

**Title (7/30):** AfterMe

**Short description (78/80):**
> Check in on your schedule. If you don't answer, the people you chose are told.

**Full description (about 1,800/4,000 characters):**
> **If you can't answer, your plan can.**
>
> AfterMe helps you prepare what the people close to you would need if you were ever unexpectedly unreachable: in hospital, travelling without signal, or simply without your phone.
>
> **How it works**
> • **Check in** with one tap on a schedule you choose, for example once a day by 8 PM.
> • **Miss a check-in?** We remind you first. Nobody else hears anything during your grace period.
> • **Still no answer?** AfterMe follows the plan you set: it emails the trusted contacts you chose and, later, lets them read the specific information you prepared for each of them.
> • **Back and safe?** Tap I'M SAFE. Everyone who was told gets an all-clear.
> • **Lost your phone?** Check in from any browser at afterme.app.
>
> **You're in control**
> • Decide who is told, what they can read, and when.
> • Contacts must accept your invitation first. They don't need to install anything.
> • See exactly what would happen, and when, before it ever happens. Stop it at any time.
>
> **Private by design**
> • Your instructions are encrypted in transit and at rest, and never appear in emails or notifications.
> • Contacts confirm a one-time code before they can read anything you shared with them.
> • If our systems have a problem, AfterMe pauses messages to contacts rather than risk a wrong one. Your reminders continue.
> • No ads. We don't sell your data. Export or delete your data at any time, in the app or on the web.
>
> **Free**
> AfterMe is free: 1 trusted contact, 3 instructions and a two-stage plan with suggested times. More contacts and plans are coming.
>
> **Good to know**
> • AfterMe does not contact emergency services. In an emergency, call your local emergency number.
> • AfterMe can't know why a check-in was missed. It only follows your plan.
> • Contacts are reached by email.
> • Instructions in AfterMe are not a legal will.
> • For adults (18+).

**Copy rules** (USER_FLOWS §15, SECURITY §6.4): never "end-to-end encrypted", never "zero-knowledge", never "guaranteed"; no death imagery or wording; no Premium, price, subscription or purchase claims in 1.0 ("more contacts and plans are coming" is the most that may be said). Every sentence above is true of the build: the reminder-first grace period and stages (ESCALATION_ENGINE), the web check-in (`/a/checkin`), the one-time code on the contact portal, the Hold that pauses contact-facing messages, export and in-app/web deletion, the free limits (`app/users/entitlements.py`: 1 contact, 3 instructions, 2 stages, preset offsets).

**Release notes ("What's new"):** `mobile/store/whatsnew/` (produced with the store assets; [RELEASE §4](RELEASE.md#4-versioning-tags-and-release-notes)).

## 5. Graphics

Produced in `mobile/store/` (by the mobile work package; this document only references them):

| Asset | Play spec | File |
|---|---|---|
| App icon | 512 × 512, 32-bit PNG, ≤ 1 MB | `mobile/store/play_icon_512.png` |
| Feature graphic | 1024 × 500, JPG or 24-bit PNG, no alpha | `mobile/store/feature_graphic_1024x500.png` |
| Phone screenshots | 2–8, each side 320–3840 px, aspect ≤ 2:1 | `mobile/store/screenshots/` (fictional demo data only; captured from a staging build with `SCREENSHOT_MODE`, which the release build refuses) |
| Tablet screenshots | Optional | Not provided (phone-first) |
| Release notes | ≤ 500 characters per language | `mobile/store/whatsnew/` |

`mobile/store/previews/` holds the launcher and splash previews for review; they are not uploaded.

## 6. App content (Play Console → Policy → App content)

| Declaration | Answer |
|---|---|
| Privacy policy | `https://afterme.app/legal/privacy` |
| **App access** | **All or some functionality is restricted** → instructions and credentials in §6.1 |
| Ads | **No**, the app does not contain ads |
| Content rating | IARC questionnaire, §6.2 |
| Target audience | **18 and over only**, §6.3 |
| News app | **No** |
| Government app | **No** |
| Financial features | **"My app doesn't provide any financial features"** |
| Health apps | **"My app does not have any health features"** (AfterMe is a personal check-in and information-sharing app: no medical, fitness, symptom, medication or health-record features; it does not contact emergency services) |
| Data safety | §7 |
| Advertising ID | **No**, the app does not use an advertising ID (AD_ID is refused by the manifest checker) |
| Sensitive permissions and APIs | **None to declare**, §6.4 |
| Account deletion | In-app path + `https://afterme.app/a/delete` |

### 6.1 App access: the reviewer account

Login is email + password only (a code is needed only at sign-up), so a pre-verified account works with **no bypass of any kind**. The account is made by the operator command, run as the API role with the KMS (it seals two sample instructions):

```bash
# a terminal (generated password printed once): run where the API identity is
python -m cli.admin reviewer-account create --email play-review@afterme.app \
  --contact-email review-inbox@afterme.app --reason "Play review 1.0.0"
# before every submission (new password, every session ended, the seeded state back)
python -m cli.admin reviewer-account reset <user_id>
# production: the Cloud Run job afterme-reviewer-account (password from the secret
# reviewer-password, never printed): see RELEASE §1.3
```

What it makes: a verified account "Play Reviewer" (Asia/Kolkata), **Premium** so that every screen is reachable (Premium is operator-granted in 1.0); **one verified contact "Review Team" whose address is our own review inbox** (a public mail domain is refused unless `--allow-public-contact`, a suppressed address or a contact that opted out is never overridden); a two-stage plan (3 h grace → the contact is told; 24 h → the two instructions are shared); two **fictional** sample instructions; an **active daily schedule at 20:00 India time**. It is audited as `operator.reviewer_account` (never shown to the account, no password or address in it). The account is an ordinary one: the engine treats it like any other.

**What is not provided, and why:** an account already in an alert. Only the engine opens incidents (INV-1) and only from a deadline the database clock computed from a real schedule (INV-3); writing a deadline into the past would fabricate a missed check-in. A reviewer cannot wait 24 hours, so the instructions say so and point at the plan preview.

**Text to paste into Play Console → App access** (with the email and password in the credential fields):

> AfterMe is a personal check-in app. Sign in with the email and password above (no code is needed). The account is a demo account with fictional data; its only trusted contact is our own review mailbox.
>
> 1. **Home** shows the next check-in. Tap **I'M OK** to check in.
> 2. **Plan** shows what would happen if a check-in were missed: a reminder first, then after a 3-hour grace period the contact is emailed, and after 24 hours the contact can read the instructions chosen for them. The timeline preview shows this without waiting.
> 3. **People** shows the trusted contact "Review Team" (already accepted).
> 4. **Instructions**: opening them asks for the password again (a deliberate privacy step). Both instructions are fictional samples.
> 5. **Settings → Privacy and data**: export, and account deletion (please do not delete this account).
>
> Alerts cannot be triggered on demand: by design, no button or app action can cause an alert; only a missed check-in can. The schedule is daily at 20:00 India time (14:30 UTC). If nobody has checked in on this demo account, Home may show that a check-in was missed or that the contact was notified; tap **I'M SAFE** (it asks for the password) to end it. Everything goes only to our own review mailbox.
>
> The same account can check in from a browser at https://afterme.app/a/checkin. Notifications are optional; reminders are sent only if you allow them.

### 6.2 Content rating (IARC questionnaire)

| Question | Answer |
|---|---|
| Email for the rating | `support@afterme.app` |
| Category | **"Utility, Productivity, Communication, or Other"** (not a game, not social media, not news) |
| Violence, blood, gore | No |
| Fear / horror / disturbing content | No (no death imagery or wording anywhere; the copy rules forbid it) |
| Sexual content, nudity | No |
| Profanity / crude humour | No |
| Drugs, alcohol, tobacco | No |
| Gambling (real or simulated) | No |
| Discriminatory content | No |
| **Does the app allow users to interact or exchange content?** | **Yes**: a user writes instructions that are delivered, privately and one way, to people the user chose and who accepted an invitation (email + a web page behind a one-time code). There is no public content, no chat, no browsing of other users, and contacts cannot reply in the app |
| **Does the app share users' personal information with third parties?** | **Yes**: the user's name and email are in the alert to the user's chosen contacts, and the instructions are released to them (consistent with §7) |
| Does the app share the user's current physical location? | No (no location is collected) |
| Digital purchases | No (no in-app purchases in 1.0) |
| Unrestricted internet access / web browser | No (the app only opens our own legal and support pages in the browser) |
| Is the app primarily a news or educational product? | No |

Expected outcome: the lowest age rating in every region (e.g. PEGI 3 / ESRB Everyone / IARC 3+) with the interactive elements **"Users Interact"** and **"Shares Info"**. The age rating describes the content; the audience is set separately to 18+ (§6.3). Re-answer the questionnaire if billing (Digital Purchases) or any new sharing is added.

### 6.3 Target audience and content

- Target age groups: **18 and over** only. Not designed for children; no element appeals to children (the listing graphics and copy are plain and adult). This keeps the app out of the Families programme.
- "Could your store listing unintentionally appeal to children?": **No**.
- Terms and the sign-up consent state 18+ (`docs/legal/TERMS_DRAFT.md`; BETA_PLAN §5).

### 6.4 Sensitive permissions and APIs

Nothing requires a declaration form, verified from the merged-manifest allowlist (`mobile/tool/check_manifest_permissions.dart`, run by every release build):

| Play policy area | AfterMe |
|---|---|
| SMS / Call log | Not requested |
| Location (foreground or background) | Not requested |
| All files access, photos and videos | Not requested |
| `QUERY_ALL_PACKAGES` | Not requested (the `<queries>` element names only text processing and `https` VIEW intents) |
| Exact alarms (`SCHEDULE_EXACT_ALARM`, `USE_EXACT_ALARM`) | Not requested: reminders come from the server |
| Foreground services (and their type declarations) | None |
| Full-screen intent (`USE_FULL_SCREEN_INTENT`) | Not requested |
| Accessibility service, VPN service, device admin | None |
| Health Connect / body sensors | None |
| `POST_NOTIFICATIONS` | Runtime permission, asked after an explanation; needs no declaration |
| `USE_BIOMETRIC` / `USE_FINGERPRINT` (≤ API 27) | Normal permissions for the app lock; no declaration |
| Contacts | No READ_CONTACTS; the system picker grants one chosen entry |

## 7. Data safety form

### 7.1 Overview questions

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **Yes** |
| Is all of the user data collected by your app encrypted in transit? | **Yes** (HTTPS only: app `AppConfig` + network security config; every web page and email link is `https`) |
| Which of the following methods of account creation does your app support? | **Username and password** (email + password; an emailed code verifies the address once) |
| Delete account URL | `https://afterme.app/a/delete` (works without the app: emailed link + password) |
| Do you provide a way for users to request that some or all of their data is deleted, without deleting their account? | **Yes**: contacts, instructions and the plan can be deleted in the app at any time |
| Has your app undergone an independent security review (MASA)? | **No** (do not claim it) |
| Is your app designed for children / committed to the Families policy? | No (18+) |

### 7.2 Data types (final answers)

"Ephemeral" is **No** for every type collected (everything collected is stored). Purposes use Play's list: App functionality, Analytics, Developer communications, Advertising or marketing, Fraud prevention / security / compliance, Personalisation, Account management.

| Play category → data type | Collected | Shared | Required / optional | Purposes | What, exactly |
|---|---|---|---|---|---|
| **Personal info → Name** | Yes | **Yes** | Required | App functionality; Account management | The user's display name. Shared: it is in the alert emails to the contacts the user chose |
| **Personal info → Email address** | Yes | **Yes** | Required | App functionality; Account management; Developer communications; Fraud prevention, security, and compliance | Login address; security and account emails (codes, new-device sign-in, lock-out, deletion). Shared: shown in the alert to the user's contacts so they recognise the sender |
| **Personal info → Phone number** | Yes | No | Optional | App functionality | Optional profile phone (stored; nothing sends SMS in 1.0) |
| **Personal info → Other info** | Yes | No | Required | App functionality | Country, time zone and language (the schedule runs in the user's time zone) |
| Personal info → Address, User IDs, race, political or religious beliefs, sexual orientation | No | — | — | — | (The account's internal id is generated by us, not provided by the user) |
| **Contacts** | Yes | No | Required | App functionality | The trusted contacts the user adds: name, email, relationship label, optional phone. Typed in, or one entry chosen in the system contact picker (no access to the address book otherwise). At least one is needed to switch check-ins on |
| **App activity → Other user-generated content** | Yes | **Yes** | Optional | App functionality | Instructions (title, text, category) and who receives each at which stage. Shared: released to the chosen contacts by the user's plan |
| **App activity → Other actions** | Yes | No | Required | App functionality; Fraud prevention, security, and compliance | Check-ins (time, app or web), schedule and plan changes, incident history, and the account's security records (sign-ins, password and email changes, when instructions were opened) |
| App activity → App interactions, In-app search history, Installed apps, Web browsing history | No | — | — | — | |
| **App info and performance → Other app performance data** | Yes | No | Required | App functionality; Fraud prevention, security, and compliance | The app version, OS version, platform and language of each signed-in device (the `426` upgrade gate and the session list use them) |
| App info and performance → Crash logs | **No** | — | — | — | No crash-reporting SDK in 1.0 (owner decision). Android vitals are Google's own data. **Add this row (and the processor) if a crash reporter is ever integrated** |
| App info and performance → Diagnostics | **No** | — | — | — | Nothing measured on the device is sent. The server keeps its own request logs (route, status, latency, request id, account id; never a body or query string): operational logs, retained by Cloud Logging's default (30 days) |
| **Device or other IDs** | Yes | No | Required | App functionality; Fraud prevention, security, and compliance | The device id we generate at sign-in, the FCM registration token (only after notifications are allowed), and the Firebase installation ID that the FCM SDK keeps |
| Location (approximate or precise) | **No** | — | — | — | IP addresses are processed in transit and stored only as a keyed one-way hash for rate limiting and security; no location is derived |
| Financial info | **No** | — | — | — | No billing in 1.0. **Add "Purchase history" when Play Billing ships (1.1)** |
| Health and fitness, Messages, Photos and videos, Audio, Files and docs, Calendar | **No** | — | — | — | |

### 7.3 Why "shared", and what is not sharing

Play exempts transfers that the user initiates and expects, and transfers to service providers. Releases and alerts are configured by the user but **sent later, automatically**, so declaring the user's name, email and instructions as **shared** (with the contacts the user chose) is the conservative and honest answer. Google Cloud (hosting, KMS), the email providers (Resend, Postmark fallback) and Firebase Cloud Messaging process data **on our behalf**: they are service providers, not "sharing". No data is sold or used for advertising.

### 7.4 Retention and deletion (consistent with the privacy policy)

| Data | Kept | Source |
|---|---|---|
| Account, profile, contacts, instructions, plan | Until the user deletes them or the account | DATABASE §5 |
| Check-in events | 400 days | DATABASE §5 |
| Incidents, actions, releases | Life of the account | DATABASE §5 |
| Notifications and delivery logs | 90 days | DATABASE §5 |
| Audit records (pseudonymous: account id, hashed IP; no name or email) | `AUDIT_RETENTION_DAYS` (365 by default), also after the account is deleted | DATABASE §5 |
| Sessions (hashed IP, user agent), tokens | 30 days after expiry or revocation | DATABASE §5 |
| Devices | 90 days after last seen | DATABASE §5 |
| Address hashes of opted-out, bounced or complaining addresses | As long as the opt-out must be honoured | DATABASE §5 |
| **Account deletion** | Access ends at once; the instruction key is destroyed at once (content unreadable everywhere, backups included); the rows are erased 30 days later | `app/users/deletion.py` |
| Backups | Up to 35 days | DEPLOYMENT §6 |

### 7.5 Not collected

Location, the phone's address book (beyond the one entry the user picks), photos, files, audio, calendar, health or fitness data, messages, web history, installed apps, advertising ID, payment data.

### 7.6 Traceability (where each answer comes from)

| Answer | Code |
|---|---|
| Name, email, password hash, verified flag, tier | `users`, `user_profiles` (`app/auth/models.py`, `app/users/models.py`) |
| Phone, country, time zone, language | `user_profiles` |
| Contacts | `trusted_contacts`, `contact_verifications` (accept/decline time, hashed IP, consent text version); picker: `mobile/lib/core/platform/contact_picker.dart` |
| Instructions | `instructions` (AES-GCM under a per-user key wrapped by Cloud KMS), `instruction_recipients` |
| Other actions | `checkin_events`, `checkin_configurations`, `escalation_*`, `incident_actions`, `release_events`, `portal_*`, `audit_logs` |
| Device data and IDs | `devices` (platform, app/OS version, locale, push token); `sessions` (ip_hash, user_agent); Firebase installation ID inside the FCM SDK |
| Delivery records | `notifications`, `notification_logs`, `email_receipts`, `email_suppressions` (hash only) |
| No crash/analytics SDK, no AD_ID | `mobile/pubspec.yaml` dependencies; the manifest checker |

## 8. Legal documents

Served at `/legal/privacy`, `/legal/terms` and `/support` from `docs/legal/*_DRAFT.md`, with the draft banner until `LEGAL_DOCUMENTS_FINAL=true`. Before submission counsel must also align the drafts with 1.0 as built: **no purchases** (the privacy draft's "Purchase status" row and the terms' "subscriptions via Google Play" clause describe 1.1), **no crash reports** (privacy draft §11 point 3 is now resolved: none collected), the processors by name and country (Google Cloud asia-south1, Resend, Postmark, FCM), and the server request logs (privacy draft §11 point 10). The Data safety answers above and the privacy policy must say the same thing.

## 9. Testing tracks

| Track | Use | Notes |
|---|---|---|
| Internal testing | Owner; every build | Up to 100 testers, available within minutes. Upload by hand ([RELEASE §3](RELEASE.md#3-the-signed-build)) |
| **Closed testing** | The beta; **the 12 × 14 rule** | The `prod` flavor against the production backend ([BETA_PLAN §1](BETA_PLAN.md#1-the-sequencing-problem-you-need-to-decide-first)). Keep ≥ 12 opted in (aim 20+) |
| Open testing | Not used | |
| Production | Staged rollout 10% → 25% → 50% → 100% with halt criteria | [RELEASE §3.6](RELEASE.md#36-production-staged-rollout) |

## 10. Pre-submission checklist

**Built (in the repository, verified by its gates):**

- [x] Application ID `app.afterme`; title "AfterMe"; target SDK 36, min 26.
- [x] Release build only through `mobile/tool/build_release.sh` (prod config, https API, obfuscation, no screenshot mode, upload key required) and the signed-release workflow `.github/workflows/release.yml` (upload key from GitHub secrets, debug-key and fingerprint check, AAB + mapping + symbols kept privately for 90 days).
- [x] Merged manifest enforced on every build: permission allowlist, no AD_ID, exported components, allowBackup off, no cleartext, no deep links.
- [x] Legal pages, support page, deletion page served by the backend (`/legal/privacy`, `/legal/terms`, `/support`, `/a/delete`).
- [x] Reviewer account tooling (`reviewer-account create | reset`) and its Cloud Run job (`afterme-reviewer-account`, off until enabled).
- [x] Listing text, Data safety, content rating, target audience, sensitive-permission answers (this document).
- [x] Store graphics in `mobile/store/` (icon, feature graphic; screenshots and release notes from the mobile work package).

**Owner actions (in order):**

- [ ] Real values in `mobile/config/prod.json` (API and public URLs, the production Firebase client config); the release workflow refuses placeholders.
- [ ] Upload key created and stored (password manager + offline copy), GitHub Environment `release` with its four secrets ([RELEASE §3.1](RELEASE.md#31-the-upload-key-once)).
- [ ] Counsel's review of the legal drafts (aligned as in §8), then `LEGAL_DOCUMENTS_FINAL=true` with the operator's facts set.
- [ ] Support inbox `support@afterme.app` and the review inbox monitored.
- [ ] Production backend deployed, alerts tested, backup restore tested, Hold game day passed (Phase 12 owner actions).
- [ ] Play Console: create the app (`app.afterme`), enter §2, §4, §5, §6, §7 exactly; reviewer account created on production and its credentials entered.
- [ ] First AAB uploaded by hand to internal testing; **16 KB check** and the pre-launch report reviewed (no crashes; accessibility warnings addressed).
- [ ] Closed test 12 × 14 completed; production access applied for ([RELEASE §2](RELEASE.md#2-applying-for-production-access)).
- [ ] Release notes written; staged rollout plan and halt criteria agreed ([RELEASE §3.6](RELEASE.md#36-production-staged-rollout)).

## 11. After launch

The first 48 hours, the yearly target-API deadline, policy monitoring and the rollback limits are in [RELEASE §5–§7](RELEASE.md#5-the-first-48-hours). Re-check this form whenever data handling changes (billing in 1.1, a crash reporter, SMS).
