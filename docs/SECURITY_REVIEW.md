# AfterMe — Security review (Phase 9)

| | |
|---|---|
| **Status** | Phase 9 complete, awaiting product-owner review |
| **Date** | 2026-10-12 |
| **Against** | the system as built through Phase 8 ([ROADMAP](ROADMAP.md)): FastAPI backend, Android app, web pages, engine, notifications |
| **Baselines** | OWASP ASVS 4.x L2 (API and web), OWASP MASVS L1 (+ selected L2 storage controls), OWASP API Security Top 10 (2023); the threat model in [SECURITY §5](SECURITY.md#5-threats-and-controls) |
| **Exit criterion** | A written security review report; zero open S1/S2 findings |
| **Related** | [SECURITY](SECURITY.md) · [TEST_PLAN §5](TEST_PLAN.md#5-security-and-authorization-tests) · [ESCALATION_ENGINE §13](ESCALATION_ENGINE.md) |

## 1. Result

**No S1 was found, and no S2 is open.** Four independent reviews found three S2 defects between them (§4); all three are fixed and covered by regression tests. Everything of S3 that was cheap and safety-relevant is fixed (§5); the rest is either an owner decision (§7) or a residual risk written into [SECURITY §18](SECURITY.md#18-accepted-residual-risks-10) (§8).

This is a **design-and-code review plus an automated test pass**. It is not a penetration test, it was not run against a real email provider, a real Firebase project or a physical phone (Phase 8 owner actions are still open), and it cannot replace the external test recommended in §9.

| Severity | Found | Fixed | Mitigated, residual recorded | Open |
|---|---|---|---|---|
| S1 (privacy or safety failure) | 0 | – | – | **0** |
| S2 (a stated control missing or bypassable) | 3 | 3 | – | **0** |
| S3 (hardening, preconditions) | about 30 (several found by more than one reviewer) | 21 (§5.1, §6.2) | the rest, in §5.3 and SECURITY §18 | none blocks launch; owner decisions and deferred items listed |
| S4 (informational) | about 30 | the cheap ones (look-alike names, `send_code` after close, test-support second guard, FLAG_SECURE on password screens, `redirect`-free docs corrections) | recorded | |

## 2. How the review was done

| Review | Scope | Method |
|---|---|---|
| Authentication and web | sessions, JWT, refresh, step-up, rate limits, enumeration, CSRF, cookies, headers, portal, webhooks, test support, configuration | A reviewer who read every file in scope and exercised pure functions (`email_validator`, `client_ip`, Jinja autoescape); nothing run against PostgreSQL |
| Data, crypto and engine | owner scoping of every repository method, database roles, grants and triggers (effective privileges computed from migrations 0001–0008), envelope encryption, the three decrypt sites, engine boundaries, logging and leakage, injection, export and deletion, operator CLI | Read-only code review with attack paths written out |
| Mobile (MASVS L1) | storage, logging, manifest, network configuration, platform channels, deep links, app lock, build configuration, dependencies | Source review **and** a release APK built, signed with the debug key, and inspected with `apkanalyzer`/`aapt2`/`apksigner` and the shipped engine bytecode |
| Assurance map | T1–T26 conformance, SEC-01…26 coverage, mobile checklist inventory | Each control traced to code and to the test that would fail if it broke |
| Automated scans | backend dependencies, mobile dependencies, committed secrets, log leakage | `pip-audit` (81 packages), OSV over `pubspec.lock` (157 hosted packages), a secret scan of the working tree and all commits, and a lifecycle log-leak test |

Reviewers were told to treat comments and documents as claims to verify, not as proof, and to report only findings with a concrete attack path or failure scenario.

## 3. Automated scans

| Scan | Result |
|---|---|
| Backend dependencies (`scripts/audit_deps.py`, pip-audit) | 81 packages, **no known vulnerabilities** |
| Mobile dependencies (OSV over `pubspec.lock`; `mobile/tool/audit_deps.dart`, new, wired into CI) | 157 hosted packages, **no advisories**. Gradle/Maven dependencies are not covered by OSV's Pub ecosystem; Dependabot now watches them |
| Secrets (working tree + every commit; gitleaks is not installed locally and runs in CI) | 35 hits, **all fixtures, placeholders or identifiers** (contract JWTs carry `example-user`; the `.env.example` key block is `...`). No committed `.env`, key, keystore or `google-services.json`; `.gitignore` covers each |
| Log leakage over a whole lifecycle (`tests/security/test_log_leak_lifecycle.py`, new) | **No leak.** One person goes through push-token registration, the lost-phone pages, a missed check-in, alert and release, a portal read with the one-time code, a signed, replayed and forged bounce webhook, I'M SAFE, export, deletion and purge, under the production JSON formatter at DEBUG with third-party loggers included; passwords, tokens, the push token, webhook secrets, the code, contact names and addresses and instruction text are absent from the logs and from the operator tables |

## 4. The three S2 findings

### 4.1 A stranger could lock the owner out of sign-in, the lost-phone page and recovery

*Found by the authentication review (F1; also F-03 of the coverage audit).* The failure budget was per account: five wrong passwords for a known email from one address made `429` precede the password check for everyone, including the owner with the right password, on the app and on `/a/login`. Three password-reset or signup requests an hour for the same address used up that address's recovery budget the same way. A person who has lost the phone is exactly who needs `/a/login`, and a person who cannot check in gets their contacts alerted.

**Fix.** The hard budget is per **(account, network)** (`LOGIN_PER_ACCOUNT_NETWORK`); a stranger spends only their own network's allowance. The account lock after 10 consecutive failures is kept for guessing spread over many networks, but it is now **indistinguishable from a wrong password** (same work, `401`, no `Retry-After`; this also closes the enumeration finding F13) and it does **not bind a device the account already knows** (an unguessable device id with the right password). Recovery, signup and deletion-link budgets are per (address, network) with a higher ceiling across networks that only stops a flood.

**Residual (SECURITY §18):** a persistent attacker with several networks (IPv6 makes that cheap) can still hold the lock on and degrade *password* sign-in from a new browser in 15-minute windows. Signed-in phones, known devices and recovery by email are unaffected, and the owner is emailed when the lock engages. Severity after the fix: S3.

### 4.2 A stolen access token could read every decrypted instruction

*Found by both backend reviews (F2, BD-2).* `GET /v1/instructions` and `/{id}` needed only a bearer token, left no trace, and made the password-gated export (60-second window) moot: 200 GETs reproduce it. This was the open owner decision "should reading an instruction need a recent password" carried since Phase 6.

**Fix (taken on the owner's behalf, see §7.4).** Both reads need the password entered in the last five minutes (`403 reauth_required`), and each read writes an `instruction.viewed` audit row (a count, never text; not shown in Activity). The app asks once per reading session through the existing re-authentication sheet.

### 4.3 The API database role could make the worker send a forged "X has not checked in" email

*Found by the data review (BD-1).* The 0005 trigger refused only the escalation category for `afterme_api`. The dispatcher routed by category and applied its template allow-list only inside the escalation path, so a row in category `user` or `contact_other` naming `contact_alert` and any contact of any account would be sent: no incident, no gate, no settle delay, no Hold, and in one variant to suppressed or opted-out addresses. It needs write access as `afterme_api` (a leaked DSN, remote code execution or a future injection bug), but T2 and DATABASE §6 promised it could not.

**Fix (three locks, each tested alone).** Migration `0009`: the trigger allows the API role exactly the (category, audience, template) combinations it writes; a CHECK confines the alert templates to the escalation category for every role; `(contact_id, user_id)` is a same-owner foreign key. The dispatcher validates the shape of every row before any re-check (`unexpected_shape`), requires that an all-clear goes only to a contact who was messaged (`not_messaged`), and backs off a row whose processing raises instead of retrying it first on every pass (BD-4: a hundred such rows could starve real alerts). Tests: `tests/security/test_notification_boundary.py` (16 tests).

## 5. S3 findings

### 5.1 Fixed in Phase 9

| ID | Finding | Fix | Evidence |
|---|---|---|---|
| F3 | `/internal/probe` was rate limited before the token was compared: whoever shared the monitor's address could starve it into a Hold, which suppresses every real escalation | Token compared first; a wrong token spends its own budget (10/min), the right one a separate 60/min | `engine/test_hold.py::test_a_stranger_cannot_use_up_the_monitors_budget` |
| F5 | Email change completed inside the shared 5-minute window | `email/change/start` needs the password within the last 60 s | `test_email_change`, matrix |
| F6 | Email "normalisation" was `lower(strip)`: IDNA and Unicode spellings and composed/decomposed accents bypassed suppression, opt-out and per-address limits | One canonical form (ASCII IDNA domain, NFC local part) at validation and at lookup | `tests/unit/test_validation.py` |
| F7 | IPv4-mapped IPv6 clients collapsed into one `::/64` rate-limit bucket | Unwrapped to IPv4 | `test_an_ipv4_mapped_ipv6_address_is_the_ipv4_client` |
| F9 | `AFTERME_APP_ENV` defaulted to `dev`: a missing variable switched every production refusal off | Unset with no `.env` is refused; a `dev`/`test` process refuses a database that is not on this machine | `tests/unit/test_config.py` |
| F10 | A forwarded header with fewer entries than trusted hops put the client-written entry in charge | Such a header is ignored; the peer is used | `test_client_ip_uses_trusted_hops_from_the_right` |
| F11 | Unbounded pre-authentication Argon2 concurrency (64 MiB each): an out-of-memory kill is an outage | At most 2 × CPU at once, the rest wait | `PasswordHasher(max_concurrent=)` |
| F12 | Webhook secrets needed only 8 characters; a forged bounce suppresses an address globally | At least 32 characters for a Postmark password in staging/production | `test_notification_config.py` |
| F-01 | An I'M OK sent under the key of an I'M SAFE (or the reverse, or another incident) was answered `200` with the other operation's result and did nothing | `409 idempotency_key_reused`; nothing is presented as done that was not | `engine/test_idempotency_binding.py` |
| F22/F-07 | Production did not require TLS to the database | Refused unless `sslmode=require` or stronger (or a loopback proxy) | `tests/unit/test_config.py` |
| BD-17 | `LOG_LEVEL=DEBUG` accepted in staging/production | Refused | `tests/unit/test_config.py` |
| BD-7 | `afterme-admin void` voided the person's *current* open incident, not the one named | Acts only on the incident it names | `engine/test_hold.py::test_void_acts_only_on_the_incident_it_names` |
| BD-9 | `httpx` was a dev dependency but imported at start-up: an image built without dev dependencies could not start | Runtime dependency (`uv.lock` updated) | `uv lock --check` |
| BD-10/F-06 | The retention role could update any contact and insert any audit row | Triggers (0009): contacts only of `pending_deletion` accounts; audit only `account.purged` | `test_the_retention_role_scrubs_only_the_contacts_of_a_closed_account` |
| BD-11 | Trigger functions ran under the caller's `search_path` | Pinned `public, pg_temp` | migration 0009 |
| F-10 | gitleaks ran only for `backend/**` changes; no dependency-update automation; the mobile pipeline had no dependency audit | `security.yml` (every push and PR, weekly), `dependabot.yml`, `mobile/tool/audit_deps.dart` | CI configuration |

### 5.2 Mobile (M-01…M-04), fixed by the mobile pass

See §6.2.

### 5.3 Open S3 items, with the reason

| ID | Finding | Disposition |
|---|---|---|
| F4 | A stolen session is an uncapped password-guess oracle (5 per 15 min per session, no account cap, no alert) | Accepted for 1.0, SECURITY §18; recommended: an account-level reauth-failure budget that revokes the session and emails the owner |
| F8 | Instruction **text edits** and push-token removal need no password and leave no Activity entry | Accepted for 1.0, §18; recommended: user-visible `instruction.updated` plus a batched notice |
| BD-3 | The API role can write engine inputs (`next_due_at`, `status`, `grace_minutes`, `users.status`, `system_flags`) with no value guards | Needs a compromised API role; §18; recommended: BEFORE UPDATE guards and a reconciliation job |
| BD-5 | The worker keeps DML on the Phase 1 authentication tables and loads the KEK | §18; revoke what it never needs when the production role provisioning is written |
| BD-6 | Timezone, due time and reminder lead can be changed without a password | Same capability as I'M OK (which is deliberately free); §18 |
| BD-8 | About 26 throwaway accounts can open enough incidents to start the anomaly Hold (paged, not silent) | Free-tier abuse control and a manual-exit Hold are the answer; threshold review with real data |
| F-09 | "abuse@" is not in every contact email; the invitation links `/support`, which nothing serves | Needs the domain (owner item D1) |
| F-08 | Operator CLI: provider tests unaudited, `--operator` self-asserted, no `suspend` command | Operator identity comes from cloud IAM at deployment; add `suspend` with the production runbook |
| F-11 | `MIN_CLIENT_VERSION` is validated for shape only | Runbook item (deploy-time check) |
| F-02 | `release_events`, `portal_access`, `incident_actions` use single-column foreign keys to contacts | Worker-written only; portal joins mitigate; document or add composite keys |
| F-17 | All-clear and withdrawn-alert skip the owner-status check (a suspended account's contacts still get the undoing message) | Deliberate (fail-safe: an alarm should be taken back); SECURITY §13 wording corrected |

## 6. Mobile review

**No S1 or S2.** Tokens, the pending check-in record and the push token live in Keystore-backed storage; there are no logs, clipboard use or files; drafts are memory-only; the merged manifest matches the permission allowlist; backup is fully excluded; refresh and reauth are sound; the shipped `libapp.so` is obfuscated and stripped.

### 6.1 MASVS L1

| Area | Result |
|---|---|
| STORAGE | Pass (verified statically; app-data inspection on a device is still manual) |
| CRYPTO | Pass (no custom crypto) |
| AUTH | Pass; app lock is local convenience only, step-up is server-side |
| NETWORK | Pass with a correction: Android's `network_security_config` does **not** bind `dart:io`; the real guard is the build configuration check in `AppConfig`, now also paired with the flavor |
| PLATFORM | Pass after M-02 |
| CODE | Pass after M-04 |
| RESILIENCE | Not targeted for 1.0 |
| PRIVACY | Pass; no crash-reporting SDK is integrated (the documentation said otherwise) |

### 6.2 S3 findings

| ID | Finding | Disposition |
|---|---|---|
| M-01 | The documented OS-level cleartext/CA control does not apply to the app's HTTP stack | Guard in code (https outside the dev flavor, flavor ↔ environment pairing), documents corrected |
| M-02 | The exported `MainActivity` accepted Flutter engine extras and intent data as a route from any app | Overridden; `flutter_deeplinking_enabled=false`; router ignores the platform location; manifest check asserts it |
| M-03 | No local protection of instruction text when app lock is off or unavailable | Closed by 4.2: reading needs the password on every phone |
| M-04 | Release hardening was a README recipe | `tool/build_release.sh`; CI release build is obfuscated; manifest assertions |

## 7. Decisions for the owner

### 7.1 Certificate pinning: **recommend not in 1.0**

Dio ignores Android's pin-set, so pinning would be hand-written Dart; leaf pins are impossible with Google-managed certificates; intermediate or root pins can brick every installed client when the chain changes, and a bricked client never receives the `426` that is supposed to rescue it. The failure mode is the worst one for this product: a phone that cannot reach the server cannot check in, and contacts get a false alarm. The benefit is protection against a CA mis-issuing a certificate for the API's name. Instead: CAA records, Certificate Transparency monitoring, HSTS preload, and the https/flavor guard. Revisit only with time-boxed, report-only pins from two CA lineages.

### 7.2 Device-bound biometric step-up for I'M SAFE: **recommend not as a bespoke key**

The lost-phone path (`/a/login` + `/a/safe`) is password-only by design, so a device key cannot be required, and any enrolled fingerprint satisfies a biometric-bound key. Deliver it as **passkeys with TOTP in 1.1**, where it also closes the email-takeover residual risk.

### 7.3 An AfterMe PIN for phones with no screen lock: **recommend not in 1.0**

A PIN would protect only the local read surface (instruction text, contacts, I'M OK in grace): writes, I'M SAFE, export and delete are already server-gated. With 4.2 the instruction text now needs the password on every phone, which is stronger than a local PIN. Remaining low-cost work: a persistent Home nudge and re-offering the app lock in onboarding when the phone has no screen lock.

### 7.4 Reading instructions needs a recent password: **implemented; please confirm or revert**

This was open since Phase 6. Both reviews rated the status quo S2, and the exit criterion required it closed, so I implemented the recommended option. To revert, change `ReauthUserDep` back to `CurrentUserDep` on the two `GET` routes in `app/instructions/router.py` and remove the matching mobile prompt; the audit row can stay.

### 7.5 Still open from earlier phases

Cloud KMS adapter and per-user key rotation (production refuses the local KMS, so production cannot start without it); email provider choice, sending-domain DNS, Firebase projects and staging environment; review of the new email copy (withdrawn alert, contact unreachable, deletion notices).

## 8. Residual risks added to SECURITY §18

See [SECURITY §18](SECURITY.md#18-accepted-residual-risks-10): targeted degradation of password sign-in by a persistent multi-network attacker; stolen-session password guessing (F4); content edits without a password (F8); engine inputs writable by a compromised API role (BD-3); worker role breadth (BD-5); no crash-reporting integration; operator identity is self-asserted until IAM supplies it.

## 9. Recommendation: external penetration test before public launch

Do it after Phase 10's closed beta is stable and before production, against **staging with real providers**, with these in scope: the authentication and step-up matrix (§7 of SECURITY) including the lost-phone pages; the contact portal (link → code → content) and its revocation; webhook authentication; the instruction cryptography and the three decrypt sites; the deployed database role boundary (the review here is from migrations, not from a live instance); rate-limit and client-IP behaviour behind the real ingress; the Android build (release APK, intent surface, FLAG_SECURE, backup, deep links). Out of scope: Google, the email provider. Ask for the report to be written against the threat table T1–T41.

## 10. What this review could not check

FLAG_SECURE in recents and screenshots, the SAF export picker, BiometricPrompt across OEMs, push delivery and lock-screen rendering, logcat during a full flow, and app-data inspection need a physical phone. Database TLS, trusted-proxy hop count, uvicorn proxy-header flags, CAA and the cloud KMS exist only on deployment. Provider error names (Resend, Postmark) were taken from documentation and are to be confirmed on the first live run.

## 11. Evidence

All commands were run from the repository, with exit codes captured to files (never read through a pipe), on 2026-10-12.

| Gate | Result |
|---|---|
| Backend `pytest --cov=app` (the whole suite, the project test database) | **2055 passed, 1 skipped** (the walkthrough writer), exit 0; coverage **96.35 %** against the 85 % gate. Phase 8 ended at 1851: +204 tests |
| Backend `ruff check` / `ruff format --check` / `mypy app` | exit 0 / exit 0 (290 files) / exit 0 (157 files, strict) |
| Backend dependency audit (`scripts/audit_deps.py`) / `uv lock --check` | 81 packages, no known vulnerabilities, exit 0 / exit 0 |
| Migration round trip, schema drift, grants (`tests/security/test_migrations.py`, `test_db_grants.py`) | pass, with `0009` and the allow-list-versus-code comparison |
| Mobile `flutter analyze` / `dart format --set-exit-if-changed` | no issues, exit 0 / 376 files, 0 changed, exit 0 |
| Mobile `flutter test --coverage` | **3415 passed**, exit 0 (Phase 8: 3349; +66) |
| Mobile `tool/coverage_check.dart` | every gate passes; `lib/` 98.6 % |
| Mobile `tool/audit_deps.dart` (OSV over `pubspec.lock`) | 157 hosted packages, no advisories, exit 0 |
| Release build through `tool/build_release.sh --apk --allow-debug-signing` and the merged-manifest check | built, R8 on, obfuscated; the manifest check passes and was shown to fail on doctored manifests (deep links on, an extra exported service, `allowBackup` true) |
| Emulator integration suite (`mobile/tool/integration.sh`, MOB-61…65 against the real backend with the test clock) | **5 of 5 PASS**, exit 0 (§11.1) |

### 11.1 Emulator integration

`mobile/tool/integration.sh` (throwaway database `afterme_it`; the API and the worker from this tree, test clock on; emulator AfterMe_API_36): **MOB-61 onboarding, MOB-62 check-in, MOB-63 missed → grace, MOB-64 escalation → I'M SAFE, MOB-65 export and delete all PASS**, exit 0. This is the only check made here that the app still cold-launches with the hand-written activity fragment (M-02) and that the whole stack agrees after the login, step-up, dispatcher and canonical-email changes; it was run once, on a debug dev build. What it cannot show is on the list in §10.

### 11.2 Tests added in this phase

`tests/security/test_log_leak_lifecycle.py` (whole-lifecycle log and operator-table leak test), `test_notification_boundary.py` (16: the three locks of finding 4.3, the poison-row back-off, the retention role guards), thirteen `test_sec_*` files and a larger authorization-matrix registry (from the SEC pass: 631 tests in `tests/security`), `engine/test_idempotency_binding.py`, the locked-account parity test in `test_timing_parity.py`, the per-network budget and recovery tests in `test_rate_limits.py`, the instruction-read step-up and audit test, canonical-email and look-alike-name tests, the production refusals in `test_config.py`; on the phone 66 tests (build identity pairing, manifest hardening, password-gated reads, FLAG_SECURE on password screens, two accessibility-matrix screens).

### 11.3 Process note

Two Claude sessions worked in this tree for part of the phase (a second interactive session was started on the same instruction, and each launched its own test-writing agent). Several pytest runs shared one database and corrupted each other; those runs were discarded and every result above comes from a run on a database nobody else touched. The result is two overlapping sets of SEC-21/22/23/26 tests, both passing, that can be merged.
