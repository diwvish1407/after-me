# AfterMe — Android app (Flutter)

*If you can't answer, your instructions can.*

Phase 1 **foundation** ([ROADMAP Phase 1](../docs/ROADMAP.md)): flavors, configuration, API
client, session storage, routing, theme, design system, l10n and tests. Phase 2 adds the
**authentication and onboarding experience** ([ROADMAP Phase 2](../docs/ROADMAP.md)): sign-up with
an emailed code, sign-in, forgotten password, re-authentication, the Settings screens (profile,
security, sessions, notifications), the full onboarding flow, the app lock and the notification
pre-prompt. Phase 3 adds **trusted contacts** ([ROADMAP Phase 3](../docs/ROADMAP.md)): the People
tab, adding, editing, removing and inviting contacts against the real contacts API, the status
chips, the free-plan limit sheet and onboarding step 4 on the real API (see
[Trusted contacts](#trusted-contacts-phase-3)). Phase 4 adds the **check-in system**
([ROADMAP Phase 4](../docs/ROADMAP.md)): the schedule, the I'M OK tap with its pending state, the
real Home, and Settings > Check-in schedule and history, all against the real API (see
[Check-ins](#check-ins-phase-4)). Phase 5 makes the **plan** real: it is read and saved through
the plan API (onboarding step 6 saves the Standard preset, the Plan tab shows it read-only; see
[The plan](#the-plan-phase-5)). Instructions only have their **screens** so far; their data comes
from a clearly marked in-memory stand-in until Phase 6 (see
[Temporary repositories](#temporary-repositories-phase-2)). The backend is authoritative; the app
never decides whether an escalation happens ([ARCHITECTURE §1](../docs/ARCHITECTURE.md)) and never
computes a deadline.

## Application ID — PROVISIONAL

| | |
|---|---|
| Application ID / Kotlin namespace | **`app.afterme`** (dev: `app.afterme.dev`, staging: `app.afterme.staging`) |
| Status | **Provisional until product decision D1** (domain / application ID, [PRD §15](../docs/PRD.md)) |

The application ID **cannot change after the first Play upload**. When D1 is decided, change
`namespace` and `applicationId` in `android/app/build.gradle.kts` and move
`android/app/src/main/kotlin/app/afterme/MainActivity.kt` to the new package before any upload.

## Toolchain

| Tool | Version |
|---|---|
| Flutter | **3.47.6 stable** (Dart 3.13.5) — pinned in CI |
| JDK | 17 (Temurin in CI; Homebrew `openjdk@17` locally) |
| Android SDK | platform 36, build-tools 36.1.0; NDK 28.2 is installed by Gradle on first build |
| Emulator | AVD `AfterMe_API_36` (android-36, google_apis, arm64-v8a) |

Shell setup used on the development Mac:

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH=$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:/opt/homebrew/bin:$PATH
```

## First-time setup

```bash
cd mobile
flutter pub get                 # also runs gen-l10n (pubspec: generate: true)
dart run build_runner build     # freezed + json_serializable (*.freezed.dart, *.g.dart)
```

### Generated code (not committed)

`*.g.dart`, `*.freezed.dart` and `lib/l10n/gen/` are **generated, gitignored and never
edited by hand**. CI regenerates them before formatting, analysis and tests, so they can never
drift from their sources, and reviews only show real changes. After pulling changes to a model
or to `lib/l10n/app_en.arb`, run the two commands above again (`flutter run`/`flutter build`
regenerate l10n automatically; build_runner must be run explicitly).

`build_runner` 2.16+ always replaces stale or conflicting outputs; its old
`--delete-conflicting-outputs` flag is accepted but ignored (with a warning).

## Flavors and configuration

| Flavor | Application ID | Label | Config file | API base URL |
|---|---|---|---|---|
| `dev` | `app.afterme.dev` | AfterMe Dev | `config/dev.json` | `http://10.0.2.2:8000` (local backend via the emulator) |
| `staging` | `app.afterme.staging` | AfterMe Staging | `config/staging.json` | `https://api.staging.afterme.invalid` (placeholder) |
| `prod` | `app.afterme` | AfterMe | `config/prod.json` | `https://api.afterme.invalid` (placeholder) |

The staging/prod URLs use the reserved `.invalid` TLD until the domain is decided (D1), so a
build can never talk to a real server by accident. Every build passes **both** a flavor and its
config file:

```bash
--flavor <env> --dart-define-from-file=config/<env>.json
```

Config keys: `APP_ENV` (`dev`/`staging`/`prod`), `API_BASE_URL`, `PUBLIC_BASE_URL` (the origin of
the public web pages: `/legal/terms`, `/legal/privacy`; https is required outside dev, and in dev it
defaults to the API origin), `SENTRY_DSN` (empty for now).
These are **not secrets** — the app contains none ([ARCHITECTURE §5.9](../docs/ARCHITECTURE.md)).
`AppConfig.fromEnvironment()` validates them at start-up and the app **refuses to start** on an
invalid configuration: missing values, a non-http(s) URL, or plain `http`/a local address in
staging or prod.

## Run

```bash
emulator -avd AfterMe_API_36 &          # or start it from Android Studio
flutter run --flavor dev --dart-define-from-file=config/dev.json
```

### Reaching the local backend

The backend's dev server listens on `http://127.0.0.1:8000` on your Mac
([DEPLOYMENT §2.2](../docs/DEPLOYMENT.md)).

* **Android emulator:** `10.0.2.2` is the emulator's alias for the host's loopback, so
  `config/dev.json` (`http://10.0.2.2:8000`) works as is.
* **Physical device over USB:** run `adb reverse tcp:8000 tcp:8000` and use a local copy of the
  config with `"API_BASE_URL": "http://127.0.0.1:8000"` (e.g. `config/dev.local.json`; do not
  commit it).

Cleartext HTTP is allowed **only in the dev flavor and only for** `10.0.2.2`, `localhost` and
`127.0.0.1` (`android/app/src/dev/res/xml/network_security_config.xml`). Staging and prod are
HTTPS-only (`src/main/res/xml/network_security_config.xml`).

## Quality gates

Run from `mobile/` (CI runs the same steps: [`.github/workflows/mobile.yml`](../.github/workflows/mobile.yml)):

```bash
dart run build_runner build
flutter gen-l10n
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze                                  # must report zero issues
flutter test --coverage
dart run tool/coverage_check.dart                # >= 70% overall, >= 90% interceptors, session and every Phase 2-4 feature area (contacts, check-ins, home and time formatting included)
flutter build apk --flavor dev --debug --dart-define-from-file=config/dev.json
flutter build apk --flavor prod --release --dart-define-from-file=config/prod.json
dart run tool/check_manifest_permissions.dart    # merged prod manifest: INTERNET, POST_NOTIFICATIONS, USE_BIOMETRIC (+ AndroidX's own signature permission); no AD_ID, no READ_CONTACTS
```

CI ([`mobile.yml`](../.github/workflows/mobile.yml)) runs every command above, plus a staging debug build
(flavor compile check). Coverage excludes generated files. Tests are deterministic and never use the network: the API
client is tested end to end over a fake `HttpClientAdapter` (`test/helpers/fake_http_adapter.dart`).

## Build

```bash
# Development APK
flutter build apk --flavor dev --debug --dart-define-from-file=config/dev.json

# Local release APK (signed with the debug key unless android/key.properties exists)
flutter build apk --flavor prod --release --dart-define-from-file=config/prod.json

# Play upload (Phase 10+): App Bundle, obfuscated, symbols kept privately (DEPLOYMENT §5.1)
flutter build appbundle --flavor prod --release --obfuscate --split-debug-info=build/symbols \
  --dart-define-from-file=config/prod.json
```

### Release signing

Release builds use the **upload key** described by `android/key.properties` when that file
exists. It is gitignored and must never be committed:

```properties
# storeFile is relative to android/. Keep comments on their own line:
# .properties files do not support trailing comments.
storeFile=upload-keystore.jks
storePassword=…
keyAlias=upload
keyPassword=…
```

Without `key.properties` the release build falls back to the **debug** signing config and Gradle
prints a warning. That keeps local `--release` builds working; such an APK can never be uploaded
to Play. Play App Signing holds the app signing key ([PLAY_STORE §3](../docs/PLAY_STORE.md)).

## Android hardening (Phase 1)

* `minSdk 26`, `targetSdk 36`, `compileSdk 36` ([PLAY_STORE §3](../docs/PLAY_STORE.md)).
* **Permissions:** `INTERNET`, `POST_NOTIFICATIONS` (check-in reminders, Android 13+, asked only
  after an explanation) and `USE_BIOMETRIC` (app lock), declared in the main manifest. The merged
  prod release manifest is checked in CI: besides those it may contain only
  `app.afterme.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`, a signature-level permission that
  AndroidX Core defines for the app itself (targetSdk ≥ 33), and the legacy `USE_FINGERPRINT`
  **limited to `maxSdkVersion="27"`**: `androidx.biometric` 1.1.0 (via `local_auth`) declares it
  without a limit, Android 8.0-8.1 (our minSdk 26) still needs it for the fingerprint prompt, and
  the manifest drops it from Android 9+ (`tools:node="replace"`). **No `AD_ID`, no `READ_CONTACTS`**
  (contacts come from the system picker, which grants access to the one chosen contact). This is
  enforced by `tool/check_manifest_permissions.dart`, an allowlist check (anything else fails the
  build) with unit tests in `test/tool/`.
* **No deep links:** the manifest has one intent filter (the launcher). Nothing outside the app
  can open a route (`test/app/router_phase2_test.dart` checks this).
* `android:allowBackup="false"`, `android:fullBackupContent="false"`, and
  `android:dataExtractionRules` excluding everything from cloud backup **and** device-to-device
  transfer: tokens are bound to this device's Keystore ([ARCHITECTURE §5.4](../docs/ARCHITECTURE.md)).
* Network security config: cleartext disabled (dev flavor exception above), system CAs only.

## Code layout

```
lib/
  main.dart                    bootstrap: config (fail fast), package info, ProviderScope
  app/                         AfterMeApp (+ the app-lock gate), router + redirect rules, theme/,
                               repository_providers.dart (where the temporary repositories live)
  core/
    config/                    AppConfig, AppEnv
    storage/                   SecureStore (Keystore-backed + in-memory), PreferencesStore
    auth/                      SessionStore, AuthController (unknown/signedOut/signedIn)
    api/                       Dio factory, interceptors/, models/ (freezed), failures/
    design_system/             AppButton, CheckInButton, StatusBanner, SectionCard, EmptyState,
                               AppTextField, LoadingView, ErrorView, FormPage, FitText
    security/                  app_lock/ (controller, lock screen, gate, local_auth gateway),
                               screen_privacy.dart (recents thumbnail)
    permissions/               notification permission + pre-prompt controller
    forms/                     validators, password-strength hint, digits-only formatter
    pickers/                   timezone and country pickers, country names
    device/ links/ platform/   device facts, URL opener, system contact picker
    time/                      clock, time formatting, profile-timezone conversion (tz database)
  features/
    auth/                      data/ (AuthRepository + Dio implementation, freezed models),
                               application/ (sign-up, sign-in, forgot password, /me, sessions),
                               presentation/ (create account, code, sign in, forgot, ReauthSheet)
    onboarding/                welcome, steps 4-9 (contact, schedule, plan, instruction, protect,
                               done), OnboardingController (saved progress), SetupController
    contacts/                  data/ (ContactsRepository + Dio implementation, freezed models),
                               application/ (ContactsController, entitlements, readiness rules),
                               presentation/ (People, Add, Edit, Detail, status chip, limit sheet,
                               the shared ContactForm)
    checkin/                   data/ (ScheduleRepository + CheckInRepository with Dio implementations,
                               freezed models), application/ (ScheduleController, CheckInController
                               state machine, the persisted pending check-in, history), presentation/
                               (Settings > Check-in schedule and history, shared labels)
    plan/                      data/ (PlanRepository + Dio implementation, freezed models, the
                               Standard preset), application/ (PlanController), presentation/
                               (Plan tab, plan preview, plan wording)
    instructions/              data/ = repository interface + TEMPORARY in-memory fake
    settings/                  settings list, profile, security, change password/email, sessions,
                               app lock, notifications, about
    home/                      data/ (HomeRepository + Dio implementation, models), application/
                               (HomeController with the server clock offset, the pure state mapping,
                               phone-side readiness checks), presentation/ (Home)
    shell/ dev/                5-tab shell, design gallery (dev only)
  l10n/app_en.arb              every user-visible string (generated code in l10n/gen/)
test/                          unit + widget tests (helpers/ has the fakes and the fake network)
  contracts/                   parses docs/contracts/phase2 to phase5 *.json (the backend's
                               golden files, with the If-Match / Idempotency-Key / ETag headers of
                               the index); test/fixtures/ holds stand-ins used until a golden file exists
  accessibility/               every Phase 2 screen at 2.0 text scale and against the guidelines
tool/                          coverage_check.dart, check_manifest_permissions.dart,
                               emulator_smoke.sh, emulator_walkthrough.sh
```

Material widgets come from **`package:material_ui`**, the official home of Material since
Flutter 3.47 moved it out of the SDK (go_router 18 is built on it, and `dart fix
--code=migrate_design_widgets` performs the same migration). Use
`import 'package:material_ui/material_ui.dart';`, not `package:flutter/material.dart`.

### API client ([ARCHITECTURE §5.3](../docs/ARCHITECTURE.md))

Interceptors, in order: **ClientInfo** (`X-AfterMe-Client: android/<semver>+<build>`; the
flavor suffix such as `-dev` is stripped so the backend's version check can parse it) →
**Idempotency** (one `Idempotency-Key` per request, reused on every retry; callers can pass
their own key per user intent) → **Auth** → **Retry**.

* Mark requests with `apiOptions(idempotent: true)` or `apiOptions(authenticated: false)`.
* **Auth:** the access token lives in memory only; refresh token, session ID and device ID live
  in secure storage. A `401 token_expired` triggers a **single-flight** `POST /v1/auth/refresh`
  (on a separate Dio without the auth interceptor); the rotated refresh token is persisted
  **before** the original request is retried, at most once. After a cold start the first
  request obtains an access token the same way. A rejected refresh (400/401/403/422), a missing
  refresh token, or `401 session_revoked`/`unauthenticated` signs the user out.
  **A refresh that fails for transient reasons (offline, timeout, 5xx, 429) keeps the session**:
  signing someone out because of a network blip would stop them checking in.
* **Retry:** only GET/HEAD or requests with an `Idempotency-Key`; only network errors and 503;
  at most 3 attempts; exponential backoff with jitter; a `Retry-After` beyond the cap stops
  retrying.
* Errors become a sealed `AppFailure` through one function, `mapDioException`, and are shown
  with the calm copy in `failureMessage` (never the server's `detail`).

### Routing

`AuthStatus.unknown` → `/splash`. `signedOut`: public routes (`/welcome`, `/create-account`,
`/verify-code`, `/sign-in`, and `/dev/gallery` in dev) plus `/forgot-password`; anything else goes
to `/welcome`. `signedIn`: the splash until the saved onboarding progress is read; then, while
onboarding is unfinished, only the onboarding steps (anything else resumes at the saved step);
afterwards the five tabs, the Settings screens and the onboarding steps (re-opened from the Home
checklist). The rules are one pure function, `authRedirect`, tested for every state. Routes are
fixed paths: the app declares no deep links, query strings and fragments never select a screen,
and only a `String` is accepted as `extra` (the forgot-password prefill).

The **app lock is not a route**. `AppLockGate` sits above the Navigator in
`MaterialApp.builder`, so the lock screen also covers bottom sheets and dialogs; the app below
stays alive but is not painted, cannot be tapped and is hidden from TalkBack.

**Session loss.** A `401 session_revoked` (or a rejected refresh) makes the API client call
`AuthController.signOut`, which clears the tokens and moves to `signedOut`; every user-scoped
provider (account, sessions, the temporary repositories) watches the status and is rebuilt empty,
the router sends the person to `/welcome` from wherever they were, and open dialogs and sheets go
with the old screens. Onboarding progress is kept (it is keyed by account id and holds no
personal data), so the same account resumes after signing in again.

### Theme and accessibility

Tokens are exactly [USER_FLOWS §1.2](../docs/USER_FLOWS.md) (plus documented derived tokens);
light and dark `ColorScheme`s are built explicitly from them. `test/app/theme/contrast_test.dart`
enforces WCAG AA ratios. Widget tests run `androidTapTargetGuideline`,
`labeledTapTargetGuideline` and `textContrastGuideline`, and render key screens at 2.0 text
scale. The platform default font is used for now; **bundling an OFL font is a Phase 2 item**.

## Accounts and onboarding (Phase 2)

Flows follow [USER_FLOWS §3, §7, §11](../docs/USER_FLOWS.md). Every string is in the ARB, copy
follows the wording rules in §15, targets are 48 dp, and every screen is tested at 200% text.

* **Sign-up:** Welcome (3 cards, skippable) → Create account (name, email, password with a calm
  strength hint, timezone auto-detected with a *Change* option, 18+ and terms/privacy consent) →
  Enter code (6 digits, paste support, 60 s resend countdown, *Wrong email address?*). The
  password is kept **in memory only** in `SignupController` (never in state, storage or logs),
  sent again with the code as the API requires, and cleared on success or when the screens close.
  Signing in to an unverified account continues at the code step.
* **Forgotten password:** the app only requests the link (`POST /auth/password/forgot`, always
  "check your email"). The reset itself happens on the web page `/a/reset`, never in the app.
* **ReauthSheet:** `showReauthSheet(context)` or `withReauth(context, action)` (retries once after
  the server asks for a recent password, `403 reauth_required`). Used by *Change email*; any
  feature can use it. A wrong password (`401 invalid_credentials`) keeps the session.
* **Settings:** Profile (name, phone, country, timezone with a device-mismatch suggestion,
  language), Security (change password, change email with its code step, active sessions with
  revoke, *Log out everywhere*, app lock), Notifications, About, Terms/Privacy links
  (`PUBLIC_BASE_URL` + `/legal/terms|privacy`, opened in the browser), Sign out.
* **Onboarding steps 4-9:** first trusted contact (type it or *Pick from my contacts*, the system
  picker, no `READ_CONTACTS`), check-in schedule, plan (Standard preset with a plain-language
  preview), optional first instruction (6 starter templates), stay protected (app lock,
  notification pre-prompt, battery tip), you're set. Progress is saved after each step
  (`PreferencesStore`: step name, completed flag, opaque account id) and restored on relaunch.
  The password and the code are never persisted. Onboarding ends in the 5-tab shell; Home shows
  the readiness checklist for whatever is missing.

### Temporary repositories (Phase 2, contacts, check-ins and the plan replaced in Phases 3-5)

The instructions are a typed repository **interface** with an in-memory fake, registered only in
`lib/app/repository_providers.dart`. The UI is final; only the data source is temporary, and the
fake loses its data when the process ends. Because the instructions are not stored, **the
"Preview: your instructions are not saved yet" banner** (Home and the done step) and the preview
wording ("check-ins are on, instructions are still a preview") stay while it is registered
(`previewModeProvider`). **Trusted contacts are real since Phase 3, the check-in schedule,
check-ins and Home since Phase 4 and the plan since Phase 5** and no longer count: they are
`DioContactsRepository`, `DioScheduleRepository`, `DioCheckInRepository`, `DioHomeRepository` and
`DioPlanRepository`. The in-memory contacts fake, the check-in "server"
(`test/helpers/fake_checkin_server.dart`) and the plan "server"
(`test/helpers/fake_plan_server.dart`) live in `test/` only.
`test/app/preview_mode_test.dart` lists the stand-ins still in use: replacing one in a later phase
means editing that list, and the banner disappears when the last one is gone. Replacements:

| Interface | Replaced by | Phase |
|---|---|---|
| `ContactsRepository` | contacts API (invitations, tier limits): **done** | 3 |
| `ScheduleRepository`, `CheckInRepository`, `HomeRepository` | `/checkin/schedule`, `/checkin/activate`, `/checkins`, `/home`: **done** | 4 |
| `PlanRepository` | `GET` / `PUT /plan` (ETag / If-Match): **done** | 5 |
| `InstructionsRepository` | encrypted instructions API (bodies never cached) | 6 |

## Check-ins (Phase 4)

Flows follow [USER_FLOWS §3 step 5 and 9, §4, §5, §11](../docs/USER_FLOWS.md); the wire contract
is [API_SPEC §5-6](../docs/API_SPEC.md) with the golden files in `docs/contracts/phase4`
(`test/contracts/phase4_contract_test.dart` parses them, including the `If-Match`,
`Idempotency-Key` and `ETag` headers of the index, and skips with a message while the folder does
not exist).

* **The server decides every time.** The app sends the interval, the time of day (`HH:MM`) and the
  reminder lead, never an instant that the server trusts (`client_reported_at` is informational),
  and it computes no deadline. "Due soon" is `next_due_at - now <= reminder lead` where *now* is
  the phone's clock **plus the offset of the last `GET /home`** (`server_time - phone clock`). The
  offset is taken from `GET /home` only: a check-in response may be a replay
  (`Idempotent-Replayed: true`) carrying the original, possibly hours-old `server_time`.
* **Profile timezone.** Every time is shown in the profile's timezone through the bundled tz
  database (`package:timezone`, `latest_all`, which also knows legacy names such as `UTC` and
  `Asia/Calcutta`), never in the phone's zone: `formatDayTime` ("Tomorrow · 8:00 PM"),
  `formatSpokenDayTime` ("tomorrow at 8:00 PM"), `formatClockTime`, `formatDateTime(timezone:)`.
  "Today" and "Tomorrow" are calendar days in that zone counted from the server's now. An unknown
  zone name falls back to the phone's zone.
* **I'M OK** (`CheckInController`): `idle -> sending -> success`, and **success only after the
  server's 200**. A tap gets one `Idempotency-Key` (UUID v4). The record (an opaque account id, the
  key, the time of the tap; `PreferenceKey.pendingCheckIn`) is written **before** the request, so
  the same key is sent again after a network error or 5xx/503, with backoff
  (5 s, 15 s, 30 s, 1 min, 2 min, then every 5 min) while the app is open, when the app returns to
  the foreground and after the process was killed. Two taps never make two keys while one is
  unconfirmed. Answers: 409 `safe_required` -> "Please confirm you're safe" (nothing recorded, the
  record is dropped; the I'M SAFE flow is Phase 7); 429 -> a calm wait, the same key sent again
  after `Retry-After`; 401 after the silent refresh -> the tap is kept until the session works;
  426 -> kept (works after an update); any other 4xx -> "That check-in didn't go through", dropped.
  The record belongs to the account that tapped and is never sent for another account.
* **Home** (`HomeController`, `homeStatus`): *Not active* (checklist from `readiness.issues` and the
  setup state, "Turn on check-ins"), *Active* (You're checked in, next and last check-in, plan card
  from `plan_summary`), *Due soon*, *Overdue* (the deadline passed and the aggregate is a moment
  behind: never "checked in"), *Pending check-in* ("Not received yet — we'll keep trying" and Try
  again), *Offline* (last known status kept in memory, I'M OK still queues as pending; with no
  status at all I'M OK still works), and a neutral placeholder when `incident` is set (Phases 5/7
  fill it in). Readiness banners, one at a time: contact declined/bounced/opted out, contact
  pending, notifications off, timezone mismatch (battery optimisation has no check yet). Results are
  announced through live regions ("Checked in. Next check-in tomorrow at 8:00 PM.").
* **Settings > Check-in schedule:** interval, time and reminder; saves with `If-Match` (412 loads
  the latest and says so, nothing is overwritten unseen; 409 `incident_open` locks the form); *Turn
  on* (409 `activation_requirements_unmet` says what is missing, unknown codes generically);
  *Turn off* asks first and then needs the password (`withReauth`). **Settings > Check-in history:**
  pages of 20 with *Show more*, date and time in the profile timezone, "From the app" / "From the
  web".
* **Onboarding:** step 5 saves through the API; step 9 asks the server to activate and, when it
  refuses, says what is missing and leaves Home to show the checklist. A timezone change in the
  profile reads Home and the schedule again (the server recomputes the deadline; 409
  `incident_open` is shown calmly).

## The plan (Phase 5)

Flows follow [USER_FLOWS §3 steps 6 and 9, §10](../docs/USER_FLOWS.md); the wire contract is
[API_SPEC §8](../docs/API_SPEC.md) with the golden files in `docs/contracts/phase5`
(`test/contracts/phase5_contract_test.dart` parses them, and skips with a message while the folder
does not exist). The full plan editor, the incident timeline and I'M SAFE are Phase 7.

* **Data.** `GET /v1/plan` returns the plan with `rules` (the tier's presets, stage limit, ...) and
  `ETag: "plan-<version>"`; a new account has no stages. `PUT /v1/plan` replaces it and needs
  `If-Match: "plan-<version>"`, built from the body's `version` (never from the `ETag` header, which
  an intermediary may weaken). `PlanController` keeps the snapshot, re-reads it after a 412 (and
  after a 404, together with the contacts, and when a contact is removed), and Home is read again
  whenever the plan's version changes.
* **Step 6** saves the Standard preset: grace 3 hours (or the chosen delay, from the choices the
  server's rules allow: a free account has the presets only), stage 1 at the end of the grace
  period notifying the person's contacts. A plan that already has more stages keeps them. The
  server's answers are said calmly: changed elsewhere (412, the latest plan is loaded), a contact
  that is gone (404), a delay or stage time it refuses (422 on `grace_minutes` /
  `stages[n].offset_minutes`), the stage limit (403) and an open incident (409).
* **Step 9** still only asks the server to activate. `activation_requirements_unmet` is
  `no_contacts`, `no_stages` (no plan stage) or `stage_empty` (no stage tells a contact who is
  switched on); the step says which in words and offers the step that fixes it.
* **Plan tab** shows the grace period, who is told at each stage (names from the contacts list)
  and the worked preview, read-only; with no stages it offers *Set up your plan* (the plan step).

## Trusted contacts (Phase 3)

Flows follow [USER_FLOWS §8, §3 step 4](../docs/USER_FLOWS.md); the wire contract is
[API_SPEC §7](../docs/API_SPEC.md) with the golden files in `docs/contracts/phase3`.

* **People tab:** rows in server order (name, relationship, status chip, one-line explanation),
  pull-to-refresh, loading and error states with *Try again*, and the readiness hint (nobody
  accepted / the plan waits for someone / contacts that cannot be reached). Routes: `/people`,
  `/people/add`, `/people/<id>`, `/people/<id>/edit` (inside the People tab; the id is only ever
  produced by the app, and a malformed path goes Home).
* **Status chip:** icon + word, never colour alone; read out as "Status: Pending". Pending,
  Accepted, Declined, Opted out, Email could not be delivered.
* **Add / edit** (`ContactForm`, shared with onboarding step 4): inline validation, server answers
  mapped onto fields (`cannot_be_own_email` and `contact_duplicate` on the email field, field
  errors of a 422 on their fields), `plan_limit_reached` opens the limit sheet, anything else a
  calm notice. Editing sends only the changed fields; changing the email warns first and the
  server resets the status to Pending and re-invites.
* **Detail:** invitation history, *Resend invitation* (pending/bounced only; off with the reason
  otherwise; a 429 shows when to try again and keeps the button off until then), *Edit*, *Remove*
  (confirmation sheet: "They will no longer be notified").
* **Limits:** `GET /me/entitlements` is read by the People tab so *Add contact* can open the
  Premium explanation at the limit (free: 1 trusted contact). There is no purchase UI (billing
  arrives later); the server stays authoritative.
* **Writes are not retried automatically** (no `Idempotency-Key` is sent for contacts, and the
  server does not replay them); reads are retried by the API client as before.
* **Contact picker:** *Pick from my contacts* uses the Phase 2 `ACTION_PICK` channel in
  `MainActivity` (`ContactsContract.CommonDataKinds.Email.CONTENT_URI`). It needs no
  `READ_CONTACTS` permission and no plugin, so there is no third-party code in the path of the
  address book and nothing to keep compatible with Flutter 3.47.6; `check_manifest_permissions.dart`
  is unchanged. The picker sits behind the `ContactPicker` interface and is faked in tests.

### Try sign-up against the local backend

```bash
# terminal 1 (backend/): API on 127.0.0.1:8000, emails written to backend/.dev_mail/
make run
# terminal 2: start the emulator and run the dev flavor (API_BASE_URL is http://10.0.2.2:8000)
flutter run --flavor dev --dart-define-from-file=config/dev.json
# in the app: Get started → fill the form → Send my code, then in backend/:
make latest-mail            # prints the newest email: the 6-digit code
```

Type the code (spaces or dashes are fine). *Forgot your password?* writes a link
`<PUBLIC_BASE_URL>/a/reset#pr_…` to `.dev_mail/` as well; open it in a browser (on a Mac use
`localhost`; the CSRF cookie is `Secure`), choose a new password, then sign in again in the app:
the reset signs out every session. The backend's `PUBLIC_BASE_URL` must be an address your
browser can reach.

### App lock

* Settings → Security → App lock (also offered in onboarding step 8). Turning it on needs a
  screen lock on the phone (biometric **strong** or PIN/pattern/password as the fallback, through
  BiometricPrompt) and asks the person to confirm once. Timeouts: immediately / 1 minute /
  5 minutes (default); stored in `PreferencesStore`.
* It locks on a cold start and after the timeout in the background (the controller is fed by a
  `WidgetsBindingObserver`; "immediately" locks as soon as the app leaves the foreground). System
  dialogs (the unlock prompt, the notification permission, the contact picker) do not count as
  leaving (`runWithoutLocking`).
* **Recents thumbnail:** while the lock is on, `MainActivity` sets `FLAG_SECURE` in `onPause`
  (before the system snapshot) and clears it in `onResume`, so the recents card shows nothing.
  `MainActivity` extends `FlutterFragmentActivity` (BiometricPrompt needs it) and the launch
  themes derive from AppCompat for the same reason.
* **No screen lock / biometrics removed:** turning it on explains what to do. If the lock is on and
  the phone loses its screen lock, the lock screen explains and offers *Turn off app lock and
  continue*, the person's explicit choice; *Sign out* is always available. That choice is only
  offered, and only accepted by the controller, when `capability()` says right now that the phone
  has **no** screen lock. A transient prompt error (`uiUnavailable`, sensor busy) is a retryable
  `unavailableNow` outcome ("Try again"), never a way to switch the lock off. The first prompt
  waits until the app is resumed.
* While locked the hidden app is also out of reach of the keyboard and switch access
  (`ExcludeFocus`) and of the Back button (`didPopRoute` in the gate).
* A session that ended for the person (revoked elsewhere, password changed or reset, log out
  everywhere) leads to Sign in with "Please sign in again." (`sessionEndedNoticeProvider`); signing
  out on purpose goes to Welcome as before.
* It is a local convenience on top of the server session ([SECURITY §11](../docs/SECURITY.md)); a
  step-up for I'M SAFE is still the server password.

### Notification permission

The pre-prompt explains why first; only the *Allow notifications* button shows the Android 13+
system dialog (`permission_handler`). Denied can be asked again; permanently denied shows how to
turn it on and opens the system settings; the prompt (onboarding and Settings) refreshes when the person returns. Opening the settings is not exempt from the lock timeout.
The result (a status name) is stored. There is **no push registration yet** (Phase 8).

### Emulator walkthrough (best effort)

`tool/emulator_walkthrough.sh <dir>` boots `AfterMe_API_36` headless if no device is attached,
installs the dev APK, and taps Welcome → Next → Get started → Create account by reading
`uiautomator dump` (no hard-coded coordinates), saving a screenshot of each screen to `<dir>`.
It fails with a clear message (and `failure.png`) when a screen or button cannot be found. Build
the dev debug APK first. Like the smoke check it is manual (CI has no emulator).

## Troubleshooting

**Keep the repository out of iCloud-synced folders.** On the development Mac the repo lives
in `~/Desktop`, which is synced by iCloud Drive with *Optimize Mac Storage*. When disk space
is low, macOS evicts files to the cloud ("dataless" files). Builds then fail in confusing
ways, for example `Could not find or load main class org.gradle.wrapper.GradleWrapperMain` or
`Index: 1, Size: 1` in `FlutterTaskHelper.readDependencies`, because Gradle reads an evicted
file as empty. It also uploads gigabytes of `build/` output to iCloud.

```bash
find . -flags +dataless                    # list evicted files
brctl download <path>                      # bring one back
flutter clean                              # build outputs are regenerable
```

The fix is to move the repo to a non-synced location (for example `~/dev/AfterMe`) or turn
off *Optimize Mac Storage*, and keep enough free disk space.

## Emulator smoke check (Phase 1 exit criterion)

`tool/emulator_smoke.sh` installs the dev debug APK on a running emulator, launches it and fails
on a missing process, `FATAL EXCEPTION` or Flutter exception in logcat. It is manual (CI has no
emulator):

```bash
emulator -avd AfterMe_API_36 &
flutter build apk --flavor dev --debug --dart-define-from-file=config/dev.json
tool/emulator_smoke.sh
```

Last result (AfterMe_API_36, Android 16 / API 36, arm64): `app.afterme.dev` installed, launched,
Welcome screen rendered (name, tagline, "Get started", "Not an emergency service" line,
dev-only gallery link), logcat clean. Since Phase 2 "Get started" opens Create account;
`tool/emulator_walkthrough.sh <dir>` taps through Welcome to Create account and saves
screenshots (it stops an emulator it started, and needs `ANDROID_SERIAL` with several devices).
A cold-boot emulator may first show a transient "System UI
isn't responding" dialog; that is an emulator artefact, tap *Wait*. The script checks process and
logcat only, so confirm the Welcome screen visually (`adb shell screencap`).

## Known limitations / next steps

* Instructions are a temporary in-memory fake (table above). The plan is real, but only the
  Standard preset can be saved and the Plan tab is read-only: the plan editor (stages, offsets,
  who is told), the incident timeline and I'M SAFE arrive in Phase 7; web check-in and push
  reminders in the later phases. Home shows no readiness banner for `no_stages` / `stage_empty`
  (USER_FLOWS §4 defines none; the checklist and the activation message cover them) and does not
  list `recent_activity` yet; the battery-optimisation readiness banner needs a check that does
  not exist yet.
* A tap that was not confirmed is replayed whenever the app next runs, however much later; the
  server stamps it with the time it receives it, and the screen shows when it was tapped
  ("You tapped I'M OK at 5:30 PM") until then.
* Contacts: the activity feed ("Mom accepted") and push notices for answers arrive with the
  notifications phases; until then the People tab shows the status after a refresh. Priority
  ordering (drag to reorder) and the pause switch (`is_active`) are in the API but not in the UI.
* Push notifications (Phase 8), FLAG_SECURE on instruction screens (Phase 6) and Sentry are later
  phases.
* **Fonts:** the platform font is still used; bundling an OFL humanist sans (USER_FLOWS §1.3) is
  deferred to Phase 11. Layout tests use real Roboto metrics (`fontFamilyProvider`).
* English only; a language picker arrives with the first translation.
* Android 12+ SplashScreen with the final icon, adaptive/monochrome icons: with store assets.
* An automated `integration_test` emulator run (CI and against the dev backend) arrives with real
  flows; until then the smoke check and the walkthrough above are manual.
