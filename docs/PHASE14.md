# AfterMe — Phase 14: redesign, several check-in times, two-step verification, Google, admin

| | |
|---|---|
| **Status** | Built (2026-11-17). Backend migrations `0014`, `0015`. |
| **Design source** | `docs/AfterMe_UI_Screens_01-29.pdf` |

## 1. What changed for people

* **New look.** Blue brand palette (USER_FLOWS §1.2 tokens), gradient headers, glass cards, 3D
  illustrations (`mobile/assets/illustrations/`, cut from the design PDF), a side menu, and a
  bottom bar of Home · Instructions · Check-in · Contacts · Profile. Home shows a greeting,
  a status card (on track / due / finish setup), figures, "Your setup" and quick actions.
* **Several check-in times.** Besides the main schedule a person can add up to 5 more check-in
  times (e.g. Morning 09:00). Each one may have its **own plan** (grace, stages, contacts) or use
  the main plan. Check-in tab → *Add a check-in time*.
* **Two-step verification** with an authenticator app (Profile → Security → Two-step
  verification), with 8 one-use recovery codes.
* **Sign in with Google.**
* **"I'm checking on them".** The alert email to a trusted contact carries a link; the contact can
  confirm they are checking on the person, and the person sees it on the incident timeline.
* **Admin** (accounts with `role = admin`): the menu shows *Admin* — figures, every account
  (status, schedule, check-in times, contacts with masked addresses, alerts), suspend /
  unsuspend, tier, admin role, end an alert, pause/resume messages to contacts (Hold).
  **Instruction content is never shown to admins.**

Not built, on purpose: Premium purchase / "Upgrade" (no Play Billing in 1.0 — PRD D5 and the
copy rules forbid purchase wording), SMS codes (authenticator apps only).

## 2. How several check-in times work (engine)

* The primary schedule stays in `checkin_configurations`; extra times are `checkin_slots`.
  Each has its own deadline (`primary_due_at`, `checkin_slots.next_due_at`).
  `checkin_configurations.next_due_at` is always the **earliest**, `due_slot_id` says whose.
  The engine still watches only `next_due_at`, so the lock, safety gate, Hold and FS-25 are
  unchanged.
* An I'M OK answers the time that is due first (and any due within 60 minutes of it); the others
  keep their deadlines. The baseline always moves (every check-in is absorbed).
* A missed time opens the incident with **that time's plan** (`escalation_plans.slot_id`), or
  the default plan. Instructions are released at stage N of the default plan for stage N of an
  event plan.
* Activation, I'M SAFE, a void and a timezone change restart every time.
* Removing a time (or lengthening it) while check-ins are on needs the password again. Removed
  times are soft-deleted (their plan may be referenced by past incidents).

## 3. API (all under the usual auth rules)

| Method | Path | Notes |
|---|---|---|
| GET/POST | `/v1/checkin/events` | list (with `max_events`) / create `{label, due_local_time, interval_days?, interval_minutes?}` |
| PUT/DELETE | `/v1/checkin/events/{id}` | change / remove (re-auth when active) |
| GET/PUT | `/v1/checkin/events/{id}/plan` | the event's plan; `inherits_default: true` + ETag `"plan-0"` until first saved |
| GET | `/v1/me/2fa` | `{enabled, recovery_codes_left}` |
| POST | `/v1/me/2fa/setup` | re-auth; returns `{secret, otpauth_uri}` |
| POST | `/v1/me/2fa/enable` | `{code}` → `{recovery_codes}` |
| POST | `/v1/me/2fa/disable` | re-auth + `{code}` |
| POST | `/v1/auth/login` | new optional `otp`; `401 mfa_required` / `invalid_otp` |
| POST | `/v1/auth/google` | `{id_token, device, timezone?, otp?}`; `503 google_unavailable` when not configured |
| GET | `/v1/admin/overview`, `/users?q=&limit=&offset=`, `/users/{id}`, `/incidents?open=`, `/hold` | admins only |
| POST | `/v1/admin/users/{id}/tier\|suspend\|unsuspend\|role`, `/incidents/{id}/void`, `/hold/enter\|exit` | admins + re-auth; `{reason}` audited |
| GET/POST | `/c/ack`, `/c/ack/confirm`, `/c/ack` | contact web pages (CSRF, same per-IP budget as other `/c` pages) |

`/v1/me` adds `role`, `mfa_enabled`, `google_linked`; `/v1/home` adds `checkin.next_due_label`,
`next_due_event_id`, `events`; incidents add `acknowledgements`.

## 4. Configuration (needed before release)

| Where | Key | Value |
|---|---|---|
| Backend env | `AFTERME_GOOGLE_CLIENT_IDS` | JSON list of OAuth client IDs whose ID tokens are accepted, e.g. `["123-web.apps.googleusercontent.com"]` (the **web** client the app requests tokens for). Empty: Google sign-in answers 503. |
| `mobile/config/<env>.json` | `GOOGLE_SERVER_CLIENT_ID` | the same **web** client ID |
| Google Cloud console | Android OAuth client | package `app.afterme` (and `.dev`, `.staging`) + the SHA-1 of the upload/debug key and of Play App Signing |

Two-step verification needs nothing extra (secrets are wrapped by the existing KMS).

## 5. Making the first admin

```bash
cd backend
make admin ARGS='user set-role you@example.com admin --reason "first admin"'
```

The person signs in again (or reopens the app); *Admin* appears in the side menu. Further admins
can be made from the admin screen.

## 6. Migrations

`0014` (check-in times, event plans) and `0015` (role, 2FA, Google, acknowledgements, the API's
Hold grants) are additive. Deploy order as always: migrate, then the API, then the worker.
