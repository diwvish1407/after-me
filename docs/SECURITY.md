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
| T2 | Forcing a release through the API | No such endpoint (API §15); the API DB role lacks `INSERT` on incidents, actions, releases and portal access; the dispatcher only sends escalation messages linked to an executed stage action; engine gate |
| T3 | Tampering with escalation timing from the client | All deadlines and offsets are computed server-side; `extra="forbid"`; client times ignored; plan rules validated server-side and re-validated by the gate |
| T4 | Credential stuffing / brute force | Argon2id; per-IP and per-account rate limits; lockout with security email; common-password blocklist; generic errors |
| T5 | Refresh-token theft | Keystore-backed storage; rotation on every use; reuse detection revokes the session; sessions listed and revocable |
| T6 | Access-token theft | 15-min lifetime; session validity checked on every request; TLS only |
| T7 | Request replay | Idempotency keys (check-in/safe); short token lifetime; TLS. Replaying a check-in can only *delay* escalation, and a replayed I'M SAFE needs a fresh re-auth window. |
| T8 | Unlocked or stolen phone used to check in or cancel | App lock (biometric / device credential); **password re-auth** for I'M SAFE, deactivate, export, delete; remote session revocation via web |
| T9 | Takeover via the user's email (password reset) | Security emails on reset/login/email change; reset revokes all sessions; TOTP/passkeys planned for 1.1. **Residual risk for 1.0.** |
| T10 | Contact's email compromised → reads released content | OTP to the same inbox (limited help); releases ≥ 24 h after the miss; revocation on I'M SAFE; views audited and shown to the user. **Residual risk** (§18). |
| T11 | Email link scanners trigger actions | GET never changes state; actions need a POST with CSRF; content needs an OTP |
| T12 | Token leakage via logs or Referer | Tokens only in URL fragments; `Referrer-Policy: no-referrer`; log redaction; access logs without query strings |
| T13 | Sensitive data in logs or crash reports | Redaction processor; no bodies logged; error-monitoring scrubbing; automated log-leak tests |
| T14 | Database or backup leak | Instruction content encrypted with per-user DEKs (KMS-wrapped); tokens stored as hashes; low-entropy values HMAC'd with a pepper; managed at-rest encryption |
| T15 | Insider / cloud credential misuse | Least-privilege IAM; MFA on cloud accounts; KMS decrypt audit logs; no admin UI; operator actions via audited CLI; separate prod project |
| T16 | Invitation spam / harassment | Verified-email signup; invitation rate limits; consent required; opt-out in every email; global "never contact me" list; abuse report address |
| T17 | OTP / code brute force | 6 digits, 5 attempts per challenge, 10–15 min expiry, send limits. Worst case ≈ 5×10⁻⁶ success per challenge, ≤ 3 challenges/hour. |
| T18 | Account enumeration | Identical responses for register/forgot; generic login errors; timing equalised (dummy Argon2 verification for unknown emails) |
| T19 | Injection (SQL/template/header) | SQLAlchemy parameters only (no string SQL); Jinja autoescape; strict Pydantic types; email header values sanitised |
| T20 | DoS / resource exhaustion | Rate limits; body-size limits; pagination caps; DB statement timeouts; ingress-level protection (Cloud Armor or equivalent) when exposed publicly |
| T21 | Push spoofing | Payloads are hints only; no actions taken from payload content |
| T22 | Supply chain | Locked dependencies (uv.lock, pubspec.lock); pip-audit / OSV scanning in CI; Dependabot/Renovate; Play App Signing; protected CI secrets; minimal third-party SDKs |
| T23 | Mass wrongful escalation from an outage or bug | Hold circuit breaker; anomaly detection; settle delay; operator kill switch |
| T24 | Clickjacking (portal) | `frame-ancestors 'none'` |
| T25 | XSS via instruction content in the portal | Content rendered as escaped plain text (`white-space: pre-wrap`); no HTML/Markdown rendering in 1.0; strict CSP with nonces |
| T26 | Phishing via display names ("AfterMe Security") | Display-name validation (no URLs or lookalike brand terms); emails always attribute "sent by AfterMe on behalf of *Name* (*email*)"; fixed templates; DMARC enforcement |

## 6. Cryptography

### 6.1 In transit
- TLS 1.2+ (prefer 1.3) for all public endpoints, with HSTS. The app sets no cleartext traffic (`network_security_config`); the dev flavor allows cleartext only to the local emulator host.
- Database connections use TLS (`sslmode=verify-full` where the provider supports it).
- **No certificate pinning in 1.0.** It risks bricking clients when certificates rotate. Revisit with a backup-pin strategy in Phase 9.

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
| Re-auth (step-up) | Password, valid 5 min: I'M SAFE, deactivate check-ins, **lengthen the interval of an active schedule** (Phase 4, owner decision 2026-10-10), export, delete account, change email |
| Lockout | 10 consecutive failures → 15 min lock + security email |
| Security emails | New-device login, password changed/reset, email changed, refresh reuse detected, all sessions revoked, deletion requested |
| Planned (1.1) | TOTP / passkeys; Google Sign-In; device-bound biometric key as an alternative step-up for I'M SAFE (evaluate in Phase 9) |

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
| Auth | `auth.signup_started`, `auth.signup_verified`, `auth.login_succeeded` ✓(new device), `auth.login_failed`, `auth.locked`, `auth.logout`, `auth.logout_all` ✓, `auth.refresh_reuse_detected` ✓, `auth.reauth_succeeded`, `auth.reauth_failed`, `auth.password_changed` ✓, `auth.password_reset_requested`, `auth.password_reset_completed` ✓, `auth.email_change_requested`, `auth.email_changed` ✓, `session.revoked` |
| Profile | `profile.updated`, `profile.timezone_changed` ✓ |
| Contacts | `contact.created` ✓, `contact.updated`, `contact.deleted` ✓, `contact.invitation_sent` ✓, `contact.accepted` ✓, `contact.declined` ✓, `contact.opted_out` ✓, `contact.bounced` ✓ |
| Check-in | `schedule.updated` ✓, `schedule.activated` ✓, `schedule.deactivated` ✓, `checkin.recorded` ✓ |
| Plan / instructions | `plan.updated` ✓, `instruction.created`, `instruction.updated`, `instruction.deleted`, `instruction.recipients_changed` ✓ |
| Escalation | `incident.opened` ✓, `incident.resolved` ✓, `incident.cancelled` ✓, `incident.voided` ✓, `escalation.reminder_sent`, `escalation.final_warning_sent` ✓, `escalation.stage_executed` ✓, `escalation.action_held` |
| Release / portal | `release.created` ✓, `release.revoked` ✓, `release.viewed` ✓, `portal.session_created`, `portal.otp_sent`, `portal.otp_failed`, `portal.access_denied` |
| Notifications | `notification.sent` / `notification.failed` (contact-facing only) |
| Data | `export.created` ✓, `account.deletion_requested`, `account.purged` |
| System / operator | `system.hold_entered`, `system.hold_exited`, `system.consistency_violation`, `operator.<command>` |
| Billing | `billing.subscription_changed` ✓ |

Metadata contains IDs, reason codes and counts only. **Never** content, names, addresses, tokens, codes or passwords.

## 10. Logging and leakage prevention

- Structured JSON logs with a redaction processor (denylist keys + value-pattern masking for emails and tokens).
- Request/response bodies are never logged. Access logs record the route template (`/v1/contacts/{id}`), not the raw URL.
- Exceptions are logged by class and safe message. Errors from the DB driver that echo parameters are wrapped.
- Error monitoring: `send_default_pii=False`, scrubbing hook, no breadcrumbs from HTTP bodies, release/env tags.
- Mobile: no `print`/`debugPrint` of models in release builds (lint rule); Sentry Flutter with scrubbing; FLAG_SECURE on sensitive screens.
- **Automated leak test:** the full lifecycle e2e test captures all log output and fails if any known secret value (password, token, OTP, instruction title/body, contact email) appears.

## 11. Mobile app (MASVS L1)

| MASVS area | Controls |
|---|---|
| STORAGE | Tokens and the pending check-in record (opaque account id, random key, tap time) in Keystore-backed secure storage; nothing sensitive in `shared_preferences`, files or logs; instruction content never persisted; `allowBackup="false"`; FLAG_SECURE on instruction/export screens |
| CRYPTO | No custom crypto; platform Keystore via plugin |
| AUTH | All authorization server-side; app lock is local convenience security; step-up via server password re-auth |
| NETWORK | HTTPS only; cleartext disabled (except the dev emulator host); platform CA trust |
| PLATFORM | Minimal permissions (INTERNET, POST_NOTIFICATIONS, USE_BIOMETRIC); **no** READ_CONTACTS (system picker); no WebViews; only the launcher activity and FCM service exported; deep links validated |
| CODE | Release builds with `--obfuscate --split-debug-info` (symbols stored privately for crash symbolication); dependencies pinned and scanned; minSdk 26 |
| RESILIENCE | Not targeted for 1.0 (no root detection). Play Integrity API to be evaluated for signup abuse in 1.1. |
| PRIVACY | No ads or analytics SDKs; minimal data; in-app export and deletion |

## 12. Web portal

- Headers: `Content-Security-Policy: default-src 'none'; script-src 'nonce-{n}'; style-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'`, plus HSTS, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, a minimal `Permissions-Policy`, `Cache-Control: no-store`, `X-Robots-Tag: noindex, nofollow`.
- Cookies: `__Host-` prefix, `Secure`, `HttpOnly`, `SameSite=Strict`, server-side session rows (hashed).
- CSRF: a synchronizer token bound to the portal/web session on every POST.
- Every message to a contact shows who sent it (name + email), why they received it, and how to opt out.

## 13. Abuse prevention

| Abuse | Control |
|---|---|
| Spamming arbitrary people with invitations | Verified-email accounts only; 10 invitations/day; 3 resends/contact/week; global suppression; complaint-rate monitoring |
| Using AfterMe to harass via "alerts" | Contacts must accept before any alert; opt-out at any time |
| Throwaway signups | Code verification; per-IP limits; Play Integrity (1.1) if needed |
| Abuse reports | `abuse@<domain>` in every contact email; operator can suspend an account (`users.status = 'suspended'` stops all contact-facing actions) |

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
- CI gates: `ruff` (incl. security rules), `mypy`, `pytest` (incl. the authz matrix + leak test), `pip-audit`, `flutter analyze`, `flutter test`, secret scanning (gitleaks), lockfile integrity.
- Weekly dependency updates (Renovate/Dependabot); critical CVEs patched within 72 h.
- This threat model is updated whenever a feature changes trust boundaries.
- **Phase 9** security review + penetration-oriented test pass. An **external penetration test before public launch** is recommended (budget permitting).

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
| No certificate pinning | Bricking risk | Phase 9 review |
| Someone holding an unlocked phone *and* knowing the password can cancel | Indistinguishable from the user | Duress features (2.x, if ever) |
