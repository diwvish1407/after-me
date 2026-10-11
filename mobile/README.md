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
[The plan](#the-plan-phase-5)). Phase 6 makes the **instructions** real: the Instructions tab, the
create/edit/detail screens and onboarding step 7 run on the encrypted instructions API, and every
screen that shows instruction content keeps the window `FLAG_SECURE` (see
[Instructions](#instructions-phase-6)). Phase 7 adds incidents and I'M SAFE, the Activity feed,
export and account deletion. Phase 8 adds **push notifications** (Firebase Cloud Messaging; see
[Notifications](#notifications-phase-8)). No temporary in-memory repository is left. The backend is
authoritative; the app
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
defaults to the API origin), `SENTRY_DSN` (empty for now), `PLAY_STORE_URL` (optional: where the
"Update AfterMe" screen sends the person; defaults to the app's Play Store page, https only).
`FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_MESSAGING_SENDER_ID` and `FIREBASE_PROJECT_ID`
(Phase 8) are the four public identifiers of the Firebase app push runs on; they are empty in the
three files until the owner creates the Firebase projects ([DEPLOYMENT §4](../docs/DEPLOYMENT.md)),
and with them empty the app builds and runs normally and says push is not configured. All four are
set or none is (a mix is refused at start-up, naming what is missing).
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
`127.0.0.1` (`AppConfig.devCleartextHosts`). Android's network security config
(`android/app/src/dev/res/xml/network_security_config.xml` for dev,
`src/main/res/xml/network_security_config.xml` for staging and prod) names the same hosts, but it
governs only the platform HTTP stack (the browser hand-off, Firebase and Google Play services); the
API client is `dio` over `dart:io`, which Android's policy does not bind. The app's own rules are
what refuse cleartext (see "Android hardening").

## Quality gates

Run from `mobile/` (CI runs the same steps: [`.github/workflows/mobile.yml`](../.github/workflows/mobile.yml)):

```bash
dart run build_runner build
flutter gen-l10n
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze                                  # must report zero issues
flutter test --coverage
dart run tool/coverage_check.dart                # >= 70% overall, >= 90% interceptors, session and every Phase 2-8 feature area (contacts, check-ins, home, plan, instructions, incidents, notifications and time formatting included)
flutter build apk --flavor dev --debug --dart-define-from-file=config/dev.json
flutter build apk --flavor prod --release --dart-define-from-file=config/prod.json
dart run tool/check_manifest_permissions.dart    # merged prod manifest: INTERNET, POST_NOTIFICATIONS, USE_BIOMETRIC, WAKE_LOCK, ACCESS_NETWORK_STATE, c2dm RECEIVE (+ AndroidX's own signature permission); no AD_ID, no READ_CONTACTS
```

CI ([`mobile.yml`](../.github/workflows/mobile.yml)) runs every command above, plus a staging debug build
(flavor compile check). Coverage excludes generated files. Tests are deterministic and never use the network: the API
client is tested end to end over a fake `HttpClientAdapter` (`test/helpers/fake_http_adapter.dart`).

## Build

```bash
# Development APK
flutter build apk --flavor dev --debug --dart-define-from-file=config/dev.json

# The production release (Play upload, DEPLOYMENT §5.1): App Bundle, obfuscated, symbols kept
# privately. It needs android/key.properties and APP_ENV=prod in config/prod.json, and it runs the
# merged-manifest check on what it built.
tool/build_release.sh

# The same as an APK, or without the upload key (signed with the public DEBUG key, never
# uploaded: a loud warning says so; this is what CI does)
tool/build_release.sh --apk
tool/build_release.sh --apk --allow-debug-signing

# What the script runs (do not build a release by hand without these flags):
#   flutter build appbundle --flavor prod --release --dart-define-from-file=config/prod.json \
#     --obfuscate --split-debug-info=build/symbols
```

`tool/build_release.sh` fails, with the reason, when `android/key.properties` is missing (unless
`--allow-debug-signing` is given), when `config/prod.json` does not say `"APP_ENV": "prod"` with an
`https` API URL, or when the merged release manifest is not as documented. Keep the Dart symbols
(`build/symbols` or `--symbols-dir=`) and the R8 mapping
(`build/app/outputs/mapping/prodRelease/mapping.txt`) **private and per version**: they
de-obfuscate crash traces and are never committed. Code and resource shrinking (R8) are stated in
`android/app/build.gradle.kts`; the app's own keep rules are `android/app/proguard-rules.pro` and
`res/raw/keep.xml` (the notification icon).

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
  after an explanation) and `USE_BIOMETRIC` (app lock), declared in the main manifest, and the
  three that the Firebase Cloud Messaging libraries add (Phase 8): `WAKE_LOCK` (FCM holds a short
  wake lock while it hands a message to the app), `ACCESS_NETWORK_STATE` (declared by the
  firebase_messaging plugin) and `com.google.android.c2dm.permission.RECEIVE` ("required by older
  versions of Google Play services to create IID tokens"). The local-notifications plugin's
  `VIBRATE` is removed by the manifest (a channel vibrates on the app's behalf); there is no
  `RECEIVE_BOOT_COMPLETED`, no exact-alarm and no foreground-service permission, because nothing is
  scheduled on the phone. The merged
  prod release manifest is checked in CI: besides those it may contain only
  `app.afterme.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`, a signature-level permission that
  AndroidX Core defines for the app itself (targetSdk ≥ 33), and the legacy `USE_FINGERPRINT`
  **limited to `maxSdkVersion="27"`**: `androidx.biometric` 1.1.0 (via `local_auth`) declares it
  without a limit, Android 8.0-8.1 (our minSdk 26) still needs it for the fingerprint prompt, and
  the manifest drops it from Android 9+ (`tools:node="replace"`). **No `AD_ID`, no `READ_CONTACTS`**
  (contacts come from the system picker, which grants access to the one chosen contact). This is
  enforced by `tool/check_manifest_permissions.dart`, an allowlist check (anything else fails the
  build) with unit tests in `test/tool/`.
* **No deep links, and nothing from an intent steers the app.** The manifest has one intent filter
  (the launcher), but `MainActivity` is exported and an explicit intent skips filters, so any app
  could send it extras. `FlutterFragmentActivity` would act on `route` (the first screen),
  `cached_engine_id` (a missing one crashes the launch), `background_mode`,
  `dart_entrypoint_args`, the intent's data as a deep link and engine flags such as
  `--trace-startup`. `MainActivity` overrides every one of those hooks (and builds the Flutter
  fragment itself, without the intent's engine flags), the activity sets
  `flutter_deeplinking_enabled=false`, and the router is built with
  `overridePlatformDefaultLocation: true`, so the first route is always the app's own splash.
  Notification taps are routed by the app from the push's `data` payload, never through the intent's
  route. `tool/check_manifest_permissions.dart` asserts on the merged release manifest:
  `allowBackup="false"`, no `usesCleartextTraffic`/`debuggable` flag, deep links off, and **exactly**
  these exported components: the launcher activity, the two FCM receivers (each guarded by
  `com.google.android.c2dm.permission.SEND`) and AndroidX's `ProfileInstallReceiver` (guarded by
  `android.permission.DUMP`). Tests: `test/tool/`. **Manual device check:** on a signed-in dev
  build, `adb shell am start -n app.afterme.dev/app.afterme.MainActivity --es route
  /settings/privacy/delete` (and `-d /settings/privacy/export`, `--es cached_engine_id x`) must open
  the normal start screen and never a destructive route or a crash.
* `android:allowBackup="false"`, `android:fullBackupContent="false"`, and
  `android:dataExtractionRules` excluding everything from cloud backup **and** device-to-device
  transfer: tokens are bound to this device's Keystore ([ARCHITECTURE §5.4](../docs/ARCHITECTURE.md)).
* **Cleartext and the build's identity.** The app's HTTP client is `dio` over `dart:io`; Android's
  network security config does **not** bind `dart:io`, so it is not what keeps the API traffic on
  TLS (it does cover the platform stack, and keeps user-installed CAs out of it). What does:
  * `AppConfig` refuses an `http` API or public URL outside dev, and a development-looking host
    (loopback, `10.0.2.2`, a private network address, `.local`, a bare name) in staging and prod;
    the reverse too: a dev build takes a development-looking host only, and plain `http` only for
    `localhost`, `127.0.0.1` and `10.0.2.2` (the hosts of the dev network security config);
  * `main()` runs the whole app in a zone with `#flutter.io.allow_http` set to `config.isDev`,
    which the engine's `dart:io` connection hook reads: outside dev an `http` request to a
    non-loopback host throws before a socket is opened;
  * at start-up the application id's flavor suffix (`.dev`, `.staging`, none) must match
    `APP_ENV`; if not (a `dev.json` built into the production flavor, or the reverse), or when the
    configuration is invalid, the app shows a plain "this build is not set up correctly" page and
    makes no request at all (`MisconfiguredBuildApp`).
  Staging and prod trust the system CA store only (no user-installed CAs).

## Code layout

```
lib/
  main.dart                    bootstrap: config (fail fast), package info, ProviderScope
  app/                         AfterMeApp (+ the app-lock gate), router + redirect rules, theme/,
                               repository_providers.dart (where the repositories are chosen)
  core/
    config/                    AppConfig, AppEnv
    storage/                   SecureStore (Keystore-backed + in-memory), PreferencesStore
    auth/                      SessionStore, AuthController (unknown/signedOut/signedIn)
    api/                       Dio factory, interceptors/, models/ (freezed), failures/
    design_system/             AppButton, CheckInButton, StatusBanner, SectionCard, EmptyState,
                               AppTextField, LoadingView, ErrorView, FormPage, FitText
    security/                  app_lock/ (controller, lock screen, gate, local_auth gateway),
                               screen_privacy.dart (recents thumbnail), secure_screen.dart
                               (FLAG_SECURE for instruction content)
    permissions/               notification permission + pre-prompt controller
    forms/                     validators, password-strength hint, digits-only formatter
    pickers/                   timezone and country pickers, country names
    device/ links/ platform/   device facts, URL opener, system contact picker, file export
    push/                      PushGateway (Firebase Messaging) and LocalNotificationGateway
                               (flutter_local_notifications + the channels), the channel ids
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
    instructions/              data/ (InstructionsRepository + Dio implementation, freezed models),
                               application/ (InstructionsController, the in-memory draft, release
                               stages), presentation/ (Instructions tab, create/edit/detail, the shared
                               InstructionForm, limit sheet, examples)
    notifications/             data/ (DevicesRepository + Dio implementation), application/ (the
                               push message model and route table, PushCoordinator: token life,
                               foreground display, taps; the registration store), presentation/
                               (PushHost, the channel words)
    settings/                  settings list, profile, security, change password/email, sessions,
                               app lock, notifications, about
    home/                      data/ (HomeRepository + Dio implementation, models), application/
                               (HomeController with the server clock offset, the pure state mapping,
                               phone-side readiness checks), presentation/ (Home)
    shell/ dev/                5-tab shell, design gallery (dev only)
  l10n/app_en.arb              every user-visible string (generated code in l10n/gen/)
test/                          unit + widget tests (helpers/ has the fakes and the fake network)
  contracts/                   parses docs/contracts/phase2 to phase8 *.json (the backend's
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
and only a `String` is accepted as `extra` (the forgot-password prefill, and the name of an example to start an instruction from).

The **app lock is not a route**. `AppLockGate` sits above the Navigator in
`MaterialApp.builder`, so the lock screen also covers bottom sheets and dialogs; the app below
stays alive but is not painted, cannot be tapped and is hidden from TalkBack.

**Session loss.** A `401 session_revoked` (or a rejected refresh) makes the API client call
`AuthController.signOut`, which clears the tokens and moves to `signedOut`; every user-scoped
provider (account, sessions, the repositories, the in-memory instruction draft) watches the status and is rebuilt empty,
the router sends the person to `/welcome` from wherever they were, and open dialogs and sheets go
with the old screens. Onboarding progress is kept (it is keyed by account id and holds no
personal data), so the same account resumes after signing in again.

A `Notifier` is the same object after sign-out and sign-in (`build()` runs again), so an answer for
account A that lands after B signed in would be applied to B's state (`ref.mounted` stays true).
Every controller that holds an account's data (Home, I'M SAFE, plan, contacts, schedule,
instructions, profile, sessions, setup) counts its sessions with a `SessionEpoch` and drops an
answer from an earlier one; the paged lists (Activity, check-in and incident history) also drop a
"Show more" that was asked before the list was read again.

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
  the server asks for a recent password, `403 reauth_required`). Used by *Change email*, the
  schedule and, since the plan step-up, by saving the plan and removing or re-addressing a contact
  who is in a plan stage (see [the plan](#the-plan-phase-5)); any feature can use it. An optional
  `ReauthReason` replaces the generic body with why that action needs the password. A wrong
  password (`401 invalid_credentials`) keeps the session.
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

### Repositories (all real since Phase 6)

Every repository is a typed **interface** registered only in `lib/app/repository_providers.dart`:
`DioContactsRepository` (Phase 3), `DioScheduleRepository`, `DioCheckInRepository` and
`DioHomeRepository` (Phase 4), `DioPlanRepository` (Phase 5) and `DioInstructionsRepository`
(Phase 6). Nothing in the app runs on an in-memory stand-in any more, so the "Preview" notice and
`previewModeProvider` are gone. The fakes (the contacts repository, the check-in "server"
`test/helpers/fake_checkin_server.dart`, the plan "server" `fake_plan_server.dart` and the
instructions "server" `fake_instructions_server.dart`) live in `test/` only.
`test/app/repository_providers_test.dart` is the release gate: it fails if a repository provider
ever returns anything but the Dio implementation, or if a preview notice comes back.

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
  key, the time of the tap; secure storage `checkin.pending`) is written **before** the request, so
  the same key is sent again after a network error or 5xx/503, with backoff
  (5 s, 15 s, 30 s, 1 min, 2 min, then every 5 min) while the app is open, when the app returns to
  the foreground and after the process was killed. Two taps never make two keys while one is
  unconfirmed. Answers: 409 `safe_required` -> "Please confirm you're safe" (nothing recorded, the
  record is dropped; the I'M SAFE flow is Phase 7); 429 -> a calm wait, the same key sent again
  after `Retry-After`; 401 after the silent refresh -> the tap is kept until the session works;
  426 -> kept (works after an update); any other 4xx -> "That check-in didn't go through", dropped.
  The record belongs to the account that tapped and is never sent for another account: the owner is
  the id of the **session** (`session.user_id`, written with the tokens at sign-in and removed with
  them), never a preference, and a record that names nobody is neither kept nor read. A
  `safe_required` answer counts only for the incident it names and is dropped as soon as a read
  of Home (or an "already closed" I'M SAFE) says that incident is over, so it can never make the
  next incident read as "your contacts have been notified".
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
* **Step-up for changes that weaken the safety net** ([SECURITY §7](../docs/SECURITY.md)). The server
  answers `403 reauth_required`, before it changes anything and after ownership and validation
  (404/422), for `PUT /v1/plan` when check-ins are on and the body really changes the plan, for
  `DELETE /v1/contacts/{id}` and for `PATCH /v1/contacts/{id}` (email changed, or `is_active`
  false) when check-ins are not off and the contact is in a plan stage. The app does what the
  schedule does: `withReauth` shows the existing password sheet with a one-line reason of its own
  (`ReauthReason.plan`, `.removeContact`, `.contactEmail`), calls `POST /auth/reauth` and sends the
  **same request again, once** (same body, same `If-Match`). Closing the sheet, or a wrong
  password, sends nothing and says nothing more than the sheet does; the controllers
  (`PlanController.save`, `ContactsController.removeContact` / `updateContact`) leave their state
  untouched on that 403. Nothing is asked pre-emptively and nothing during onboarding.
  Callers: the plan step (also opened from the Plan tab and the Home banner), Remove on the
  contact detail and Save on the contact edit form. There is no switch for `is_active` in the app
  yet; when there is one it needs its own reason string.
* **Home banner for a gap.** With check-ins on (Active, Due soon, Overdue; not Not active, where the
  checklist says it, and not during an incident, when the plan is read-only) and `no_contacts`,
  `no_stages` or `stage_empty` in `readiness.issues`, Home shows a persistent, non-dismissible
  attention banner above the status: what is wrong and what it means in one sentence, and one action
  that opens the step that fixes it (contact first: *Add a trusted contact*; otherwise *Review your
  plan*, the plan step). It sits with the readiness banner, the offline banner and the pending or
  expired check-in notice without hiding any of them or I'M OK, and goes when Home reads the
  aggregate again after the fix. Per-contact issues (declined, bounced, opted out, pending) keep
  their own banner; they are not a gap.

## Instructions (Phase 6)

Flows follow [USER_FLOWS §3 step 7, §9](../docs/USER_FLOWS.md); the wire contract is
[API_SPEC §10](../docs/API_SPEC.md) with the golden files in `docs/contracts/phase6`
(`test/contracts/phase6_contract_test.dart` parses every file of the index, problems included, and
skips with a message while the folder does not exist).

* **Data.** `GET /v1/instruction-categories` (ids; the words are localised in the app),
  `GET /v1/instructions[?category=]` (summaries, **no body**), `POST`, `GET /{id}`, `PATCH` (any
  subset; `recipients` replaces the list) and `DELETE`. Title 1-120 and body 1-20,000 characters of
  plain text, counted as code points like the server; control characters and text-direction
  overrides are refused on the device and by the server (`invalid_characters`). The list holds
  summaries only: a body is read for the one screen that shows or edits it
  (`InstructionByIdView`), held in that widget's state and dropped with it. It is never in a
  provider, a cache, storage, a log or an error message (`toString` of every content model is
  redacted). Writes carry no `Idempotency-Key` and are not retried automatically.
* **Create / edit** (`InstructionForm`, shared with onboarding step 7): category, title, text, **Who
  receives this?** (the trusted contacts, several allowed; somebody who has not accepted yet is
  allowed with a gentle note) and **When?**, worded "If you haven't checked in for 2 days": the
  plan's own stages that run at least `rules.release_offset_min` = 1 day after a missed check-in
  **and** the tier's presets of 1, 2 and 3 days that the plan has no stage for yet
  (`releaseOptions`; offered only where the server would accept the stage: the plan already has a
  first stage, has room under `max_stages`, and the time is later than the first stage and 30
  minutes from every other). One time for everybody, or one per person, which edit keeps when the
  instruction already has different times.
  * **Choosing a time the plan has no stage for adds that stage when the instruction is saved**
    (`InstructionsController.addInstructionWithTimes` / `updateInstructionWithTimes`): one
    `PUT /v1/plan` (`If-Match`) with every existing stage exactly as it is (ids, times, contacts)
    plus a new stage per distinct time telling the people chosen for it, then the instruction with
    the new stage ids. All new stages are one request, so the plan changes completely or not at all.
    A 412/428 re-reads the plan and tries once more, silently (a stage another device added is
    reused), then shows the plan's "changed somewhere else" notice. If the plan cannot be saved
    nothing is sent for the instruction. If the instruction is refused after the plan was saved the
    form says so plainly, keeps the draft, and the stage stays (the next try finds it and uses it,
    without a second plan save). `403 plan_limit_reached` (stages) says the free plan's room (2)
    was hit and that nothing was changed. The whole save runs inside one `withReauth` (reason
    `ReauthReason.instructionNewTime`), so there is one password sheet and each request is sent
    once after it; during onboarding nothing is asked.
  * With no time to choose (the plan has no stage at all, or no room for another and none far
    enough out) the form says so plainly, offers *Review your plan*, and the instruction can still
    be saved with nobody to receive it.
  Digital Accounts shows "Don't paste passwords. Say where they can be found (for example, your
  password manager's emergency access)." *Start from an example* fills in the title and a skeleton
  of 4 per category (36 in `app_en.arb`, examples only: prompts, never real data); onboarding and
  the empty tab offer the six featured ones. Server answers land on fields (`title`, `body`,
  `category`, `recipients[n].contact_id`, `recipients[n].release_stage_id`) in the app's own words;
  the free-plan `plan_limit_reached` for instructions opens the limit sheet (3 on the free plan, no
  purchase action).
* **The draft** being typed is kept in memory only (`InstructionAutosave`), so leaving to add a
  contact or review the plan loses nothing; it is dropped when the instruction is saved, on
  *Start over* and when the session ends, and is never written anywhere.
* **List** grouped by category with a filter; each card has the title, an Active/Inactive chip (icon
  and word), the recipients' initials and "Mom: After 1 day" (from the plan's own offset, "Stage 2"
  while the plan is not loaded), and the notes for recipients who have not accepted or cannot be
  reached. **Detail**: text, who and when ("Stage 2: after 1 day"), the Active switch, Edit and
  Delete behind a confirmation sheet. The Plan tab says how many instructions a stage shares, and
  Home's plan card shows `instructions_active`.
* **Step-up** ([SECURITY §7](../docs/SECURITY.md)). While check-ins are on the server answers
  `403 reauth_required` (after ownership and validation) for: creating an instruction with
  recipients, changing its recipients, switching off or deleting one that has recipients, and
  removing or re-addressing a contact who only receives an active instruction. The app does what
  the plan does: `withReauth` shows the password sheet with a reason of its own
  (`ReauthReason.instructionRecipients`, `.instructionOff`, `.removeRecipient`, `.recipientEmail`)
  and sends the **same request again, once**; closing the sheet changes nothing and says nothing.
  Editing the text or the category, switching on, an instruction nobody receives and everything
  during onboarding never ask.
* **Reading needs a fresh password too** (Phase 9). `GET /v1/instructions` and
  `GET /v1/instructions/{id}` answer `403 reauth_required` unless the password was entered in the
  last 5 minutes. That is an ordinary state, never a reason to end the session (a 403 is not a 401):
  * The list controller's state is then an `AsyncError` holding that `ForbiddenFailure`
    (`InstructionsListState.needsPassword`); every other consumer (Home, the checklist, the plan
    editor) reads `.value` and sees "nothing yet". Nothing is cached on disk, and a change the
    server confirmed while the list is locked is **not** turned into a list of one: the list is
    read again instead.
  * The Instructions tab says "Your instructions are hidden" with *Show my instructions*, and a
    pull-to-refresh after the 5 minutes ran out, through `withReauth` with
    `ReauthReason.instructionRead`: the sheet once, then the same read once. Closing the sheet says,
    calmly, that they stay hidden and changes nothing; a wrong password stays in the sheet; a read
    refused again after the password is said as hidden, not retried.
  * An instruction's page (detail and edit) reads through `withReauth` at once (the person just
    tapped it); closing the sheet leaves a page that says it stays hidden, with *Show this
    instruction*.
  * The plan editor names the instructions of a stage (the "can't be removed yet" sheet and notice)
    only after the same prompt; without it, it still says how many.
  * Home and the incident screens take titles from the Home and incident APIs, not from the
    instructions API, so they never ask.
* **FLAG_SECURE (FR-INS-06).** `SecureScreen` wraps every screen that shows or edits instruction
  content (the whole Instructions tab, create, edit, detail and the onboarding editor), and, since
  the Phase 9 review, every screen where a password is typed or a file of the person's data is
  requested: sign in, create account, change password, the password sheet, export and delete
  account (`test/core/security/password_screens_secure_test.dart`). It tells
  `MainActivity` over `app.afterme/secure_screen` to set or clear `FLAG_SECURE`: no screenshots, no
  screen recording and nothing in the recents card. It is reference counted (`SecureScreens`), so a
  page on top of another never clears it for the one below, and it follows what is *shown*, not what
  is built: the shell keeps every tab's navigator alive, so it holds the flag only while its
  `TickerMode` is on, which also lets go when a page is covered by another route. The flag is
  cleared a microtask after the last holder lets go, so a page replaced by another never leaves a
  gap. The native side keeps this reason apart from the app lock's recents reason (`onPause`):
  neither clears the other's flag. Android only; no package, no new permission.
* **What is not E2EE.** Content is encrypted at rest on the server and opened for the owner's own
  requests and for released recipients; it is not end-to-end encrypted ([SECURITY §18](../docs/SECURITY.md)).
  The text fields turn off the keyboard's personal learning (`enableIMEPersonalizedLearning`).

## Activity, privacy and data, and the update gate (Phase 7)

Flows follow [USER_FLOWS §11, §14](../docs/USER_FLOWS.md); the wire contract is
[API_SPEC §3 and §11](../docs/API_SPEC.md) with the golden files in `docs/contracts/phase7`
(`test/contracts/phase7_contract_test.dart` parses every file of the index, problems included, and
the two incident goldens whose `releases` are not empty).

* **Activity** (Settings > Activity, `/settings/activity`; `features/activity`). `GET /v1/activity
  ?limit=20&cursor=` newest first, grouped by day in the profile's timezone, **Show more** follows
  the opaque cursor, pull to refresh, empty and error states. The server sends `action` and
  `params`; the words are composed here (`describeActivity`, one case per row of the API_SPEC §11
  table). An action this version does not know reads "Something changed on your account" (never
  hidden); a `null` `contact_display_name` / `instruction_title` falls back to wording that does not
  need it. `ActivityItem` keeps whatever `params` hold and ignores unknown fields. Titles are the
  owner's content: `SecureScreen(enabled: ...)` holds `FLAG_SECURE` only while an entry that names
  an instruction is on screen. Home shows the aggregate's newest three `recent_activity` entries
  (action and time only) with **See all activity**.
* **Export my data** (`/settings/privacy/export`). Says first that the file holds the decrypted
  instructions, then `withReauth` -> `POST /v1/me/export` at once (the server accepts the password
  for **60 seconds** and an export spends it; 3 an hour) -> the bytes go to the system's save dialog
  through `app.afterme/export` (Android Storage Access Framework, `ACTION_CREATE_DOCUMENT`, name
  `afterme-export.json`, no storage permission, no copy kept by the app). The request is read as
  **bytes** (`ResponseType.bytes`; error bodies are read by `ApiProblem.tryParse` from bytes too),
  stopped at 32 MiB, never repeated by the client, never decoded, logged or kept. "Saved" is said
  only after the activity wrote the file (on a background thread: a large file to a cloud provider
  can be slow; a half-written document, or an empty one created for nothing, is deleted); cancel, a failed
  write, no document provider and an export too large each have their own calm sentence. The save
  dialog runs inside `runWithoutLocking`, like the contact picker.
* **Delete account** (`/settings/privacy/delete`). Lists exactly what happens; the button is off
  until `DELETE` is typed exactly; `withReauth` immediately before `DELETE /v1/me`
  `{"confirm":"DELETE"}`. The screen cannot be left while the request is in flight. On `202`
  (every session is already revoked server-side) `DeleteAccountController` - which outlives the
  screen - sets the "closed" notice, ends the local session through the existing sign-out path
  (`SessionStore.clear()` deletes only the `session.*` keys, never `deleteAll`), then
  `LocalAccountData.wipe()` removes the pending check-in record and every preference and resets the
  app lock and onboarding in memory. The router then shows **Your account has been closed** with the
  purge date, then sign-in. Nothing after the `202` can turn into a failure: a storage error while
  the session ends is swallowed, and the clean-up steps are independent. A network failure says "not
  confirmed, nothing changed on this screen" and the request can be repeated. A `401` after a
  request whose outcome was unknown is **not** "closed": the session may have ended for an unrelated
  reason while the account and its schedule are live. The person is signed out of the stale session,
  the same final route says "We couldn't confirm that your account was closed" (an email will come
  if it was; otherwise sign in again), and **nothing is deleted** on the phone (the pending check-in,
  the preferences and the app lock stay). A `401` on the first request is only an ended session.
* **Your plan** (`/settings/your-plan`): `GET /v1/me/entitlements`, "Free · 1 of 1 contact · 0 of 3
  instructions · 1 of 2 stages", what Free does not have (own times), and a calm "Premium isn't
  available yet" line. No purchase action until billing exists.
* **If you lose your phone** (`/settings/lost-phone`): the configured public address + `/a/login`
  shown as text and opened with the same mechanism as the legal pages.
* **Offline.** A list that cannot be refreshed keeps what it has and says "Showing the last
  information we have" (People, Instructions, Plan, Activity, check-in and incident history; Home
  has its own offline banner): `StaleData` is marked by a failed `reload()` and cleared by the next
  one that works. Actions that have no queue (plan save, instruction save, I'M SAFE, export,
  delete) use `actionFailureMessage`: no answer is "we couldn't confirm that", nothing on the screen
  changes and the person's input stays.
* **426 gate.** `UpgradeGateInterceptor` (last in the API client's chain) raises `upgradeGateProvider`
  on any 426 and clears it on the next 2xx. `UpgradeRequiredGate` (in `MaterialApp.builder`, under the
  app lock) covers the whole app with **Update AfterMe** (store link from `PLAY_STORE_URL`, **Check
  again**) and keeps what is below alive and inert: forms keep their text, and a pending check-in
  stays in secure storage and is sent after the update. No other failure raises it. **Check again**
  is one real request and claims only what it answered: signed in it reads Home, signed out it
  sends `GET /v1/me` without a token (the version check runs before authentication; `/health` is
  not version-checked and would prove nothing). A 426 says "still isn't supported"; no usable
  answer (offline, 5xx, 429) says "We couldn't check just now" and the screen stays.
* **Home banner.** "Review your plan" (no stage, or a stage that tells nobody) opens the plan
  editor (`/plan/edit`) because the banner only exists while check-ins are on; the checklist of an
  account that is still setting up keeps opening the onboarding step.

## Trusted contacts (Phase 3)

Flows follow [USER_FLOWS §8, §3 step 4](../docs/USER_FLOWS.md); the wire contract is
[API_SPEC §7](../docs/API_SPEC.md) with the golden files in `docs/contracts/phase3`.

* **People tab:** rows in server order (name, relationship, status chip, one-line explanation),
  pull-to-refresh, loading and error states with *Try again*, and the readiness hint (nobody
  accepted / the plan waits for someone / contacts that cannot be reached). A contact answers where
  the app cannot see it, so the list is read again, silently (the list and its scroll position stay),
  whenever the tab comes back into view and whenever Home's `contacts_verified` / `contacts_total`
  disagree with the list on hand. Routes: `/people`,
  `/people/add`, `/people/<id>`, `/people/<id>/edit` (inside the People tab; the id is only ever
  produced by the app, and a malformed path goes Home).
* **Status chip:** icon + word, never colour alone; read out as "Status: Pending". Pending,
  Accepted, Declined, Opted out, Email could not be delivered.
* **Add / edit** (`ContactForm`, shared with onboarding step 4): inline validation, server answers
  mapped onto fields (`cannot_be_own_email` and `contact_duplicate` on the email field, field
  errors of a 422 on their fields), `plan_limit_reached` opens the limit sheet, anything else a
  calm notice. Editing sends only the changed fields; changing the email warns first and the
  server resets the status to Pending and re-invites (and, while check-ins are on, asks for the
  password when the contact is in a plan stage; closing that sheet leaves the form as it was).
* **Detail:** invitation history, *Resend invitation* (pending/bounced only; off with the reason
  otherwise; a 429 shows when to try again and keeps the button off until then), *Edit*, *Remove*
  (confirmation sheet: "They will no longer be notified"; while check-ins are on, removing someone
  who is in a plan stage then asks for the password, see [the plan](#the-plan-phase-5)).
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
  screen lock on the phone (any biometric the phone accepts to unlock it, class 2 or class 3, or
  PIN/pattern/password as the fallback, through BiometricPrompt: `local_auth_android` asks for
  `BIOMETRIC_WEAK or BIOMETRIC_STRONG` and offers no class-3-only option) and asks the person to
  confirm once. Timeouts: immediately / 1 minute /
  5 minutes (default); stored in `PreferencesStore`.
* It locks on a cold start and after the timeout in the background (the controller is fed by a
  `WidgetsBindingObserver`; "immediately" locks as soon as the app leaves the foreground). System
  dialogs (the unlock prompt, the notification permission, the contact picker) do not count as
  leaving (`runWithoutLocking`).
* **Recents thumbnail:** while the lock is on, `MainActivity` sets `FLAG_SECURE` in `onPause`
  (before the system snapshot) and clears it in `onResume` (unless an instruction screen holds it
  for its own reason, see [Instructions](#instructions-phase-6)), so the recents card shows nothing.
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
The result (a status name) is stored. An answer registers the FCM token with the server at once and
updates Home's "notifications are off" banner (see [Notifications](#notifications-phase-8)).

### Emulator walkthrough (best effort)

`tool/emulator_walkthrough.sh <dir>` boots `AfterMe_API_36` headless if no device is attached,
installs the dev APK, and taps Welcome → Next → Get started → Create account by reading
`uiautomator dump` (no hard-coded coordinates), saving a screenshot of each screen to `<dir>`.
It fails with a clear message (and `failure.png`) when a screen or button cannot be found. Build
the dev debug APK first. Like the smoke check it is manual (CI has no emulator).

## Integration tests on an emulator (Phase 7, MOB-61 to MOB-65)

The real app, on an Android emulator, against the real dev backend (API and worker) with the
**test clock** ([TEST_PLAN §6](../docs/TEST_PLAN.md), [API_SPEC §17](../docs/API_SPEC.md)). They
live in `integration_test/` (the `integration_test` SDK package is a *dev* dependency: it is not in
any release build and adds no permission to the merged manifest) and are **not** part of
`flutter test`, which runs `test/` only.

```bash
tool/integration.sh                                  # all five, from a cold start
tool/integration.sh --only mob63_missed_grace_test.dart
tool/integration.sh --keep-emulator                  # leave a booted emulator for the next run
```

The script drops and recreates the throwaway database `afterme_it` (never `afterme_dev`) and
migrates it; starts the API on `127.0.0.1:8000` and the worker (`AFTERME_TICK_SECONDS=2`) with
test support on, one random token and rate limits off; uses the attached device or boots
`AfterMe_API_36` headless; runs each `integration_test/mob6*_test.dart` (one install each); prints
the tail of the worker and API logs when a test fails; and always stops what it started. Logs and
the mail directory are in a temporary directory whose path it prints. It needs PostgreSQL running
with a superuser reachable as your OS user, the backend's `.venv` (`make setup` once), and port
8000 free (it refuses to start otherwise). A full run takes about five minutes.

To run one file by hand against a backend you started yourself (API and worker with
`AFTERME_TEST_SUPPORT_ENABLED=true` and `AFTERME_TEST_SUPPORT_TOKEN=<40+ characters>`, both on the
same database and the same token):

```bash
flutter test integration_test/mob63_missed_grace_test.dart -d emulator-5554 --flavor dev \
  --dart-define-from-file=config/dev.json --dart-define=TEST_TOKEN=<that token>
```

| Test | What it drives |
|---|---|
| MOB-61 | Sign-up with the emailed code, onboarding, a contact who accepts through the real `/c` pages, schedule, plan, activation; Home active, People shows the contact accepted. |
| MOB-62 | I'M OK: "Checked in" appears only once the server lists the check-in; Home and the history screen follow. |
| MOB-63 | The test clock passes the deadline; the worker opens the incident; Home shows the grace state; I'M OK resolves it; no `contact_alert` was sent. |
| MOB-64 | Stage 1 runs and the settle delay passes (stepwise, as the worker refuses a late contact message); the contact is alerted; Home offers I'M SAFE; password sheet, confirmation, result; the contact gets the all-clear; the timeline, past incidents and Activity read the real data. MOB-64b: an I'M OK from a phone that has not refreshed gets `409 safe_required` and ends on the I'M SAFE path with nothing recorded. |
| MOB-65 | Export (password, the real `POST /v1/me/export`) and account deletion (type DELETE, password), the closed-account screen with the purge date, and a sign-in that fails afterwards. |

How they are built: `integration_test/support/harness.dart` starts the app widget with the same
providers as `main()` (real API client, secure storage, preferences, device plugins) on a wiped
phone, and waits only by pumping frames until the screen shows something, with a timeout that
reports the screen and the server's own `GET /v1/home` for the test account. `support/backend.dart`
is the tests' own `Dio`: test clock, mail reader, the contact's public pages (CSRF cookie and field,
`POST /c/session`, `POST /c/invite/accept`) and a probe session for reading server state. Each test
uses a fresh account (`it+<timestamp>@example.com`), so the tests are independent and the clock
only ever moves forward. What is not covered: the system's save dialog for the export (Storage
Access Framework, system UI) is replaced by a recording `FileExportGateway`, so the real picker
stays a manual check; system permission dialogs are never opened (the notification step is passed
with Continue); and `main()` itself is not executed (`tool/emulator_smoke.sh` covers the launch).
The debug APK these runs build holds the throwaway test token as a `--dart-define`.

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

* The plan editor, the incident timeline and I'M SAFE are built (Phase 7). The instruction form
  closes the "no stage a day out" gap itself by adding a stage at 1, 2 or 3 days to the plan when
  the person chooses that time (see [Instructions](#instructions-phase-6)); its "Review your plan"
  action still opens the onboarding plan step. Push reminders come from the server (Phase 8).
* The export's save dialog (Storage Access Framework) and the account deletion have been exercised
  through the Dart gateways, the real API client over a fake network and widget tests only; neither
  has been run on a device yet.
* A tap that was not confirmed is replayed whenever the app next runs, however much later; the
  server stamps it with the time it receives it, and the screen shows when it was tapped
  ("You tapped I'M OK at 5:30 PM") until then.
* Contacts: "Mom accepted" shows in Activity (Phase 7); a push when a contact could not be reached
  opens the People tab (Phase 8); the People tab also reads the status again whenever it comes into
  view. Priority
  ordering (drag to reorder) and the pause switch (`is_active`) are in the API but not in the UI.
* Sentry is a later phase. Attachments (FR-INS-09) are deferred.
  FLAG_SECURE has been tested through the Dart gateway and the channel only; it has not been seen on
  a device yet.
* **Fonts:** the platform font is still used; bundling an OFL humanist sans (USER_FLOWS §1.3) is
  deferred to Phase 11. Layout tests use real Roboto metrics (`fontFamilyProvider`).
* English only; a language picker arrives with the first translation.
* Android 12+ SplashScreen with the final icon, adaptive/monochrome icons: with store assets.
* An automated `integration_test` emulator run (CI and against the dev backend) arrives with real
  flows; until then the smoke check and the walkthrough above are manual.

## Notifications (Phase 8)

Flows follow [USER_FLOWS §6, §11, §13](../docs/USER_FLOWS.md) and
[ARCHITECTURE §5.7](../docs/ARCHITECTURE.md); the wire contract is
[API_SPEC §4](../docs/API_SPEC.md) with the golden files in `docs/contracts/phase8`
(`test/contracts/phase8_contract_test.dart` parses the device requests, responses and the problem,
and **reads `push_payloads.json`**: a push type the server sends that the app has no mapping for
fails that test). The server sends the pushes; the app never schedules an alarm or decides anything
from a push.

* **Packages.** `firebase_core` 4.15, `firebase_messaging` 16.7 and `flutter_local_notifications`
  22.3; nothing else of Firebase (no analytics, no crashlytics). Dev-only: the platform interfaces
  of those two, to test the adapters against a fake platform. **No `google-services.json` and no
  google-services Gradle plugin:** Firebase is started from Dart with `FirebaseOptions` built from the
  four `FIREBASE_*` values of the config file.
* **Configure a build.** Put the four values of the Firebase app of that flavor in
  `config/<env>.json`:

  ```json
  "FIREBASE_API_KEY": "…", "FIREBASE_APP_ID": "1:…:android:…",
  "FIREBASE_MESSAGING_SENDER_ID": "…", "FIREBASE_PROJECT_ID": "…"
  ```

  (the `current_key`, `mobilesdk_app_id`, `project_number` and `project_id` of that app's
  `google-services.json` in the Firebase console, which is only read, never added to the repo).
  Each flavor has its own application id and so its own Firebase Android app
  (`app.afterme.dev`, `app.afterme.staging`, `app.afterme`). With the values empty the app builds and
  runs normally; Settings > Notifications says "Phone notifications aren't set up in this version of
  AfterMe" and nothing is registered.
* **Everything is behind two interfaces,** like the app lock and the file export:
  `PushGateway` (`core/push/push_gateway.dart`: token, refresh stream, delete, the foreground and
  opened-app message streams, the initial message) and `LocalNotificationGateway`. The Firebase and
  plugin adapters are thin and tested against a fake platform interface and mocked channels
  (`test/core/push/`); the logic above them is tested with fakes (`test/helpers/fake_push.dart`).
  The system permission is **not** in `PushGateway`: the existing notification permission gateway is
  the one place that knows it (Home's banner, Settings and the token's life cannot disagree).
* **The token's life** (`PushCoordinator`). Once the person is signed in, push is configured and the
  permission is granted, the token is sent with `PUT /v1/devices/current` (`platform`,
  `app_version`, `os_version`, `locale`, `push_token`): at start, when the app returns, when FCM
  issues a new token and when the permission changes. A token that has not changed (with the same
  facts) is not sent again for a day. The record of what was sent is in secure storage, bound to
  the account. Turning notifications off (the permission revoked) sends `push_token: null`, once.
  A token the server would refuse (not 20-4096 printable characters) is not sent; a 422 is left
  alone until tomorrow or a new token; a network, 5xx or 429 answer is tried again after 1, 5 and 15
  minutes (and again when the app returns); a 401 is the session handling's. Nothing blocks the UI.
* **Sign-out** (any kind: the person's, a session the server ended, a closed account): the
  registration is forgotten and the FCM token on the phone is deleted, **after** the server call
  (the status changes only once the sign-out request was answered), and FCM is turned off until the
  next sign-in (`firebase_messaging_auto_init_enabled` is `false` in the manifest, and turned on
  only with the first `getToken`). A delete that fails (offline) is marked and done at the next
  start. A token is never registered while signed out.
* **Channels.** `reminders` (high), `incidents` (high) and `account` (default), created at start
  by `MainActivity` (`app.afterme/notification_channels`) with a **private** lock-screen visibility
  and the names and descriptions of the ARB, so the person can silence reminders without silencing
  alerts. The server's pushes name their channel (and `visibility: PRIVATE`); a push that names none
  lands in `account`.
* **A push while the app is open** is shown through the local-notification gateway (the system shows
  nothing for it): on the channel the message names (or its type's own), with the **server's
  generic text** (the app composes none), and Home is read again. A message with no known
  `data.type`, or a `v` other than `"1"`, is ignored; nothing from a message is stored or logged
  (only the type is ever a word in the code). While nobody is signed in nothing is shown.
* **A tap** (system tray, a notification the app showed, or the one that started the app) goes by
  `data.type`: everything to Home except `contact_unreachable`, which opens People; an unknown type
  opens Home. A tap while the session is being read waits; signed out it goes to sign-in and shows
  nothing; during onboarding the router resumes the saved step; the **app lock is above the
  navigator**, so a tap while locked changes the page under the lock and nothing shows until the
  person unlocks (`push_flow_test.dart`).
* **The background handler** (`afterMeBackgroundMessageHandler`, a top-level `vm:entry-point`) does
  nothing: the system shows notification messages by itself, and a push is only a hint.
* **Settings > Notifications** shows the permission status, "Open phone settings" when it is blocked,
  the three channels in plain words, what is lost with notifications off (and that reminders and
  alerts also arrive by email), that a notification never names a person, and, in a build without
  push, that it is not set up.
* **Not verifiable without a Firebase project and a device:** the real token, delivery in the
  foreground, the background and a closed app, the channels in the system settings, and the
  lock-screen behaviour (`docs/TEST_PLAN.md` lists the manual checks).

