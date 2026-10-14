# AfterMe — Security & Privacy

| | |
|---|---|
| **Status** | Draft v0.1 — awaiting product-owner approval |
| **Baselines** | OWASP ASVS 4.x Level 2 (API & web), OWASP MASVS Level 1 (+ selected L2 storage controls) (app), OWASP API Security Top 10 (2023) |
| **Related** | [ARCHITECTURE](ARCHITECTURE.md) · [ESCALATION_ENGINE](ESCALATION_ENGINE.md) · [DATABASE](DATABASE.md) · [TEST_PLAN §5](TEST_PLAN.md#5-security-and-authorization-tests) |

---

## 1. Security goals

1. **No unauthorized disclosure.** A user's data is visible only to that user, and to the specific contacts they chose, at the time they chose.
2. **No unauthorized or accidental release.** Releases happen only through the engine, and only when the user's rules are met ([ESCALATION_ENGINE §2](ESCALATION_ENGINE.md#2-safety-invariants)).
3. **No silent suppression.** Nobody but the authenticated, re-verified user can stop an escalation.
4. **Minimal blast radius.** A leaked database dump, log file, backup or notification exposes as little as possible.

## 2. Assets

| Class | Assets |
|---|---|
| **Critical** | Instruction content; per-user data-encryption keys and KMS permissions; JWT signing keys; refresh tokens; portal link tokens and OTPs; password hashes; HMAC pepper |
| **Sensitive** | User PII (name, email, phone, timezone); contact PII; check-in history (reveals daily patterns); incident and release history; push tokens |
| **Internal** | Audit metadata, device/app versions, operational metrics |
| **Public** | Category list, legal pages, marketing content |

## 3. Threat actors

| Actor | Example goals |
|---|---|
| Anonymous internet attacker | Account takeover, scraping, DoS, abusing invitation emails |
| Malicious authenticated user | Read or modify **other** users' data (IDOR), forge releases, spam people |
| Someone with the user's phone (locked or unlocked) | Fake check-ins, cancel an escalation, read instructions |
| Someone with access to the user's email | Password reset → takeover |
| Someone with access to a contact's email | Read released instructions |
| A contact acting maliciously | Try to obtain information early or beyond what was released |
| Insider / compromised cloud credentials | Bulk data access |
| Compromised third-party provider | Read message metadata, inject messages |
| Network attacker | Intercept or modify traffic |

## 4. Trust boundaries

```
[Android app] ──TLS──▶ [Ingress/LB] ──▶ [api] ──TLS──▶ [PostgreSQL]
      ▲                                  │   └────────▶ [KMS]
      │ push (untrusted payload)         │
[FCM] ◀──── [worker/dispatcher] ─────────┘──▶ [Email provider] ──▶ [Contact inbox] ──▶ [Portal (browser)]
```

1. **Everything from the client is untrusted.** That includes IDs, times, states, push contents echoed back, and the app version claim.
2. **Push payloads carry no authority.** The app always fetches state from the API.
3. **Email is a weak channel.** Links and codes travel through inboxes; content never does.
4. **The `api` process is less trusted than the `worker`** for escalation: it cannot create incidents, actions or releases (DB grants, [DATABASE §6](DATABASE.md#6-database-roles-and-grants)).

## 5. Threats and controls

| # | Threat | Controls |
|---|---|---|
| T1 | IDOR / cross-user access | Owner-scoped repositories (no unscoped `get`); `404` for not-owned; composite same-owner FKs in the DB; authorization-matrix test over **every** route |
| T2 | Forcing a release through the API | No such endpoint (API §15); the API DB role lacks `INSERT` on incidents, actions, releases and portal access; the dispatcher only sends escalation messages linked to an executed stage action; engine gate **Phase 9:** a trigger limits what the API role may insert into `notifications` to the (category, audience, template) combinations it really writes; a CHECK confines the two alert templates to the escalation category for every role; `(contact_id, user_id)` is a same-owner foreign key; and the dispatcher validates the shape of every row again, and that an all-clear goes only to a contact who was messaged, before any other re-check. |
| T3 | Tampering with escalation timing from the client | All deadlines and offsets are computed server-side; `extra="forbid"`; client times ignored; plan rules validated server-side and re-validated by the gate |
| T4 | Credential stuffing / brute force | Argon2id; per-IP and per-account rate limits; lockout with security email; common-password blocklist; generic errors **Phase 9:** the hard failure budget is per (account, network), so a stranger who knows an address spends only their own network's budget; the account lock after 10 consecutive failures is answered like a wrong password and does not bind a device the account already knows. Residual risk: §18. |
| T5 | Refresh-token theft | Keystore-backed storage; rotation on every use; reuse detection revokes the session; sessions listed and revocable |
| T6 | Access-token theft | 15-min lifetime; session validity checked on every request; TLS only |
| T7 | Request replay | Idempotency keys (check-in/safe); short token lifetime; TLS. Replaying a check-in can only *delay* escalation, and a replayed I'M SAFE needs a fresh re-auth window. **Phase 9:** a key replays only the operation (and, for I'M SAFE, the incident) it was first used for; any other use is `409 idempotency_key_reused`, never another operation's result. |
| T8 | Unlocked or stolen phone used to check in or cancel | App lock (biometric / device credential); **password re-auth** for I'M SAFE, deactivate, export, delete; remote session revocation via web **Phase 9:** reading instructions needs the password entered in the last five minutes and is audited (`instruction.viewed`); starting an email change needs it within the last minute. |
| T9 | Takeover via the user's email (password reset) | Security emails on reset/login/email change; reset revokes all sessions; TOTP/passkeys planned for 1.1. **Residual risk for 1.0.** |
| T10 | Contact's email compromised → reads released content | OTP to the same inbox (limited help); releases ≥ 24 h after the miss; revocation on I'M SAFE; views audited and shown to the user. **Residual risk** (§18). |
| T11 | Email link scanners trigger actions | GET never changes state; actions need a POST with CSRF; content needs an OTP |
| T12 | Token leakage via logs or Referer | Tokens only in URL fragments; `Referrer-Policy: no-referrer`; log redaction; access logs without query strings |
| T13 | Sensitive data in logs or crash reports | Redaction processor; no bodies logged; error-monitoring scrubbing; automated log-leak tests |
| T14 | Database or backup leak | Instruction content encrypted with per-user DEKs (KMS-wrapped); tokens stored as hashes; low-entropy values HMAC'd with a pepper; managed at-rest encryption |
| T15 | Insider / cloud credential misuse | Least-privilege IAM; MFA on cloud accounts; KMS decrypt audit logs; no admin UI; operator actions via audited CLI; separate prod project |
| T16 | Invitation spam / harassment | Verified-email signup; invitation rate limits; consent required; opt-out in every email; global "never contact me" list; abuse report address |
| T17 | OTP / code brute force | 6 digits, 5 attempts per challenge, 10–15 min expiry, send limits. Worst case ≈ 5×10⁻⁶ success per challenge, ≤ 3 challenges/hour. |
| T18 | Account enumeration | Identical responses for register/forgot; generic login errors; timing equalised (dummy Argon2 verification for unknown emails) **Phase 9:** a locked account is answered like a wrong password (same work, same `401`, no `Retry-After`); email addresses are compared in one canonical spelling (IDNA domain, NFC). |
| T19 | Injection (SQL/template/header) | SQLAlchemy parameters only (no string SQL); Jinja autoescape; strict Pydantic types; email header values sanitised |
| T20 | DoS / resource exhaustion | Rate limits; body-size limits; pagination caps; DB statement timeouts; ingress-level protection (Cloud Armor or equivalent) when exposed publicly |
| T21 | Push spoofing | Payloads are hints only; no actions taken from payload content |
| T22 | Supply chain | Locked dependencies (uv.lock, pubspec.lock); pip-audit / OSV scanning in CI; Dependabot/Renovate; Play App Signing; protected CI secrets; minimal third-party SDKs |
| T23 | Mass wrongful escalation from an outage or bug | Hold circuit breaker; anomaly detection; settle delay; operator kill switch |
| T24 | Clickjacking (portal) | `frame-ancestors 'none'` |
| T25 | XSS via instruction content in the portal | Content rendered as escaped plain text (`white-space: pre-wrap`); no HTML/Markdown rendering in 1.0; strict CSP with nonces |
| T26 | Phishing via display names ("AfterMe Security") | Display-name validation (no URLs or lookalike brand terms); emails always attribute "sent by AfterMe on behalf of *Name* (*email*)"; fixed templates; DMARC enforcement |
| T27 | Lost-phone web pages (`/a/login`, `/a/checkin`, `/a/safe`) used to check in or cancel | The app's sign-in, lockout and per-network budget; a 1 h `web` session in a `__Host-` cookie (only its SHA-256 stored); CSRF double submit on every POST; the password for I'M SAFE; the owner is emailed on every web sign-in and sees it in Activity. Tests: `test_web_checkin`, SEC-13/14 |
| T28 | Data export used to read everything at once | Password entered in the last 60 s and spent by the export; 3 an hour; `no-store`; audited. Reading instructions one by one needs the 5-minute window too, so the export is not the weaker door |
| T29 | Account deletion raced against an incident, or used as a weapon | Password within 60 s plus the typed word; one transaction under the per-user lock; contacts already told get a withdrawn-alert (never an all-clear); the wrapped key is deleted; guard triggers refuse new contacts/instructions/keys for a closed account; the purge is a separate role |
| T30 | Test support (`/test/*`) enabled where it can alert real people | Refused in production by configuration; a 32-byte token; a development email provider only; the router guard fails closed. SEC-23 |
| T31 | Forged or replayed provider webhooks (suppression, complaint, opt-out) | Svix HMAC with a 5-minute window, or a Postmark password of at least 32 characters; idempotent per event id; an event is applied only to a contact that still has the address; bare `401`/`404` |
| T32 | Global suppression used as a lever against someone else's contact | Only the mailbox's own webhook word suppresses; owners are told. Accepted: a stranger can add a victim's address as a contact to induce a "never contact me" (abuse playbook) |
| T33 | Push-token takeover; a push to a stranger's phone | One holder per token; cleared on logout, deletion and FCM `UNREGISTERED`; generic payloads; never logged |
| T34 | Activity feed as a side channel | Per-action metadata allow-list; owner-scoped; entry ids come from a global sequence (accepted, §18) |
| T35 | The fallback email provider delivering twice, or a provider's configuration error read as a verdict on a contact | A provider's "permanent" is not final until the other refuses; failure kinds; at-least-once is the intended direction of error |
| T36 | Compromise of the retention job | Its own role; DELETE only of accounts in `pending_deletion` (trigger); UPDATE of contacts only for such accounts (trigger, Phase 9); audit INSERT only `account.purged` (trigger, Phase 9) |
| T37 | Operator CLI misuse | Runs with the worker credentials from cloud IAM; commands audited (`operator.*`); `void` acts only on the incident it names (Phase 9). `user suspend|unsuspend|set-tier` are audited with the operator's free-text reason (at most 200 printable characters, never logged, `user_visible=false`). Provider tests are unaudited and `--operator` is self-asserted (accepted, §18) |
| T38 | The 426 upgrade gate used to lock people out | `MIN_CLIENT_VERSION` is shape-validated; the web check-in remains; a deploy-time check belongs in the runbook |
| T39 | The idempotency store used to replay another operation's result | Key bound to user, operation and incident (Phase 9) |
| T40 | Targeted denial of sign-in or recovery for a known address | Per-(account, network) budgets; the account lock does not bind a known device; recovery budgets per (address, network) with a higher ceiling across networks. Residual: §18 |
| T41 | Database links without TLS; a proxy count that lets clients choose their address | Production refuses database URLs without `sslmode=require` or stronger (unless a local proxy); a forwarded header with fewer entries than trusted hops is ignored; IPv4-mapped IPv6 addresses are unwrapped |

## 6. Cryptography

### 6.1 In transit
- TLS 1.2+ (prefer 1.3) for all public endpoints, with HSTS. Android's `network_security_config` (no cleartext, system CAs only, the dev flavor allowing the emulator host) governs the platform stack (browser hand-offs, Firebase and Google Play services) and keeps user-installed CAs out; **it does not bind `dart:io`, which carries the app's API traffic** (confirmed in Phase 9 against the Flutter 3.47.6 embedder). For API traffic the enforcement is in the app: `AppConfig` refuses a non-https base URL outside the dev flavor and a development-looking host in staging or prod, the flavor (package suffix) must agree with `APP_ENV` or the app shows a "misconfigured build" page without making a call, and the app runs in a zone with `#flutter.io.allow_http` set to the dev flavor only.
- Database connections use TLS (`sslmode=verify-full` where the provider supports it).
- **No certificate pinning in 1.0 (Phase 9 decision, recommended to the owner).** Dio ignores Android's pin-set, so pinning would be hand-written Dart; leaf pins are impossible with Google-managed certificates; intermediate or root pins can brick every installed client when the chain changes, and a bricked client never receives the `426` that is meant to rescue it: a phone that cannot reach the server cannot check in, and the contacts get a false alarm. The benefit is protection against a CA mis-issuing a certificate for the API's name. Instead: CAA records, Certificate Transparency monitoring, HSTS preload, and the https/flavor guard in the app. Revisit only with time-boxed, report-only pins from two CA lineages.

### 6.2 Instruction content (envelope encryption)

```
KMS KEK (never leaves KMS)
   └─ wraps → per-user DEK (256-bit, random)  stored wrapped in user_keys
                 └─ encrypts → instruction content {title, body}
```

- Algorithm: **AES-256-GCM** with a random 96-bit nonce per encryption.
- Stored format: `0x01 ‖ nonce(12) ‖ ciphertext ‖ tag(16)`.
- **AAD** = `"afterme/instruction/v1|{user_id}|{instruction_id}|{content_key_version}"`. This binds each ciphertext to its row and owner, so a swapped or copied ciphertext fails to decrypt.
- KMS wrap/unwrap also passes `user_id` as additional authenticated data.
- Unwrapped DEKs are cached in process memory for ≤ 5 min. They are never logged and never persisted.
- Rotation: KEK via KMS key versions (DEKs re-wrapped by a batch job); DEK per user on demand (re-encrypt that user's instructions).
- Decryption happens only for: the owner's API requests, the portal for an OTP-verified contact viewing an eligible release, and the owner's data export.

**Phase 6, implemented.** `app/security/envelope.py` (AES-256-GCM, the stored format and AAD above), `kms.py` (the `KmsProvider` interface and `LocalKms`) and `vault.py` (seal/open with the per-user key, created on a user's first instruction and cached unwrapped for at most 5 minutes in process memory).
* **Production and staging (Phase 12): Cloud KMS.** `KMS_PROVIDER=gcp_kms` (`app/security/gcp_kms.py`): the KEK is the CryptoKey `instruction-kek` in Cloud KMS and never leaves it; only the API service account holds EncrypterDecrypter on it. The wrapped DEK carries `gcp:<CryptoKey name>` (not a version: Cloud KMS records the version inside the ciphertext) and is bound to the user by AAD inside the KMS. Every call has a 3 s ceiling, CRC32C checks both ways, and every failure is one `kms.call_failed` log line with a short code (never a key name or bytes), which pages ([DEPLOYMENT §7](DEPLOYMENT.md#7-monitoring-and-alerting)); a KMS failure answers "temporarily unavailable" (`503` + `Retry-After`), including the creation of a person's first key.
* **Rotation in production** ([DEPLOYMENT §9](DEPLOYMENT.md#9-runbooks), Key management; the Cloud Run job `afterme-kms`, run as the API service account): the KEK rotates **automatically every 90 days** (a new primary version; old versions keep decrypting); `cli.admin kms rewrap` then rewrites every wrapped DEK under the primary version, and an old version is disabled only after a rewrap reported `"complete": true`. A per-user DEK rotation (`kms rotate-user`, a suspected exposure of one account) re-encrypts that person's instructions in one transaction and bumps `dek_version` (a database trigger allows +1 only).
* **Development and tests only:** `KMS_PROVIDER=local` keeps the KEK in the environment (`KMS_LOCAL_KEY`, ids `local-<12 hex>`, an optional `KMS_LOCAL_KEY_PREVIOUS` while rewrapping). It is **refused in staging and production**.
* Only the API process holds keys: `afterme_worker` has no privilege on `user_keys` and cannot select `instructions.content_ciphertext`, so the engine decides releases without ever being able to read one.
* A ciphertext copied to another row, another user, or another key version fails to decrypt (tests `test_a_ciphertext_moved_to_another_*`); the failure is a generic `500` that names nothing.
* Implemented since (Phase 12): per-user DEK rotation and the KEK re-wrap job (`app/ops/kms.py`, above), and the data export.

### 6.3 Secrets and hashes

| Secret | Generation | Storage |
|---|---|---|
| Password | user-chosen | Argon2id (OWASP-recommended parameters, tuned to ~100–250 ms on prod hardware; rehash on login when parameters change) |
| Refresh/link/portal/session tokens | `secrets.token_urlsafe(32)` (256-bit) | SHA-256 hash |
| 6-digit codes / OTPs | CSPRNG | HMAC-SHA256(pepper, context ‖ code) |
| IPs, suppressed emails | — | HMAC-SHA256(pepper, value) |
| JWT signing | Ed25519 key pair, `kid` header, two active keys during rotation | Secret manager |

JWT validation uses an algorithm allow-list (`EdDSA` only) and checks `iss`, `aud`, `exp`, `iat` and `sid`.

### 6.4 Honest limitation: not end-to-end encrypted

The server **can** decrypt instruction content, because it must deliver that content to contacts while the user is unreachable, and contacts don't have the app. Therefore:
- Marketing and store copy say **"encrypted in transit and at rest"**. They **never** say "zero-knowledge" or "end-to-end encrypted".
- In-app guidance discourages storing passwords (FR-INS-07).
- A future **E2EE mode** (2.x): contacts install AfterMe, and keys are exchanged during acceptance (similar to password-manager emergency access).

## 7. Authentication and sessions

| Control | Value |
|---|---|
| Password rules | 10–128 chars; any Unicode (NFKC-normalised); common-password blocklist; no composition rules; no forced rotation |
| Signup | Emailed 6-digit code before the account exists in usable form |
| Access token | 15 min, EdDSA JWT; carries `sid`, which is checked against `sessions` on every request |
| Refresh token | Opaque, rotated on every use; 30 s network-retry grace; otherwise reuse revokes the session |
| App session | Idle 60 days, absolute 365 days |
| Web session | 1 h; `__Host-` cookie; counts as re-auth for 5 min after password login |
| Re-auth (step-up) | Password, valid 5 min: **reading an instruction or the list of them** (Phase 9: the text is decrypted for the response, and without this the export's 60-second rule protected nothing), I'M SAFE, deactivate check-ins, **lengthen the interval of an active schedule** (Phase 4, owner decision 2026-10-10), **change the plan while the schedule is active, remove or deactivate a contact who is in a plan stage or is a recipient, or change that contact's email, change who receives an instruction, or switch off or delete an instruction that has recipients** (Phase 5 review F-12, owner decision 2026-10-10; Phase 6 review F5), export and delete account (the password within the last **60 seconds**, spent by the export), change email (the password within the last 60 seconds to start it; Phase 9) |
| Lockout | Failed sign-ins are budgeted per **(account, network)**, 5 per 15 min, so a stranger who knows an address spends only their own network's budget (Phase 9). 10 consecutive failures → 15 min account lock + security email, for guessing spread over many networks. While locked, a sign-in from a device the account does not know is answered exactly like a wrong password (same work, `401`, no `Retry-After`: nothing says the address exists or is locked), and a sign-in from a device the account already knows is not bound by the lock. Recovery and signup budgets are per (address, network) with a higher ceiling across networks |
| Security emails | New-device login, password changed/reset, email changed, refresh reuse detected, all sessions revoked, deletion requested |
| Planned (1.1) | TOTP / passkeys; Google Sign-In; device-bound biometric key as an alternative step-up for I'M SAFE (Phase 9: **not as a bespoke key**, because the lost-phone path is password-only by design and any enrolled fingerprint satisfies a biometric-bound key; deliver it as passkeys alongside TOTP) |

## 8. Authorization

- **Ownership:** every user-owned query includes `user_id = :current_user`. Repositories make an unscoped lookup impossible to write by accident. A not-owned resource returns `404`.
- **Database-level same-owner guarantees:** composite FKs prevent linking user A's instruction to user B's contact or stage.
- **Role separation:** `afterme_api` vs `afterme_worker` grants ([DATABASE §6](DATABASE.md#6-database-roles-and-grants)).
- **Portal scope:** a portal session is bound to exactly one `(incident, contact)` and sees only that pair's non-revoked, visible releases.
- **Entitlements:** tier limits enforced in services, never trusted from the client.
- **Operators:** no in-app admin role in 1.0. Operations run via the `afterme-admin` CLI using cloud IAM, and every command is audited.

## 9. Audit logging

Append-only (`INSERT`/`SELECT` grants only). `user_visible` marks events shown in the Activity feed (✓).

| Area | Actions |
|---|---|
| Auth | `auth.web_login_succeeded` ✓ (the lost-phone page, `/a/login`), `auth.signup_started`, `auth.signup_verified`, `auth.login_succeeded` ✓(new device), `auth.login_failed`, `auth.locked`, `auth.logout`, `auth.logout_all` ✓, `auth.refresh_reuse_detected` ✓, `auth.reauth_succeeded`, `auth.reauth_failed`, `auth.password_changed` ✓, `auth.password_reset_requested`, `auth.password_reset_completed` ✓, `auth.email_change_requested`, `auth.email_changed` ✓, `session.revoked` |
| Profile | `profile.updated`, `profile.timezone_changed` ✓ |
| Contacts | `contact.created` ✓, `contact.updated`, `contact.deleted` ✓, `contact.invitation_sent` ✓, `contact.accepted` ✓, `contact.declined` ✓, `contact.opted_out` ✓, `contact.bounced` ✓ |
| Check-in | `schedule.updated` ✓, `schedule.activated` ✓, `schedule.deactivated` ✓, `checkin.recorded` ✓ |
| Plan / instructions | `plan.updated` ✓, `instruction.created`, `instruction.updated`, `instruction.deleted`, `instruction.viewed` (Phase 9: every read, a count, never text, not shown in Activity), `instruction.recipients_changed` ✓ |
| Escalation | `incident.opened` ✓, `incident.resolved` ✓, `incident.cancelled` ✓, `incident.voided` ✓, `escalation.reminder_sent`, `escalation.final_warning_sent` ✓, `escalation.stage_executed` ✓, `escalation.action_held` |
| Release / portal | `release.created` ✓, `release.revoked` ✓, `release.viewed` ✓, `portal.session_created`, `portal.otp_sent`, `portal.otp_verified`, `portal.otp_failed`, `portal.new_link_requested`, `portal.access_denied` (reserved) |
| Notifications | `notification.sent` / `notification.failed` (contact-facing only) |
| Data | `account.exported` ✓ (was `export.created`), `account.deletion_requested` (not shown: the account is closed), `account.purged` (written by the retention job, `INSERT` only) |
| System / operator | `system.hold_entered`, `system.hold_exited`, `system.consistency_violation`, `operator.<command>` |
| Billing | `billing.subscription_changed` ✓ |

Metadata contains IDs, reason codes and counts only. **Never** content, names, addresses, tokens, codes or passwords. The one exception is the operator's own free-text reason on the `operator.*` actions (at most 200 printable characters, one line, validated at write time, `user_visible=false`, never logged): it is written by the person running the command, not taken from user data.

## 10. Logging and leakage prevention

- Structured JSON logs with a redaction processor (denylist keys + value-pattern masking for emails and tokens).
- Request/response bodies are never logged. Access logs record the route template (`/v1/contacts/{id}`), not the raw URL.
- Exceptions are logged by class and safe message. Errors from the DB driver that echo parameters are wrapped.
- Error monitoring: `send_default_pii=False`, scrubbing hook, no breadcrumbs from HTTP bodies, release/env tags.
- Mobile: no `print`/`debugPrint` of models in release builds (lint rule); Sentry Flutter with scrubbing (**not integrated yet**: no crash-reporting SDK ships in 1.0, see §18); FLAG_SECURE on sensitive screens.
- **Automated leak test:** the full lifecycle e2e test captures all log output and fails if any known secret value (password, token, OTP, instruction title/body, contact email) appears.

## 11. Mobile app (MASVS L1)

| MASVS area | Controls |
|---|---|
| STORAGE | Tokens and the pending check-in record (opaque account id, random key, tap time) in Keystore-backed secure storage; nothing sensitive in `shared_preferences`, files or logs; instruction content never persisted; `allowBackup="false"`; FLAG_SECURE on instruction screens (**Phase 6**) and, since Phase 9, on the export and delete-account screens and every password-entry screen and sheet, and, since Phase 10, on the contact add/detail/edit screens and wherever an instruction title is shown (Home, plan editor, Activity, incident screens) (a MethodChannel `app.afterme/secure_screen`, reference counted, follows what is shown) |
| CRYPTO | No custom crypto; platform Keystore via plugin |
| AUTH | All authorization server-side; app lock is local convenience security (the prompt accepts weak or strong biometrics or the device credential: `local_auth` offers no class-3-only option, and narrowing it could lock a person out of their own check-in); step-up via server password re-auth, including **reading** instructions (Phase 9) |
| NETWORK | HTTPS only, enforced in the app (see §6.1): `AppConfig`, the flavor/`APP_ENV` pairing and the `allow_http` zone; the platform's `network_security_config` for the platform stack; platform CA trust, no user-installed CAs; no certificate pinning (§6.1) |
| PLATFORM | Minimal permissions (INTERNET, POST_NOTIFICATIONS, USE_BIOMETRIC); **no** READ_CONTACTS (system picker); no WebViews; only the launcher activity and the two FCM receivers (guarded by `com.google.android.c2dm.permission.SEND`) exported, plus AndroidX's profile installer (`ProfileInstallReceiver`, guarded by `DUMP`); **no deep links**: `flutter_deeplinking_enabled=false`, the launcher activity ignores intent extras and data for routes and engine selection, and the router never takes the platform's initial location (Phase 9, M-02); notification taps are routed by the app from the FCM `data` payload. `tool/check_manifest_permissions.dart` asserts the exported set, `allowBackup`, cleartext and `debuggable` on every CI build |
| CODE | Release builds through `tool/build_release.sh`, which enforces `--obfuscate --split-debug-info`, requires `android/key.properties` (the debug-key fallback only with `--allow-debug-signing`, which CI uses, loudly), `APP_ENV=prod` and an https API URL, and runs the manifest check; R8 minification and resource shrinking explicit; dependencies pinned and scanned (pub and pip against OSV in CI; Gradle/Maven by Dependabot only); minSdk 26 |
| RESILIENCE | Not targeted for 1.0 (no root detection). Play Integrity API to be evaluated for signup abuse in 1.1. |
| PRIVACY | No ads or analytics SDKs; minimal data; in-app export and deletion |

## 12. Web portal

- Headers: `Content-Security-Policy: default-src 'none'; script-src 'nonce-{n}'; style-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'`, plus HSTS, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, a minimal `Permissions-Policy`, `Cache-Control: no-store`, `X-Robots-Tag: noindex, nofollow`.
- Cookies: `__Host-` prefix, `Secure`, `HttpOnly`, `SameSite=Strict`, server-side session rows (hashed).
- CSRF: the double-submit pair (a `__Host-` cookie and a hidden field with the same random value, compared in constant time) on every POST; the portal session cookie is a separate, HttpOnly value.
- Every message to a contact shows who sent it (name + email), why they received it, and how to opt out.

**Phase 6, implemented (release pages).** A portal session is a random 256-bit value in a `__Host-` cookie, stored as SHA-256, valid 60 minutes, and is not enough to see content: the one-time code (HMAC under the pepper, bound to its challenge, five attempts counted *before* the comparison, 10 minutes, three sent per hour per access) elevates it for 15 minutes. Link tokens are random, 30 days, stored hashed, and minted by the dispatcher at send time, so the raw token exists only in the email. The portal re-checks the contact (verified, switched on, not suppressed or opted out), the account and the release (not revoked, past the settle delay, outside an unprocessed Hold window, instruction active) on **every** request; a link, a session or a code never outlives the state it was issued for. Instruction text appears only in the body of a successful view response, HTML-escaped (`white-space: pre-wrap`), never in a URL, header, log, audit record, email or push.

## 13. Abuse prevention

| Abuse | Control |
|---|---|
| Spamming arbitrary people with invitations | Verified-email accounts only; 10 invitations/day; 3 resends/contact/week; global suppression; complaint-rate monitoring |
| Using AfterMe to harass via "alerts" | Contacts must accept before any alert; opt-out at any time |
| Throwaway signups | Code verification; per-IP limits; Play Integrity (1.1) if needed |
| Abuse reports | `abuse@<domain>` in every contact email; operator can suspend an account (`users.status = 'suspended'` stops every contact-facing action: queued alerts are cancelled, reminders and portal pages stop, web sessions die. **The one thing it does not stop is taking an alarm back**: an all-clear or a withdrawn alert to a contact who was already told is still sent, because leaving someone alarmed is the worse outcome; Phase 9 decision, F-17). Operator commands (Phase 10, audited, `operator.*`): `python -m cli.admin user suspend <user-id> --reason "…"` (sets `suspended` and revokes every app and web session; it voids and sends nothing), `user unsuspend`, `user set-tier`. A suspended person's open incident cannot escalate further (the gates cancel its pending actions) and a deadline that passes meanwhile is not shifted: after `unsuspend` the next tick opens an incident with a full grace period (product decision still open) |

## 14. Privacy

### 14.1 Data inventory

| Data | Purpose | Shared with | Retention |
|---|---|---|---|
| Account (email, password hash) | Authentication | — | Until deletion (+30 d purge) |
| Profile (name, phone, country, timezone, language) | Personalisation; schedule; name shown to contacts | Contacts (name, email) | Until deletion |
| Contacts (name, relationship, email, phone) | Invitations, alerts, releases | Email provider (for delivery) | Until removed or account deletion |
| Instructions | Release to chosen contacts | **Chosen contacts, per the user's rules** | Until deleted |
| Check-in events | Core function; history | — | 400 days |
| Incidents, releases, views | Core function; user's history | — | Life of account |
| Device info, push token | Push delivery | Google (FCM) | Until logout/revocation |
| Diagnostics (crash reports) | Reliability | Error-monitoring provider (scrubbed) | Provider default (configure 30–90 d) |
| Purchase info | Entitlements | Google Play | Life of subscription + legal minimum |

### 14.2 Principles
- **No advertising, no data sale, no third-party analytics SDKs** in 1.0.
- Processors (cloud host, email provider, FCM, error monitoring, Google Play) are listed in the privacy policy, with data-processing terms in place.
- User rights: access/export (in-app), correction (in-app), deletion (in-app + web), withdrawal (contacts: opt-out).
- **Age:** 18+ only. Not directed at children.
- **Legal review required** before launch for the chosen markets: India DPDP Act 2023 and Rules, GDPR/UK GDPR, US state privacy laws as applicable ([PRD D3](PRD.md#15-decisions-needed-from-the-product-owner)).

## 15. Secure development lifecycle

- Branch protection; every change via PR with CI green; a security checklist in the PR template (authz, input validation, logging, migrations).
- CI gates: `ruff` (incl. security rules), `mypy`, `pytest` (incl. the authz matrix + leak test), `pip-audit`, `flutter analyze`, `flutter test`, secret scanning (gitleaks, `security.yml`: every push and pull request, and weekly), the mobile dependency audit against OSV (`tool/audit_deps.dart`), Dependabot for `uv`, `pub`, Gradle and Actions, lockfile integrity.
- Weekly dependency updates (Renovate/Dependabot); critical CVEs patched within 72 h.
- This threat model is updated whenever a feature changes trust boundaries.
- **Phase 9 (done 2026-10-12):** security review and test pass, written up in [SECURITY_REVIEW](SECURITY_REVIEW.md). An **external penetration test before public launch** is recommended; its scope is in that report (§9).

## 16. Operational security

- Separate cloud projects per environment; production access restricted to named people with MFA.
- Secrets only in the secret manager; rotated on personnel change and at least yearly (JWT keys, pepper with a dual-check window, probe token, provider keys).
- KMS key rotation enabled; decrypt operations logged.
- Backups encrypted, access-restricted, restore-tested quarterly ([DEPLOYMENT §6](DEPLOYMENT.md#6-backups-and-recovery)).

## 17. Incident response (summary)

1. **Contain:** enter Hold (stops all contact-facing actions), revoke affected sessions, rotate exposed keys and tokens, disable compromised provider credentials.
2. **Assess:** scope via audit logs, KMS logs and provider logs.
3. **Notify:** affected users, and regulators where the law requires it (e.g. GDPR 72 h; India DPDP breach-intimation rules) per the legal playbook prepared before launch.
4. **Recover and review:** fix, verify, exit Hold with shift, blameless post-mortem, update this document.

## 18. Accepted residual risks (1.0)

| Risk | Why accepted | Revisit |
|---|---|---|
| The server can decrypt instructions (not E2EE) | Required for release to non-app contacts | 2.x E2EE mode |
| Email-account compromise of the user → takeover | MFA not in 1.0 | 1.1 TOTP/passkeys |
| Email-account compromise of a contact → reads releases | Contacts have no app or second factor | SMS/WhatsApp second factor (1.1+) |
| Duplicate notifications in rare crash cases | At-least-once delivery at the provider boundary; never a *wrongful* message | Provider idempotency |
| No certificate pinning | Bricking risk is worse than the benefit for a single-backend app (Phase 9 decision) | Time-boxed report-only pins from two CA lineages, if ever |
| A persistent attacker with several networks who knows an address can keep the account lock on and degrade *password* sign-in from a new browser in 15-minute windows | Signed-in phones, known devices and recovery by email are unaffected, the owner is emailed when the lock engages, and any harder rule would let the same attacker lock the owner out outright | Passkeys (1.1); an emailed one-tap check-in link is a product decision |
| A stolen session can guess the password at 5 per 15 min per session without an alert (F4) | Needs a stolen refresh token; each guess needs the password to be the weak point | Account-level reauth-failure budget that revokes the session and emails the owner |
| A stolen access token can edit the text of an instruction that already has recipients, and remove the phone's push token, without the password (F8) | Same capability as I'M OK, which is deliberately free; the edit is audited | A user-visible `instruction.updated` and a batched notice; step-up for text edits of recipient-bearing instructions |
| A compromised `afterme_api` role can write engine inputs (`next_due_at`, `status`, `grace_minutes`, `users.status`, `system_flags`) (BD-3) | It cannot create incidents, actions, releases or messages (Phase 9, BD-1); timing writes need a compromised API role | Value-level guard triggers and a reconciliation job |
| The worker role keeps DML on authentication tables and loads the key-encryption key (BD-5) | Production role provisioning does not exist yet | Revoke what it never needs when it is written; load the KEK only in the API |
| Timezone, due time and reminder lead can be changed without a password (BD-6) | Bounded to one interval and the same capability as I'M OK | Revisit with real data |
| No crash-reporting integration, although the data-safety form and §10 assume one | Nothing is lost by its absence except visibility | Decide with the Play data-safety answers |
| Operator identity (`--operator`) is self-asserted; provider tests are unaudited | The CLI runs with cloud IAM credentials; named operators only | Take the identity from IAM at deployment |
| Someone holding an unlocked phone *and* knowing the password can cancel | Indistinguishable from the user | Duress features (2.x, if ever) |

## 19. Account export, deletion and the lost-phone pages (Phase 7)

* **Export** (`POST /v1/me/export`): behind a password entered in the last minute and spent by the export (the file holds the decrypted instructions; a confirmation made more than a minute earlier, for something else, does not count; one made within the last minute for something else does, because there is one confirmation time per session), 3 per hour, `Cache-Control: no-store`, audited. Nothing in it that could be used to sign in as the person or to read another account; a text that cannot be opened is listed as an error, not dropped.
* **Deletion** (`DELETE /v1/me` and the public `/a/delete`): one transaction under the per-user lock. What can reach another person stops at once (incident voided with an all-clear, schedule off, releases and portal access revoked, invitations dead); content is erased and the **wrapped key is deleted**, so a ciphertext that survives apart from its key cannot be opened (a pre-deletion database backup holds both: DATABASE §4's 35-day backup statement is the accurate one); sessions end; the address and password are overwritten. A contact that still has the undoing message queued (the withdrawn-alert message, or the all-clear) keeps its name and address until that message has left (the dispatcher never writes to a deleted contact, and an alarm must be answered); the retention job scrubs it then. The remaining rows are hard-deleted after `ACCOUNT_DELETION_DAYS` (30). The web page needs an emailed single-use link (30 minutes, the token in the URL fragment) **and** the password; it answers every address identically.
* **Retention job** (`afterme_maintenance`): `DELETE` on `users` and `SELECT` on three of its columns (no address, no hash), `UPDATE` of the personal columns of `trusted_contacts` only, `INSERT` (never `UPDATE`) on `audit_logs`. It has no access to instruction content, keys or tokens.
* **Lost-phone pages** (`/a/login`, `/a/checkin`, `/a/safe`): the API's sign-in with the same lockout and failure budget; a `web` session of one hour in a `__Host-` cookie (`HttpOnly`, `Secure`, `SameSite=Strict`, only its SHA-256 stored) with CSRF double submit on every POST; the owner is emailed on every web sign-in and sees it in Activity; I'M SAFE asks for the password (the budget of `/auth/reauth`) unless the sign-in itself was within five minutes. No bearer token or refresh token is ever issued to a browser.
* **Test support** (`/test/*`) exists only when explicitly enabled, is refused in production by configuration, always needs a 32-byte token (the router carries the guard, and it fails closed), and refuses to start with a real email provider (moving the clock opens incidents and alerts contacts for every account in the database). It can move the clock for the API and the worker (one `system_flags` row) and read the development mail files; it can read nothing else and writes no application data.

## 20. Notifications (Phase 8)

* **What a push contains.** A fixed generic title and body per type, a type, a protocol version and an optional incident id. No name, no time, no instruction content, no address; `visibility: PRIVATE`. The app takes only a route from it and fetches everything over the authenticated API (T21). A test asserts that no push payload and no rendered email across a whole released incident contains an instruction title or text.
* **Registration tokens** are credentials for "push to this phone": one holder at a time (registering a token takes it from any other device), cleared on logout, on notifications off, on account deletion and when FCM says it is unregistered. They are never logged or echoed.
* **Provider credentials** (`EMAIL_API_KEY`, `EMAIL_FALLBACK_API_KEY`, `EMAIL_WEBHOOK_SECRET`, `EMAIL_FALLBACK_WEBHOOK_SECRET`, `FCM_CREDENTIALS_JSON`) are secrets from the secret manager; production-like configuration refuses a real provider without its key, a real provider without its webhook secret, a push provider that is not `fcm`, and a sender address on `.invalid`. FCM prefers Workload Identity (no key file at all).
* **Webhooks** authenticate by the provider's signature (Svix HMAC with a 5-minute window) or password (constant-time), are idempotent per event id, and can only add knowledge: they cannot create a message, an incident or a release. A bad signature is a bare `401`; an unconfigured provider is a bare `404`.
* **Suppression is global and one-way, so it needs the mailbox's own word.** Only a provider's *webhook* (a hard bounce, a complaint) puts an address on the suppression list (hashed with the pepper); every later message to it, from any account, is cancelled at the gate. A provider's *refusal at send time* is one provider's list: it marks that contact `bounced` and tells the person, and suppresses nothing. A refusal about our own account, sender or relay (Postmark `400`/`401`/`405`, Resend `validation_error`, SMTP `5.7.x`) is never read as a verdict on a contact. An event about an address the contact no longer has changes nothing. A complaint is "never contact me again" everywhere and takes back the releases made to that person.
* **Errors carry codes, not content.** Provider failures are logged and stored as short codes (`resend_403`, `postmark_406`); never an address, a token, a body or a URL.
* **At-least-once.** The fallback provider (and crash recovery) can send a message twice; for alerts that is the intended direction of error.

