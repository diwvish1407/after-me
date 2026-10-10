# AfterMe — API Specification

| | |
|---|---|
| **Status** | Draft v0.1 — awaiting product-owner approval |
| **Style** | REST + JSON, versioned under `/v1` |
| **Source of truth** | Once implemented, the generated OpenAPI document (`/v1/openapi.json`, served only outside production) is canonical. This spec defines the intended contract. |
| **Golden examples** | `docs/contracts/phase2/*.json` (auth and profile) and `docs/contracts/phase3/*.json` (trusted contacts and entitlements) and `docs/contracts/phase4/*.json` (check-in schedule, I'M OK, history, Home) and `docs/contracts/phase5/*.json` (the plan, incidents, I'M SAFE, `safe_required`, the probe; parsed by `mobile/test/contracts/phase5_contract_test.dart`; their `index.json` also records the `ETag`, `If-Match`, `Idempotency-Key` and `Idempotent-Replayed` headers): a request/response example for every JSON endpoint and the main problem shapes, generated and compared by a backend test (`AFTERME_UPDATE_CONTRACTS=1` or `make contracts` regenerates) and parsed by the mobile tests. Each folder's `index.json` lists them. |
| **Related** | [DATABASE](DATABASE.md) · [SECURITY](SECURITY.md) · [ESCALATION_ENGINE](ESCALATION_ENGINE.md) |

---

## 1. Conventions

| Topic | Rule |
|---|---|
| Base URL | `https://api.<domain>/v1` (JSON API) and `https://<domain>/` (web pages). The domain is pending [PRD D1](PRD.md#15-decisions-needed-from-the-product-owner). |
| Transport | HTTPS only (HSTS). TLS 1.2+. |
| Auth | `Authorization: Bearer <access_token>` on every endpoint except those marked **public**. |
| Content | `application/json; charset=utf-8`. Request bodies ≤ 64 KB (instructions ≤ 128 KB). |
| Unknown fields | **Rejected** (`422 validation_failed`). No mass assignment. |
| IDs | UUID strings. Never sequential. |
| Instants | RFC 3339 UTC, e.g. `"2026-10-14T14:30:00Z"`. Every response that drives UI timing includes `server_time`. |
| Local time | `"HH:MM"` 24 h. Timezones are IANA names. |
| Pagination | `?limit=` (default 20, max 100) and `?cursor=` (opaque). Response: `{ "items": [...], "next_cursor": "…" \| null }`. |
| Idempotency | `Idempotency-Key: <uuid>` **required** on `POST /checkins` and `POST /incidents/{id}/safe`; optional elsewhere. Replays return the original status and body. |
| Concurrency | Mutable singletons (`/plan`, `/checkin/schedule`) return `ETag`. Updates **require** `If-Match` → `428` if missing, `412` if stale. |
| Client version | `X-AfterMe-Client: android/1.0.0+12`. Below the minimum supported version → `426 upgrade_required`. |
| Request ID | `X-Request-ID` is accepted (or generated) and echoed. It appears in every error body. |
| Caching | All authenticated responses: `Cache-Control: no-store`. |
| Rate limits | `429` with `Retry-After`; `RateLimit-Limit/Remaining/Reset` headers ([§16](#16-rate-limits)). |
| Ownership | Any resource not owned by the caller returns **`404`**, exactly as if it did not exist. |

### 1.1 Errors (RFC 9457)

```json
HTTP/1.1 409 Conflict
Content-Type: application/problem+json

{
  "type": "https://<domain>/problems/safe-required",
  "title": "Confirm you're safe",
  "status": 409,
  "code": "safe_required",
  "detail": "Your contacts have been notified. Confirm I'M SAFE to stop the escalation.",
  "request_id": "01J…",
  "incident_id": "6c1e…"
}
```

Validation errors add `"errors": [{ "field": "stages[1].offset_minutes", "code": "too_small", "message": "…" }]`.

| HTTP | `code` | Meaning |
|---|---|---|
| 400 | `bad_request` | Malformed request that no more specific code covers (also the fallback for other framework 4xx) |
| 400 | `invalid_code` | Verification/OTP code wrong or expired (generic) |
| 401 | `unauthenticated` | Missing or invalid token |
| 401 | `token_expired` | Access token expired → refresh |
| 401 | `session_revoked` | Session ended → log in again |
| 401 | `invalid_credentials` | Login failed (generic, no detail on which part) |
| 403 | `forbidden` | Authenticated but not allowed |
| 403 | `reauth_required` | Operation needs password re-auth within the last 5 min |
| 403 | `email_unverified` | Login attempted on an account that hasn't completed signup verification |
| 403 | `plan_limit_reached` | Tier limit; body includes `limit`, `current`, `resource` (e.g. `"contacts"`) |
| 404 | `not_found` | Missing **or not yours** |
| 405 | `method_not_allowed` | Path exists, method does not |
| 409 | `safe_required` | Contacts already messaged; use I'M SAFE |
| 409 | `incident_open` | Change not allowed during an open incident |
| 409 | `stage_in_use` | Stage has assigned instructions (`instruction_ids` in body) |
| 409 | `contact_duplicate` | Email already used by another of your contacts |
| 409 | `activation_requirements_unmet` | `requirements: [...]` in body (Phase 4: `no_contacts`; `no_stages` joins it in Phase 5) |
| 409 | `invalid_state` | Generic state conflict |
| 412 | `precondition_failed` | `If-Match` stale |
| 413 | `payload_too_large` | |
| 422 | `validation_failed` | Field errors |
| 422 | `cannot_be_own_email` | A contact's address is the account's own address; also carries `errors: [{ field: "email", code: "cannot_be_own_email", message }]` so the app can mark the field |
| 426 | `upgrade_required` | App version too old |
| 428 | `precondition_required` | `If-Match` missing |
| 429 | `rate_limited` | |
| 500 | `internal_error` | Generic; no internals |
| 503 | `service_unavailable` | Retryable (includes lock timeout) |

## 2. Authentication (`/v1/auth`)

### 2.1 Signup: start (public)

`POST /v1/auth/register/start`

```json
{ "email": "diwakar@example.com", "password": "correct horse battery",
  "display_name": "Diwakar", "timezone": "Asia/Kolkata", "locale": "en", "country_code": "IN" }
```

→ **`202`** `{ "status": "code_sent", "resend_after_seconds": 60 }`. The response is the same whether or not the email is already registered. If it is, the email says *"Someone tried to create an account with this address. If it was you, sign in or reset your password."* An unverified pending signup is replaced. Pending signups are purged after 24 h.

### 2.2 Signup: verify (public)

`POST /v1/auth/register/verify`

```json
{ "email": "diwakar@example.com", "code": "482913", "password": "correct horse battery",
  "device": { "platform": "android", "app_version": "1.0.0+12", "os_version": "15", "locale": "en-IN" } }
```

The `password` must be the one chosen at signup. Anyone can start a signup for someone else's address; without this check the code mailed to that person would activate an account holding the attacker's password (pre-hijacking). A mismatch returns the same generic `400 invalid_code` and counts as a code attempt.

→ **`201`** (`400 invalid_code` otherwise; 5 attempts per code)

```json
{
  "access_token": "eyJ…", "access_token_expires_at": "2026-10-08T10:15:00Z",
  "refresh_token": "rt_9f…", "session_id": "…", "device_id": "…",
  "user": { "id": "…", "email": "diwakar@example.com", "tier": "free" }
}
```

`POST /v1/auth/register/resend` `{ "email" }` → `202` (rate-limited).

### 2.3 Login, refresh, logout

| Method & path | Body | Response |
|---|---|---|
| `POST /auth/login` (public) | `{ email, password, device }` | `200` tokens as in §2.2 · `401 invalid_credentials` · `403 email_unverified` (a new code is sent) |
| `POST /auth/refresh` (public) | `{ refresh_token }` | `200 { access_token, access_token_expires_at, refresh_token }` · `401 session_revoked` |
| `POST /auth/logout` | — | `204` (current session; clears that device's push token) |
| `POST /auth/logout-all` | — | `204` (all sessions, including this one) |
| `POST /auth/reauth` | `{ password }` | `204`; sets `reauthenticated_at` on this session (valid 5 min) · `401 invalid_credentials` (wrong password; the session stays valid, so clients must **not** treat this as session loss) · `429 rate_limited` (5 per 15 min per session) |
| `GET /auth/sessions` | — | `200 { items: [{ id, kind, device: {platform, app_version}, created_at, last_used_at, current }] }` |
| `DELETE /auth/sessions/{id}` | — | `204` · `404` if not yours or unknown |

A client treats `400`, `401`, `403` and `422` from `/auth/refresh` as a rejected refresh and signs out; any other failure (network, timeout, `429`, `5xx`) is transient and keeps the session. Clients refresh the access token **only** on `401 token_expired`. Any other `401` on an authenticated call (`unauthenticated`, `session_revoked`, `invalid_credentials` from reauth) is never retried with a refresh.

Security emails (Phase 1): a login from a new device, a refresh-token reuse that revoked the session, and `logout-all` each send one email to the account address after the change commits.

### 2.4 Passwords and email

| Method & path | Body | Result |
|---|---|---|
| `POST /auth/password/forgot` (public) | `{ email }` | `202 { "status": "email_sent" }` |
| `POST /auth/password/change` | `{ current_password, new_password }` | `204` · `401 invalid_credentials` · `422 validation_failed` · `429` |
| `POST /auth/email/change/start` | `{ new_email }` | **Re-auth.** `202 { "status": "code_sent" }` · `403 reauth_required` · `429` |
| `POST /auth/email/change/verify` | `{ code }` | `200` same body as `GET /me` · `400 invalid_code` |

**Forgot password.** The response is always `202` with an identical body, whether or not the account exists, and the server does the same work in every case (a token is generated and hashed, the email is rendered, the same statements run; delivery happens after the response is sent). Only a *verified, active* account is sent anything. The email contains `{PUBLIC_BASE_URL}/a/reset#<token>`, where `token` is `pr_` plus 256 bits of CSPRNG output (URL-safe base64, 46 characters in all). Only its SHA-256 is stored (`auth_tokens`, purpose `password_reset`, kind `link`). The link is valid for 30 minutes and works once; issuing a new link invalidates every older unused one. Limits: 3/h per email (compared case-insensitively), 10/h per IP; exceeding either is `429 rate_limited`. The token is redeemed on the web page ([§13.2](#132-user-account-a)), never through the JSON API; the mobile app only asks for the email and tells the person to open the link.

**Change password.** The new password follows the signup policy (10–128 characters after NFKC normalisation, not the email address or its local part, not on the common-password blocklist) and must differ from the current one. Policy violations are `422 validation_failed` with `errors[0].field = "new_password"` and a code (`too_short`, `too_long`, `password_too_common`, `password_matches_email`, `password_unchanged`) and do not count against the guessing budget. A wrong `current_password` is `401 invalid_credentials` (the session stays valid; clients must not treat this as session loss), is audited as `auth.reauth_failed` with reason `change_password`, and **shares the 5-per-15-minutes-per-session budget with `/auth/reauth`**. On success the password hash and `password_changed_at` are replaced, **every other session of the user is revoked** (reason `password_changed`, push tokens of those devices cleared) while the current session and its refresh token keep working, unused reset links are invalidated, the `password_changed` email is sent and `auth.password_changed` is audited (user-visible).

**Change email.** `start` requires a re-authentication within the last 5 minutes (`403 reauth_required` otherwise) and is limited to 5/h per user. It always answers `202 { "status": "code_sent" }` so it reveals nothing about `new_email`:
* a free address (or one held only by a never-verified signup) gets a 6-digit code (same rules as signup codes: HMAC-stored, 15 minutes, 5 attempts, a new code invalidates the previous one; payload holds the normalised new address), and the **old** address gets an `email_change_requested` notice (new address masked as `a***@example.com`);
* an address that belongs to another verified account gets the `account_exists` notice instead of a code;
* the current address (any casing) does nothing.

`verify` takes the code; a wrong, expired, used or exhausted code (and a code that lost a race for the address, including a database uniqueness violation) is `400 invalid_code`. On success `users.email` / `email_normalized` change, a never-verified signup holding the address is superseded (the code proves control of the mailbox), unused reset links are invalidated, **other sessions are kept**, the **old** address receives the `email_changed` notice, `auth.email_changed` is audited (user-visible) and the body is the same as `GET /me`.

**Security emails.** Phase 1: new-device login, refresh-token reuse, all sessions signed out, account locked, account exists. Phase 2 adds `password_reset_link`, `password_reset_completed`, `password_changed`, `email_change_code`, `email_change_requested` and `email_changed`. All are sent after the transaction commits.

## 3. Me (`/v1/me`)

`GET /v1/me` →

```json
{
  "id": "…", "email": "diwakar@example.com", "tier": "free", "status": "active",
  "profile": { "display_name": "Diwakar", "phone_e164": "+9198…", "country_code": "IN",
               "timezone": "Asia/Kolkata", "locale": "en" },
  "created_at": "2026-10-08T09:58:00Z"
}
```

| Method & path | Notes |
|---|---|
| `PATCH /me/profile` | `{ display_name?, phone_e164?, country_code?, timezone?, locale? }` → `200` same body as `GET /me`. Any non-empty subset; an empty body or an unknown field is `422`. Same rules as signup (display name rules, IANA timezone, ISO 3166-1 alpha-2 country, language tag locale); `phone_e164` is E.164 (`+` and 7–15 digits). `null` clears `phone_e164` and `country_code` only; `null` for the other fields is `422 null_not_allowed`. Audited as `profile.updated` (changed field names only) and, when the timezone changes, `profile.timezone_changed` (user-visible). Changing `timezone` while the schedule is active restarts the clock in the new zone (`next_due_at` recomputed from now, audited as `schedule.updated`, §6.1) and bumps the schedule `version` whatever its status; during an incident it is `409 incident_open` and **nothing** in the request is applied. **Phase 4, implemented.** |
| `GET /me/entitlements` | `200 { tier, limits: { contacts, instructions, stages, custom_offsets }, usage: { contacts, instructions, stages } }`. Free: contacts 1, instructions 3, stages 2, `custom_offsets` false. Premium: 25, 200, 10, true. `usage` counts the caller's non-deleted rows; `instructions` and `stages` are `0` until those features exist (Phases 4 to 6). The server enforces the limits (`403 plan_limit_reached`); the app only mirrors them. An account whose tier changed keeps what it has but cannot add beyond the new limit. **Phase 3, implemented.** |
| `POST /me/export` | **Re-auth.** `200`, `Content-Disposition: attachment; filename="afterme-export.json"`. Contents: profile, contacts, schedule, plan, instructions (**decrypted**), check-in history, incidents, activity. Audited. |
| `DELETE /me` | **Re-auth.** Body `{ "confirm": "DELETE" }` → `202 { status: "pending_deletion", purge_after }`. Behaviour: [DATABASE §4](DATABASE.md#4-deletion-behaviour). |

## 4. Devices

| Method & path | Body | Notes |
|---|---|---|
| `PUT /v1/devices/current` | `{ platform, push_token?, app_version, os_version, locale }` | Upsert for the session's device. A push token registered to another user's device is detached from it. |
| `DELETE /v1/devices/current/push-token` | — | `204` (user turned notifications off) |

## 5. Home (dashboard aggregate)

`GET /v1/home`: everything the home screen needs in a single call.

```json
{
  "server_time": "2026-10-14T13:30:00Z",
  "user": { "display_name": "Diwakar", "tier": "free", "timezone": "Asia/Kolkata" },
  "checkin": {
    "status": "active",
    "next_due_at": "2026-10-14T14:30:00Z",
    "last_checkin_at": "2026-10-13T14:00:00Z",
    "schedule": { "interval_days": 1, "due_local_time": "20:00", "reminder_lead_minutes": 60 }
  },
  "incident": null,
  "plan_summary": { "stages": 2, "contacts_total": 1, "contacts_verified": 1, "instructions_active": 3 },
  "readiness": { "ready": true, "issues": [] },
  "recent_activity": [ { "action": "checkin.recorded", "occurred_at": "2026-10-13T14:00:00Z" } ]
}
```

`readiness.issues[].code` values: `schedule_inactive`, `no_contacts`, `contact_pending`, `contact_declined`, `contact_bounced`, `contact_opted_out`, `no_stages`, `stage_empty`, `release_contact_unverified`. **Phase 5, implemented:** `no_stages` (the plan has no stage) and `stage_empty` (a stage notifies nobody who is switched on) are real; `plan_summary.stages` counts the stages; `incident` is the object of §9 while one is open. `release_contact_unverified` arrives with instructions (Phase 6). The client adds its own issues: `push_disabled`, `timezone_mismatch`, `battery_optimized`.

During an incident, `incident` is the object described in §9.

**Phase 4, implemented.** The contact and schedule parts are real; the rest are placeholders that later phases fill in:
* `incident` is always `null` until Phase 5. `plan_summary.stages` and `instructions_active` are `0` until Phases 5 and 6.
* `readiness.issues` is a list of `{ "code": …, "contact_id": uuid | null }`. `contact_id` names the contact an issue is about (`contact_pending`, `contact_declined`, `contact_bounced`, `contact_opted_out`) and is `null` otherwise. Only contacts that are switched on (`is_active`) are judged. `no_stages`, `stage_empty` and `release_contact_unverified` arrive with Phases 5 and 6. `ready` is `true` exactly when `issues` is empty.
* `recent_activity` is the newest five **user-visible** audit records (the Activity feed, SECURITY §9), newest first.
* `user.tier` and `checkin.status` are the server's view; the client never derives them.

## 6. Check-in

### 6.1 Schedule

`GET /v1/checkin/schedule` → `ETag: "sched-4"`

```json
{ "interval_days": 1, "due_local_time": "20:00", "reminder_lead_minutes": 60,
  "timezone": "Asia/Kolkata", "status": "active",
  "next_due_at": "2026-10-14T14:30:00Z", "last_checkin_at": "2026-10-13T14:00:00Z", "version": 4 }
```

| Method & path | Notes |
|---|---|
| `PUT /checkin/schedule` | `If-Match` required. `{ interval_days, due_local_time, reminder_lead_minutes }`. If active, recomputes `next_due_at` from now. `409 incident_open` during an incident. **Re-auth** (`403 reauth_required`) when the schedule is **active** and `interval_days` is larger than the saved value; shortening, changing the time or reminder only, and any change while the schedule is off need none. |
| `POST /checkin/activate` | Requirements: a plan with ≥ 1 stage notifying ≥ 1 contact. Otherwise `409 activation_requirements_unmet` with e.g. `["no_stages"]`. Sets `baseline_at = now` and computes `next_due_at`. |
| `POST /checkin/deactivate` | **Re-auth.** Turns check-ins off; `409 incident_open` during an incident. |

**Phase 4, implemented.**
* **`version` and the ETag.** `ETag: "sched-<version>"` is a strong validator. `version` goes up on a change to `interval_days`, `due_local_time` or `reminder_lead_minutes`, on activate and deactivate, and when the profile timezone changes. It does **not** change on a check-in, so a client that is editing the schedule never loses its `If-Match` because the user tapped I'M OK. `If-Match` must be exactly the current ETag: `*`, weak (`W/`) and unquoted values are `412`. Clients build it from the body's `version` (`"sched-<version>"`), not from the `ETag` header, because an intermediary that compresses a response may weaken the header. Missing is `428` and is answered before anything is read.
* **PUT is idempotent.** A body equal to the stored values changes nothing (no version bump, no audit record, and no restart of the clock). A change while active restarts the clock: `baseline_at = now`, `next_due_at` recomputed (ESCALATION_ENGINE §3.4).
* **Activation.** *Phase 5, implemented:* the requirement is "a plan with at least one stage that notifies at least one contact who is switched on". `requirements` lists what is missing: `no_contacts` (no contact is switched on), `no_stages` (the plan has no stage), `stage_empty` (stages exist but none notifies a contact who is switched on). Activating an active schedule is `200` and changes nothing.
* **Deactivation** sets `status = inactive`, clears `next_due_at`, and keeps `last_checkin_at`. Deactivating an inactive schedule is `200` and changes nothing.
* **Locking.** Every change takes the per-user lock (the `checkin_configurations` row). A lock wait longer than 5 s is `503 service_unavailable`; retry.
* Audit: `schedule.updated` (changed field names and whether the schedule was active), `schedule.activated`, `schedule.deactivated`; all user-visible.

### 6.2 I'M OK

`POST /v1/checkins`, header `Idempotency-Key` (required), body `{ "client_reported_at": "…" }` (optional, informational)

→ **`200`**

```json
{ "checkin": { "id": "…", "kind": "ok", "received_at": "2026-10-14T13:31:02Z" },
  "next_due_at": "2026-10-15T14:30:00Z",
  "incident_resolved": false,
  "server_time": "2026-10-14T13:31:02Z" }
```

| Situation | Result |
|---|---|
| No incident | Recorded; schedule advanced |
| Incident open, no contact messaged yet | Recorded; incident `resolved`; `incident_resolved: true` |
| Incident open, contacts messaged | **`409 safe_required`** (nothing recorded) |
| Schedule inactive | Recorded (history), no schedule effect |
| Same `Idempotency-Key` again | Original response replayed |

`GET /v1/checkins?cursor=` → `{ items: [{ id, kind, source, received_at }], next_cursor }`

**Phase 4, implemented.**
* `Idempotency-Key` is 16 to 64 characters from `A-Z a-z 0-9 _ . : -`; a missing or malformed key is `422 validation_failed` with `errors[0].field = "Idempotency-Key"`. A UUID is the intended form. Keys are scoped to the user.
* **Replay.** A key that was already recorded is answered with the stored body (including its original `server_time`) before the rate limit and the lock are touched, so a retry of a tap that succeeded can never be turned into a `429` or a `503`. A replayed response is the stored JSON of the first answer (its key order may differ; a field that a later release adds or removes never turns a replay into an error) and carries `Idempotent-Replayed: true`; because its `server_time` is old, a client calibrates its clock offset from `GET /v1/home` (or from a response without that header), never from a replay.
* **Incidents (Phase 5, implemented).** With an open incident the check-in takes the user lock, then the incident row (ESCALATION_ENGINE §6.2). If **no contact has been messaged** (`contacts_messaged_at IS NULL`) it is recorded, the incident becomes `resolved` (`incident_resolved: true`), what is pending is cancelled and anything still queued for contacts is cancelled before it was sent. If contacts **were** messaged it is **`409 safe_required`** with the `incident_id`, and nothing is recorded: the person confirms I'M SAFE (§9). If the configuration says `incident_open` but no incident row exists (it cannot happen through the API), the check-in is recorded and the schedule restored, so the person is never locked out.
* `next_due_at` is `null` when the schedule is inactive; `last_checkin_at` is still updated. The last check-in never moves backwards if a request that started earlier waited for the lock behind a later one.
* `client_reported_at` is optional and informational. A value that is not RFC 3339 with an offset, or outside 2020–2099, is **ignored** (stored as `NULL`), never rejected: a phone with a wrong clock must still be able to check in. Unknown body fields are `422`.
* **Rate limit:** 30 new check-ins per hour per user (`429` with `Retry-After`).
* **History.** Newest first by `(received_at, id)`; `limit` 1 to 100 (default 20); `cursor` is opaque, and a cursor this server did not issue is `422`. `source` is `app` (the `web` source arrives with web check-in). Rows are kept for 400 days (DATABASE §5).
* Audit: `checkin.recorded` (user-visible).

## 7. Trusted contacts

**Phase 3, implemented** (invitations, consent and the recipient pages; escalation fields arrive with later phases). Every route needs a bearer token and is owner-scoped: another user's contact ID is `404 not_found`, exactly like an unknown ID, and changes nothing.

Contact object:

```json
{
  "id": "…", "display_name": "Mom", "relationship": "mother", "relationship_label": null,
  "email": "mom@example.com", "phone_e164": null, "priority": 1,
  "verification_status": "pending", "verified_at": null, "is_active": true,
  "invitation_sent_at": "2026-10-08T09:00:00Z", "invitation_send_count": 1,
  "notified_at_stages": [], "receives_instructions": 0,
  "created_at": "…", "updated_at": "…"
}
```

| Field | Rules |
|---|---|
| `display_name` | 1 to 80 characters, NFC, no control or bidi characters, no links or addresses, not the brand term (same rules as a profile name) |
| `relationship` | `mother`, `father`, `parent`, `spouse`, `partner`, `sibling`, `child`, `relative`, `friend`, `neighbor`, `employer`, `colleague`, `other` |
| `relationship_label` | Up to 40 characters (same character rules as a name); allowed **only** when `relationship` is `other`. Changing the relationship away from `other` clears it |
| `email` | Required; trimmed and lower-cased (the stored and returned form). Unique among the account's non-deleted contacts; never the account's own address |
| `phone_e164` | Optional, E.164 (`+` and 7 to 15 digits) |
| `priority` | Integer 1 to 999. Default on create: last priority + 1 (capped at 999). Ties are ordered by `created_at` |
| `verification_status` | `pending` (invited, no answer), `verified` (accepted), `declined`, `opted_out`, `bounced` |
| `is_active` | Owner's switch; a paused contact stays in the list |
| `invitation_sent_at`, `invitation_send_count` | Last invitation and how many were sent to the current address. Both stay `null` / `0` while nothing could be sent |
| `notified_at_stages`, `receives_instructions` | `[]` and `0` until the plan and instruction phases |

| Method & path | Notes |
|---|---|
| `GET /contacts` | `200 { "items": [contact, …] }`, non-deleted only, ordered by `priority`, then `created_at`; never more than 25 |
| `POST /contacts` | Body `{ display_name, relationship, relationship_label?, email, phone_e164?, priority? }` → `201` with the contact. Checks, in order: validation `422`; own address `422 cannot_be_own_email`; duplicate `409 contact_duplicate` (case and whitespace insensitive); tier limit `403 plan_limit_reached` (`limit`, `current`, `resource: "contacts"`; free 1, premium 25 non-deleted contacts; concurrent requests cannot exceed it); then the daily budgets `429 rate_limited` (20 creations and 10 invitations per day per user; nothing is created). An invitation email is queued after the commit (and sent after the response). Requests rejected by validation, duplicate or plan checks do not use up the daily budgets |
| `GET /contacts/{id}` | `200` contact |
| `PATCH /contacts/{id}` | Any non-empty subset of `{ display_name, relationship, relationship_label, email, phone_e164, priority, is_active }`; unknown fields and an empty body are `422`. `null` clears `phone_e164` and `relationship_label`; `null` for any other field is `422 null_not_allowed`. **Changing the normalised `email`** resets `verification_status` to `pending`, clears `verified_at`, restarts `invitation_send_count`, invalidates unanswered invitations and sends a new one (it counts towards the 10-per-day invitation budget; the duplicate and own-address rules apply). An earlier answer is never carried over to the new address. Audited as `contact.updated` (field names only) |
| `DELETE /contacts/{id}` | `204`. Soft delete: `deleted_at` is set and `email`, `email_normalized`, `phone_e164` and `relationship_label` are set to `NULL` at once; `display_name` stays for the owner's own history; unanswered invitations stop working. Removing stage and recipient links arrives with the phases that create them. The old address can be added again, and a deleted contact does not count towards the tier limit |
| `POST /contacts/{id}/invitation` | Resend → `202 { "status": "queued" }`. Only while `verification_status` is `pending` or `bounced`; otherwise `409 invalid_state` (a declined, opted-out or verified contact is never re-invited from here). Limits: 3 per 7 days per contact and the 10-per-day invitation budget → `429 rate_limited` with `Retry-After`. A new invitation invalidates earlier unanswered ones |

**Invitations and consent.** The invitation email (`contact_invitation`, English, calm, neutral pronouns, "AfterMe is not an emergency service") names the inviter and their address, explains what accepting means, says no app is needed, and carries two links: `{PUBLIC_BASE_URL}/c/open#ci_<token>` (accept or decline) and `{PUBLIC_BASE_URL}/c/optout#oo_<token>` (stop emails). Invitation tokens are `ci_` + 256 random bits; only the SHA-256 is stored (`contact_verifications`); they are valid for 14 days and can be answered once. Opt-out tokens are stateless and never expire: `oo_<contact_id>.<mac>`, where `mac` is an HMAC-SHA256 of the contact ID **and the normalised address the link was issued for** under the server pepper (constant-time compare; tokens issued before a pepper rotation keep working while the previous pepper is configured). Binding the address is a deliberate deviation from an ID-only MAC: when the account holder corrects an address (a typo that reached a stranger), the stranger's old link stops working instead of opting out, or globally suppressing, the contact's new, correct address. A link whose address is no longer the contact's renders the generic "This link doesn't work" page. The wording version `2026-10-v1` is stored with each answer. Contacts receive nothing escalation-related in Phase 3: only the invitation, the notices of their own answers and these pages.

**Notices to the account holder** (email after commit, audited and shown in Activity): `contact_accepted`, `contact_declined`, `contact_opted_out`.

**Suppression.** Invitations are sent only to addresses not on the global suppression list. For a suppressed address the contact is still created (`pending`, `invitation_send_count` 0, no invitation row, no email, no `contact.invitation_sent` audit record), the same limits are counted, and the response has the same shape and status as for any other address. The API never says that an address is suppressed. Suppressed contacts show as `pending` forever, with a hint to contact them another way.

**Audit** (IDs and reason codes only; never names or addresses): `contact.created`, `contact.updated`, `contact.deleted`, `contact.invitation_sent`, `contact.accepted`, `contact.declined`, `contact.opted_out`. All are user-visible except `contact.updated`. Answers given on the recipient pages are recorded with `actor_type = contact`.

## 8. Escalation plan

`GET /v1/plan` → `ETag: "plan-7"`

```json
{
  "id": "…", "version": 7, "grace_minutes": 180,
  "stages": [
    { "id": "s1", "position": 1, "offset_minutes": 180,  "notify_contact_ids": ["c-mom"], "release_count": 0 },
    { "id": "s2", "position": 2, "offset_minutes": 1440, "notify_contact_ids": ["c-bro"], "release_count": 1 }
  ],
  "rules": { "grace_min": 60, "grace_max": 4320, "stage_gap_min": 30, "offset_max": 43200,
             "release_offset_min": 1440, "max_stages": 2, "custom_offsets": false,
             "presets": [180, 360, 720, 1440, 2880, 4320] }
}
```

`PUT /v1/plan` (`If-Match` required) replaces the plan atomically:

```json
{ "grace_minutes": 180,
  "stages": [
    { "id": "s1",  "offset_minutes": 180,  "notify_contact_ids": ["c-mom"] },
    { "id": null,  "offset_minutes": 2880, "notify_contact_ids": ["c-bro"] }
  ] }
```

Validation (server-side; also re-checked by the engine):
- `stages[0].offset_minutes == grace_minutes`
- offsets strictly increasing, gaps ≥ 30, ≤ 43200; count ≤ `max_stages`
- free tier: offsets must come from `presets`
- every `notify_contact_id` must be yours (otherwise `404`)
- a stage with assigned releases must keep offset ≥ 1440
- stages missing from the request are deleted → `409 stage_in_use` if instructions are assigned
- `409 incident_open` during an incident

→ `200` with the new plan and `ETag`.

**Phase 5, implemented.**
* A new account has an empty plan (grace 180, `stages: []`); `GET /plan` creates it if an older account has none. `If-Match` is built from `version` (`"plan-<version>"`); a PUT that changes nothing does not bump it. `404` for a stage or contact that is not yours, `422 validation_failed` with field paths (`grace_minutes`, `stages[1].offset_minutes`, …) and codes `out_of_range`, `must_equal_grace`, `too_close`, `too_large`, `not_a_preset`, `too_short`, `duplicate`, `release_too_early`; `403 plan_limit_reached` (`resource: "stages"`) beyond the tier limit. A downgraded account keeps the stages and custom times it has and cannot add more.
* Positions follow the order of `stages` in the request. Deleting a contact removes it from every stage and bumps the plan `version` (an empty stage is allowed and does nothing). Releases and `stage_in_use` arrive with instructions (Phase 6): `release_count` is `0` until then.
* The engine never reads the live plan to decide an incident: it uses the **snapshot** taken when the incident opened, narrowed by live data (INV-7).

## 9. Incidents

Incident object:

```json
{
  "id": "…", "status": "escalating", "requires": "safe",
  "missed_due_at": "2026-10-14T14:30:00Z", "anchor_at": "2026-10-14T14:30:00Z",
  "grace_ends_at": "2026-10-14T17:30:00Z", "contacts_messaged": true,
  "timeline": [
    { "kind": "user_reminder", "variant": "missed", "scheduled_for": "2026-10-14T14:30:00Z", "status": "executed" },
    { "kind": "execute_stage", "stage_position": 1, "scheduled_for": "2026-10-14T17:30:00Z", "status": "executed",
      "contacts": [ { "id": "c-mom", "display_name": "Mom", "result": "messaged" } ], "release_count": 0 },
    { "kind": "user_final_warning", "scheduled_for": "2026-10-15T13:30:00Z", "status": "pending" },
    { "kind": "execute_stage", "stage_position": 2, "scheduled_for": "2026-10-15T14:30:00Z", "status": "pending",
      "contacts": [ { "id": "c-bro", "display_name": "Brother" } ], "release_count": 1 }
  ],
  "server_time": "2026-10-14T18:02:00Z"
}
```

`requires`: `"checkin"` (I'M OK resolves it) or `"safe"` (use I'M SAFE).

| Method & path | Notes |
|---|---|
| `GET /incidents/current` | `200 { incident: {…} \| null }` |
| `GET /incidents` | History (closed and open), paginated |
| `GET /incidents/{id}` | Includes `releases: [{ instruction_id, title, contact_id, released_at, first_viewed_at, revoked_at }]` once closed |
| `POST /incidents/{id}/safe` | **Re-auth + `Idempotency-Key`.** → `200 { status: "cancelled", all_clear_sent_to: [{ contact_id, display_name }], next_due_at }`. `409 invalid_state` if not open. |

**Phase 5, implemented.**
* **The API can only read and stop incidents.** Incidents, their timeline and releases are created by the worker alone (INV-1); the database refuses the API role the `INSERT`, and the only column updates it may make are the ones that stop or observe.
* The object is exactly the one above plus `closed_at` and `closed_by` (`user_checkin`, `user_safe`, `account_deleted`, `operator_void`); `requires` is `null` once closed. Timeline `contacts[].display_name` is the person's own contact name (kept after a soft delete); `result` is `messaged`, `skipped` or `null` while pending; `release_count` is `0` until Phase 6. A reminder that became untrue (grace ended, or a stage ran) is shown as `cancelled`.
* `GET /incidents` is newest first with an opaque `cursor`; a stranger's id is `404`.
* `POST …/safe` also answers with `incident_id` and `server_time`; a replay of the same key returns the stored JSON and `Idempotent-Replayed: true`. It cancels what is pending and queued, restarts the schedule exactly as an I'M OK does, and queues `contact_all_clear` to the contacts that were actually messaged and `all_clear_confirmation` to the user. I'M SAFE is allowed on any open incident; with nobody messaged the all-clear list is empty.
* A pending stage whose time arrives while the system is in a Hold waits (ESCALATION_ENGINE §7); the app sees it as `pending` with a later `scheduled_for` after the Hold ends.

## 10. Instructions

| Method & path | Notes |
|---|---|
| `GET /instruction-categories` | `[{ id: "home", sort_order: 3 }, …]` (labels localised client-side) |
| `GET /instructions?category=` | List: `{ id, category, title, status, recipients: [{ contact_id, display_name, stage_position }], updated_at }`. **No body in list.** |
| `POST /instructions` | See below → `201` |
| `GET /instructions/{id}` | Full object, including `body` |
| `PATCH /instructions/{id}` | Any of `category`, `title`, `body`, `status`, `recipients` (replaces the list) |
| `DELETE /instructions/{id}` | `204`. Content wiped; open-incident releases revoked. |

```json
POST /v1/instructions
{
  "category": "home",
  "title": "House emergency",
  "body": "The spare key is with Mrs. Sharma at flat 3B …",
  "status": "active",
  "recipients": [ { "contact_id": "c-bro", "release_stage_id": "s2" } ]
}
```

Validation: title 1–120 chars; body 1–20,000 chars (Unicode, normalised to NFC); contacts and stages must be yours; the release stage offset must be ≥ 1440 (`422 release_stage_too_early`); `403 plan_limit_reached`. Assigning an unverified contact is allowed, but it creates a readiness issue.

## 11. Activity

`GET /v1/activity?cursor=` → user-visible audit events:

```json
{ "items": [
  { "id": 98121, "action": "release.viewed", "occurred_at": "…",
    "params": { "contact_display_name": "Brother", "instruction_title": "House emergency" } },
  { "id": 98007, "action": "checkin.recorded", "occurred_at": "…", "params": { "source": "app" } }
], "next_cursor": "…" }
```

Display strings are composed client-side from `action` + `params`. Instruction titles are decrypted for the owner only.

## 12. Billing (Phase 13 / per [PRD D5](PRD.md#15-decisions-needed-from-the-product-owner))

| Method & path | Notes |
|---|---|
| `POST /v1/billing/google-play/purchases` | `{ product_id, purchase_token }` → verified server-side with the Google Play Developer API, acknowledged, `users.tier` updated → `200 /me/entitlements` |
| `POST /webhooks/google-play/rtdn` | Real-time developer notifications (Pub/Sub push; authenticated by Google-signed token) |

## 13. Web routes (server-rendered)

All POSTs carry a CSRF token. GETs never change state. Bearer tokens travel only in URL **fragments** and are exchanged by POST.

### 13.1 Recipient portal (`/c`)

**Phase 3 implements the invitation, decline and opt-out pages. Deliberate deviation from the earlier design: there is no contact session cookie.** Tokens stay in the URL fragment; a first-party script copies the fragment into a hidden form field and clears it with `history.replaceState`; and every page that needs the token is the response to a POST that carries it in the body. The release pages (`/c/release*`, `/c/new-link`) arrive with the release phase and will need their own, separate access mechanism.

| Route | Purpose |
|---|---|
| `GET /c/open` | Landing page for the invitation link. Static form (no database access, no state change); sets the CSRF cookie; the script reads `#ci_…` and submits it to `POST /c/session` |
| `POST /c/session` | `token`, `csrf` → the invitation page: inviter's name and address, what accepting means, **Accept** and **Decline** buttons, and a clearly separate **Never contact me about AfterMe again** button. Changes nothing |
| `POST /c/invite/accept` | `token`, `csrf` → contact `verified` (`verified_at`, response `accepted`, `consent_text_version`, `ip_hash`), thank-you page. Notice `contact_accepted` to the account holder |
| `POST /c/invite/decline` | `token`, `csrf`, optional `never_contact` (`1`) → contact `declined`, thank-you page; with `never_contact` the address is also added to the global suppression list and every other live contact row holding it is set to `opted_out` (like "everyone" below). Notice `contact_declined` |
| `GET /c/optout` | Landing page for the opt-out link; the script reads `#oo_…` and submits it to `POST /c/optout/confirm` |
| `POST /c/optout/confirm` | `token`, `csrf` → page with the two choices. Changes nothing |
| `POST /c/optout` | `token`, `csrf`, `scope` = `this_person` \| `everyone`. `this_person`: that contact becomes `opted_out` and its unanswered invitations stop working. `everyone`: additionally the address (HMAC under the pepper, never the address itself) goes on `email_suppressions` with reason `contact_block_all`, and **every live contact row holding that address, whoever owns it, becomes `opted_out`** (the one deliberate cross-user write, isolated in one repository function). Each affected account holder gets an audit record and the `contact_opted_out` notice. Repeating a choice is harmless and sends nothing again. Concurrent answers that block the same address (one person answering invitations from two accounts at once) are serialised by a per-address lock taken before any contact row is locked, so they cannot deadlock |

Rules for every `/c` route: the body is `application/x-www-form-urlencoded` (anything else fails the CSRF check); every POST needs the double-submit CSRF pair (`__Host-afterme_csrf` cookie and hidden `csrf` field) → `403` page otherwise; **20 requests per hour per IP across all `/c` POSTs** → `429` page with `Retry-After`; the pages carry the same headers as `/a` (strict CSP with a nonce, no third-party script, `Referrer-Policy: no-referrer`, `Cache-Control: no-store`, `X-Robots-Tag: noindex, nofollow`, `frame-ancestors 'none'`). A successful answer clears the CSRF cookie.

A malformed, unknown, tampered, expired, already answered or invalidated token (and an opt-out token for a deleted contact) renders **one** generic calm page ("This link doesn't work") with status `400`; the body and status are identical in every case, so nothing reveals whether a contact or invitation exists. A contact that is no longer `pending` or `bounced` cannot answer an old invitation.

### 13.2 User account (`/a`)

| Route | Purpose |
|---|---|
| `GET/POST /a/login` | Web login (rate-limited); creates a short `web` session (1 h); counts as re-auth for 5 min |
| `GET /a/checkin` · `POST /a/checkin` · `POST /a/safe` | Lost-phone check-in / I'M SAFE (same server logic as the API) |
| `GET /a/reset` · `POST /a/reset` | Password reset from email (`#<token>`). **Phase 2, implemented.** |
| `GET /a/assets/web.css` | The single first-party stylesheet of the `/a` pages |
| `GET/POST /a/delete` → `GET /a/delete/confirm` · `POST /a/delete/confirm` | Public account-deletion request (Play Store requirement): email link + password confirmation |
| `POST /a/logout` | |

**Password reset page.**
* `GET /a/reset` renders the form and **never changes state** (it does not even touch the database). The link's `#<token>` fragment is not sent to the server; one small first-party script (nonce-protected, no third-party code) copies it into the hidden `token` field and clears the fragment with `history.replaceState`. The response sets the CSRF cookie `__Host-afterme_csrf` (`Secure`, `HttpOnly`, `SameSite=Strict`, `Path=/`) and puts the same random value in the hidden `csrf` field (double submit).
* `POST /a/reset` (`application/x-www-form-urlencoded`: `token`, `new_password`, `csrf`; the token is read from the body only, never from the URL). Limit: 10/h per IP. Outcomes, all HTML:

| Status | Page |
|---|---|
| `200` | Password changed; sign in again in the app. The CSRF cookie is cleared. |
| `400` | One generic "this link doesn't work" page for a malformed, unknown, used or expired token, or an unusable account (it never reveals whether an account exists), pointing to *Forgot password* in the app. |
| `403` | CSRF cookie and field missing or different, or the body is not a urlencoded form. Nothing is changed. |
| `422` | Password policy failure (same policy as signup): the form is shown again with the reason; the link stays valid. |
| `429` | Rate limited (`Retry-After`). |

Success sets the new Argon2id hash and `password_changed_at`, clears any login lockout, **revokes every session of the user** (reason `password_reset`, all push tokens cleared), consumes the token (atomically, so concurrent submissions succeed at most once), invalidates other unused reset links and pending email-change codes, sends the `password_reset_completed` email and audits `auth.password_reset_completed` (user-visible).

Every `/a` page carries `Content-Security-Policy: default-src 'none'; script-src 'nonce-{n}'; style-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'` (fresh nonce per response), `Referrer-Policy: no-referrer`, `Cache-Control: no-store`, `X-Robots-Tag: noindex, nofollow`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` and a minimal `Permissions-Policy`.

### 13.3 Public

`/legal/privacy`, `/legal/terms`, `/support`, `/.well-known/assetlinks.json` (Android App Links, later).

## 14. Internal, webhooks and health

| Route | Auth | Purpose |
|---|---|---|
| `POST /internal/probe` | `X-Probe-Token` (secret) | External uptime monitor; records an `ingestion_probes` row → feeds Hold ([ESCALATION_ENGINE §7](ESCALATION_ENGINE.md#7-system-hold-the-circuit-breaker)). **Phase 5, implemented:** `204`; `401` for a missing or wrong token (constant-time compare); `404` where no `PROBE_TOKEN` is configured; 10 per minute per IP; optional `X-Probe-Source`. |
| `POST /webhooks/email/{provider}` | Provider signature verification | Delivery, bounce, complaint events |
| `GET /health/live` | none | Process alive |
| `GET /health/ready` | none | DB reachable, migrations at head → `200`/`503` |

Admin operations (Hold enter/exit, key rotation) are **not** exposed over HTTP. They run via the `afterme-admin` CLI with operator credentials, and are audited.

## 15. Deliberately absent

There is **no** endpoint to:
- trigger, advance or simulate an escalation, stage, release or contact notification;
- set `next_due_at`, an incident status, or any timeline action directly;
- read another user's anything, or look up users or contacts by email;
- view a release as the owner *through the portal* (the owner sees releases in `/incidents/{id}`).

Staging has an extra **test-only** router (`/v1/_test/clock`, `/v1/_test/tick`). It is compiled out of production builds, and startup fails if it is enabled with `APP_ENV=prod`.

## 16. Rate limits

| Scope | Limit |
|---|---|
| `register/start`, `register/resend` | 5/h per IP · 3/h per email |
| `register/verify` | 5 attempts per code · 20/h per IP |
| `login` | 10/15 min per IP · 5 failed attempts/15 min per account (successful logins do not count; further attempts get `429` with `Retry-After` until the window ends); account locked 15 min after 10 consecutive failures (security email) |
| `refresh` | 60/h per session |
| `password/forgot` | 3/h per email · 10/h per IP |
| `reauth`, `password/change` | 5/15 min per session, one shared budget (`password/change` counts only attempts that test the current password) |
| `email/change/start` | 5/h per user |
| `POST /a/reset` | 10/h per IP |
| `checkins` | 30/h per user |
| `contacts` create | 20/day per user · invitations 10/day per user (creations, resends and address changes together) · resend 3/7 days per contact |
| `POST /c/session`, `/c/invite/*`, `/c/optout*` | 20/h per IP, one shared budget |
| `/c/release/otp` | 3/h per access · verify 5 per challenge |
| `/a/login` | as `login` |
| `/internal/probe` | 10/min |
| Default authenticated | 300/min per user |
| Default unauthenticated | 60/min per IP |

Client IPs are taken from `X-Forwarded-For` **only** through the configured number of trusted proxy hops.
