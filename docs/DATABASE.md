# AfterMe — Database Design

| | |
|---|---|
| **Status** | Draft v0.1 — awaiting product-owner approval |
| **Engine** | PostgreSQL. Production: 16 or newer (managed). SQL kept compatible with **14** so the current local Homebrew install works; upgrading local to match production is recommended. |
| **Related** | [ESCALATION_ENGINE](ESCALATION_ENGINE.md) · [API_SPEC](API_SPEC.md) · [SECURITY](SECURITY.md) |

---

## 1. Conventions

| Topic | Convention |
|---|---|
| Primary keys | `uuid DEFAULT gen_random_uuid()` (built in since PG 13). Append-only logs use `bigint GENERATED ALWAYS AS IDENTITY`. |
| Time | `timestamptz` everywhere, stored in UTC. Wall-clock values that are deliberately local use `time` plus an IANA timezone. |
| Enumerations | `text` + `CHECK (… IN …)`. Easier to evolve than PG enums. |
| Naming | `snake_case`, plural tables. Constraint names via the Alembic naming convention (`pk_`, `fk_`, `uq_`, `ck_`, `ix_`). |
| Ownership | Every user-owned row has `user_id`. Same-owner relationships are enforced **in the database** with composite foreign keys `(x_id, user_id) → x(id, user_id)`, so a row can never link to another user's contact, step or instruction. |
| Soft delete | Only where history must survive (`trusted_contacts`, `instructions`). On soft delete, PII/content is **scrubbed immediately** (set to NULL). |
| Timestamps | `created_at` / `updated_at` (`updated_at` maintained by the application layer). |
| Sensitive content | Instruction content is stored only as AES-256-GCM ciphertext ([SECURITY §6](SECURITY.md#6-cryptography)). |
| Pseudonymous hashes | `*_hash bytea` = SHA-256 for random tokens; HMAC-SHA256 with a server pepper for low-entropy values (IPs, OTP codes, emails used for suppression). |
| Terminology | **Stage** in the UI = `escalation_steps` in the database. |

## 2. Entity overview

```
users ─┬─ user_profiles (1:1)
       ├─ user_keys (1:1)                       per-user wrapped DEK
       ├─ sessions ── refresh_tokens
       ├─ auth_tokens                           verify email / reset / email change / web deletion
       ├─ devices                               FCM tokens
       ├─ trusted_contacts ── contact_verifications
       ├─ checkin_configurations (1:1)          also the per-user LOCK row
       ├─ checkin_events
       ├─ escalation_plans (1:1 in 1.0)
       │     └─ escalation_steps ── escalation_step_contacts ──▶ trusted_contacts
       ├─ instructions ── instruction_recipients ──▶ trusted_contacts, escalation_steps
       ├─ escalation_incidents
       │     ├─ incident_actions
       │     ├─ release_events ──▶ instructions, trusted_contacts
       │     └─ portal_access ── portal_tokens
       │                      └─ portal_sessions ── portal_otp_challenges
       ├─ notifications ── notification_logs
       └─ subscriptions

instruction_categories (reference data)
email_suppressions     (global opt-out / bounce list; no user FK)
audit_logs             (append-only; NO FK so history survives deletion)
system_flags, system_holds, ingestion_probes, service_heartbeats, rate_limit_counters
```

## 3. Schema

> This is the target schema for the initial migrations. Columns marked *(1.1)* are reserved and are not created until needed.

### 3.1 Identity and access

```sql
CREATE TABLE users (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email                 text NOT NULL CHECK (char_length(email) <= 254),
  email_normalized      text NOT NULL UNIQUE,              -- lower(trim(email))
  email_verified_at     timestamptz,
  password_hash         text NOT NULL,                      -- Argon2id PHC string
  password_changed_at   timestamptz NOT NULL DEFAULT now(),
  status                text NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active','pending_deletion','suspended')),
  tier                  text NOT NULL DEFAULT 'free' CHECK (tier IN ('free','premium')),
  deletion_requested_at timestamptz,
  failed_login_count    smallint NOT NULL DEFAULT 0,
  locked_until          timestamptz,
  last_login_at         timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_profiles (
  user_id        uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  display_name   text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 80),
  phone_e164     text CHECK (phone_e164 ~ '^\+[1-9][0-9]{6,14}$'),
  country_code   char(2),                                   -- ISO 3166-1 alpha-2
  timezone       text NOT NULL,                             -- IANA; validated against zoneinfo in app
  locale         text NOT NULL DEFAULT 'en',
  -- photo_object_key text  (1.1)
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_keys (                                    -- envelope encryption
  user_id      uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  wrapped_dek  bytea NOT NULL,
  kek_id       text  NOT NULL,                              -- KMS key resource name + version
  dek_version  integer NOT NULL DEFAULT 1,
  created_at   timestamptz NOT NULL DEFAULT now(),
  rotated_at   timestamptz
);

CREATE TABLE devices (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform               text NOT NULL CHECK (platform IN ('android')),
  push_token             text,
  push_token_updated_at  timestamptz,
  app_version            text,
  os_version             text,
  locale                 text,
  created_at             timestamptz NOT NULL DEFAULT now(),
  last_seen_at           timestamptz NOT NULL DEFAULT now(),
  revoked_at             timestamptz
);
CREATE UNIQUE INDEX uq_devices_push_token ON devices(push_token) WHERE push_token IS NOT NULL;
CREATE INDEX ix_devices_user ON devices(user_id) WHERE revoked_at IS NULL;

CREATE TABLE sessions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind                 text NOT NULL CHECK (kind IN ('app','web')),
  device_id            uuid REFERENCES devices(id) ON DELETE SET NULL,
  web_token_hash       bytea UNIQUE,                        -- web sessions only (cookie value, hashed)
  auth_method          text NOT NULL DEFAULT 'password',
  reauthenticated_at   timestamptz,                         -- step-up for I'M SAFE, deletion, export
  created_at           timestamptz NOT NULL DEFAULT now(),
  last_used_at         timestamptz NOT NULL DEFAULT now(),
  idle_expires_at      timestamptz NOT NULL,
  absolute_expires_at  timestamptz NOT NULL,
  revoked_at           timestamptz,
  revoke_reason        text CHECK (revoke_reason IN ('logout','logout_all','password_changed',
                         'password_reset','reuse_detected','account_deleted','operator','expired')),
  ip_hash              bytea,
  user_agent           text CHECK (char_length(user_agent) <= 200)
);
CREATE INDEX ix_sessions_user_active ON sessions(user_id) WHERE revoked_at IS NULL;

CREATE TABLE refresh_tokens (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id   uuid NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  token_hash   bytea NOT NULL UNIQUE,                       -- SHA-256 of 256-bit random token
  issued_at    timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  used_at      timestamptz,
  replaced_by  uuid REFERENCES refresh_tokens(id) ON DELETE SET NULL
);
CREATE INDEX ix_refresh_tokens_session ON refresh_tokens(session_id);

CREATE TABLE auth_tokens (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose      text NOT NULL CHECK (purpose IN ('signup_verify','email_change',      -- 6-digit codes
                                                'password_reset','account_delete_web')), -- links
  kind         text NOT NULL CHECK (kind IN ('code','link')),
  secret_hash  bytea NOT NULL,       -- link: SHA-256(256-bit token); code: HMAC(pepper, user_id||code)
  payload      jsonb,                -- e.g. new email for email_change
  attempts     smallint NOT NULL DEFAULT 0,                 -- codes: max 5
  expires_at   timestamptz NOT NULL,                        -- codes 15 min; reset 30 min; delete 24 h
  used_at      timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_auth_tokens_link ON auth_tokens(secret_hash) WHERE kind = 'link';
CREATE INDEX ix_auth_tokens_user_purpose ON auth_tokens(user_id, purpose) WHERE used_at IS NULL;
```

Codes are looked up by `(user_id, purpose)` (latest unused), never by hash. Links (`password_reset`) are looked up by the SHA-256 of the presented token (unique partial index `uq_auth_tokens_link`) and must be unused and unexpired. `email_change` codes carry `payload = {"email": <new address as typed>, "email_normalized": <lower(trim)>}`. Issuing a new code or link invalidates earlier unused ones of the same purpose. Signups that are never verified (`users.email_verified_at IS NULL`) are purged after 24 h. Phase 2 (reset links, email change) needed no schema change and added no migration.

**Refresh rotation.** Each refresh marks the presented token `used_at` and issues a successor. If an already-used token is presented **within 30 s** of `used_at` and its successor has not yet been used, this is treated as a network retry: the successor is invalidated and a new one issued. Any other reuse is treated as theft: the whole session is revoked (`reuse_detected`) and a security email is sent.

### 3.2 Trusted contacts

```sql
CREATE TABLE trusted_contacts (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  display_name           text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 80),
  relationship           text NOT NULL CHECK (relationship IN ('mother','father','parent','spouse',
                           'partner','sibling','child','relative','friend','neighbor','employer',
                           'colleague','other')),
  relationship_label     text CHECK (char_length(relationship_label) <= 40),
  email                  text CHECK (char_length(email) <= 254),
  email_normalized       text,
  phone_e164             text CHECK (phone_e164 ~ '^\+[1-9][0-9]{6,14}$'),
  priority               smallint NOT NULL DEFAULT 100
                         CHECK (priority BETWEEN 1 AND 999),          -- added in Phase 3: matches the API
  verification_status    text NOT NULL DEFAULT 'pending'
                         CHECK (verification_status IN ('pending','verified','declined',
                                                        'opted_out','bounced')),
  verified_at            timestamptz,
  status_changed_at      timestamptz NOT NULL DEFAULT now(),
  is_active              boolean NOT NULL DEFAULT true,
  invitation_sent_at     timestamptz,
  invitation_send_count  smallint NOT NULL DEFAULT 0,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_trusted_contacts_id_user UNIQUE (id, user_id),
  CONSTRAINT ck_trusted_contacts_email_present CHECK (deleted_at IS NOT NULL OR email IS NOT NULL)
);
CREATE UNIQUE INDEX uq_trusted_contacts_user_email
  ON trusted_contacts(user_id, email_normalized) WHERE deleted_at IS NULL;
CREATE INDEX ix_trusted_contacts_user ON trusted_contacts(user_id) WHERE deleted_at IS NULL;

CREATE TABLE contact_verifications (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id             uuid NOT NULL REFERENCES trusted_contacts(id) ON DELETE CASCADE,
  channel                text NOT NULL DEFAULT 'email' CHECK (channel IN ('email')),
  token_hash             bytea NOT NULL UNIQUE,
  sent_at                timestamptz NOT NULL DEFAULT now(),
  expires_at             timestamptz NOT NULL,                -- 14 days
  responded_at           timestamptz,
  response               text CHECK (response IN ('accepted','declined')),
  consent_text_version   text NOT NULL,                       -- which wording they agreed to
  ip_hash                bytea,
  created_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_contact_verifications_contact ON contact_verifications(contact_id);

CREATE TABLE email_suppressions (                             -- global, cross-user
  email_hash         bytea PRIMARY KEY,                         -- HMAC(pepper, email_normalized)
  reason             text NOT NULL CHECK (reason IN ('contact_block_all','hard_bounce','complaint')),
  source_contact_id  uuid,                                      -- informational, no FK
  created_at         timestamptz NOT NULL DEFAULT now()
);
```

**Phase 3 (migration `0002`, implemented) notes.**
* The DDL above is what the migration creates, plus one constraint: `priority BETWEEN 1 AND 999` (named `ck_trusted_contacts_priority_range`); the other checks carry the Alembic names `ck_trusted_contacts_*` and `ck_contact_verifications_*`.
* `email` and `email_normalized` hold the same trimmed, lower-cased address of a live contact. Soft delete sets `deleted_at` and sets `email`, `email_normalized`, `phone_e164` and `relationship_label` to `NULL`; `display_name` is kept.
* An invitation is *invalidated* (replaced by a newer one, contact deleted or opted out, address changed) by setting `expires_at` to that instant, so `responded_at IS NULL AND expires_at > now()` means "can still be answered". The API role cannot delete invitations.
* `consent_text_version` is stored when the invitation is created and set again with the answer (`2026-10-v1` in Phase 3).
* Rate limits that protect contacts (`contact_create_user`, `invitation_user`, `invitation_resend_contact`, `web_contact_ip`) live in `rate_limit_counters`; the opt-out token is stateless (an HMAC of the contact ID and the normalised address it was issued for), so it needs no table.
* `email_suppressions.email_hash` is `HMAC(pepper, "email_suppression" context, normalised address)`; lookups also try the previous pepper during rotation. No foreign key to users: the list is global.

### 3.3 Check-in

```sql
CREATE TABLE checkin_configurations (                         -- created at signup; per-user LOCK row
  user_id                uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  interval_days          smallint NOT NULL DEFAULT 1 CHECK (interval_days BETWEEN 1 AND 30),
  due_local_time         time NOT NULL DEFAULT '20:00',
  reminder_lead_minutes  smallint NOT NULL DEFAULT 60
                         CHECK (reminder_lead_minutes IN (0,30,60,120,240)),
  status                 text NOT NULL DEFAULT 'inactive'
                         CHECK (status IN ('inactive','active','incident_open')),
  baseline_at            timestamptz,                         -- last check-in or schedule change
  last_checkin_at        timestamptz,
  next_due_at            timestamptz,
  activated_at           timestamptz,
  version                integer NOT NULL DEFAULT 1,          -- ETag for optimistic concurrency
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_checkin_cfg_active_has_due
    CHECK (status = 'inactive' OR (next_due_at IS NOT NULL AND baseline_at IS NOT NULL))
);
CREATE INDEX ix_checkin_cfg_due ON checkin_configurations(next_due_at) WHERE status = 'active';

CREATE TABLE checkin_events (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind                 text NOT NULL CHECK (kind IN ('ok','safe')),
  source               text NOT NULL CHECK (source IN ('app','web')),
  received_at          timestamptz NOT NULL,                  -- Clock.now() (DB time) — authoritative
  client_reported_at   timestamptz,                           -- informational only
  idempotency_key      text NOT NULL CHECK (char_length(idempotency_key) BETWEEN 16 AND 64),
  session_id           uuid REFERENCES sessions(id) ON DELETE SET NULL,
  device_id            uuid REFERENCES devices(id) ON DELETE SET NULL,
  incident_id          uuid,                                  -- FK added after incidents table
  response_snapshot    jsonb NOT NULL,                        -- for idempotent replay
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_checkin_events_idem UNIQUE (user_id, idempotency_key)
);
CREATE INDEX ix_checkin_events_user_time ON checkin_events(user_id, received_at DESC);
```

**Phase 4 (migration `0003`, implemented) notes.**
* `checkin_events` and its index are created exactly as above, with two differences: `incident_id` is a plain nullable `uuid` with **no foreign key** until the incidents table exists (the Phase 5 migration adds it), and the unique constraint is declared as `uq_checkin_events_idem`.
* **Append-only.** `afterme_api` and `afterme_worker` have `SELECT, INSERT` only (no `UPDATE`, no `DELETE`, no `TRUNCATE`). A user's rows leave with the account through `ON DELETE CASCADE`. `afterme_maintenance` has `DELETE` and `SELECT (id, received_at)` for the 400-day purge.
* `response_snapshot` holds the exact JSON returned to the caller; an idempotent replay returns it verbatim.
* `checkin_configurations.version` is the schedule's ETag. It is incremented on a schedule change, activate, deactivate and a timezone change, **not** on a check-in. On deactivation `baseline_at`, `next_due_at` and `activated_at` are set to `NULL` and `last_checkin_at` is kept. `last_checkin_at` and `baseline_at` never go backwards, and every restart of the clock (check-in, schedule change, activation, timezone change) stamps `baseline_at` with at least the last check-in's time, so `baseline_at >= received_at` of every recorded check-in (the engine treats the opposite as an inconsistency, ESCALATION_ENGINE §6.3). The request's `now` is the start of its transaction and can precede a check-in that committed while it waited for the lock.

### 3.4 Escalation plan

```sql
CREATE TABLE escalation_plans (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  grace_minutes  integer NOT NULL DEFAULT 180 CHECK (grace_minutes BETWEEN 60 AND 4320),
  version        integer NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_escalation_plans_user UNIQUE (user_id)       -- relaxed for multiple plans (1.2)
);

CREATE TABLE escalation_steps (                               -- "stages" in the UI
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id         uuid NOT NULL REFERENCES escalation_plans(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  position        smallint NOT NULL CHECK (position >= 1),
  offset_minutes  integer NOT NULL CHECK (offset_minutes BETWEEN 60 AND 43200),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_escalation_steps_id_user UNIQUE (id, user_id),
  CONSTRAINT uq_escalation_steps_position UNIQUE (plan_id, position) DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT uq_escalation_steps_offset UNIQUE (plan_id, offset_minutes) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE escalation_step_contacts (                       -- who is NOTIFIED at a stage
  step_id     uuid NOT NULL,
  contact_id  uuid NOT NULL,
  user_id     uuid NOT NULL,
  PRIMARY KEY (step_id, contact_id),
  FOREIGN KEY (step_id, user_id)    REFERENCES escalation_steps(id, user_id) ON DELETE CASCADE,
  FOREIGN KEY (contact_id, user_id) REFERENCES trusted_contacts(id, user_id) ON DELETE CASCADE
);
```

Cross-row rules are enforced in the service layer inside the plan-update transaction (under the per-user lock) and re-checked by the engine gate:
stage 1 offset = `grace_minutes`; offsets strictly increasing with gaps ≥ 30 min; stage count ≤ the tier limit; any stage referenced by `instruction_recipients.release_step_id` has offset ≥ 1440.

**Phase 5 (migration `0004`, implemented) notes.**
* Creates `escalation_plans`, `escalation_steps`, `escalation_step_contacts`, `escalation_incidents`, `incident_actions`, `notifications`, `notification_logs`, `system_holds`, `ingestion_probes` and `service_heartbeats` as specified, and the foreign key `checkin_events.incident_id → escalation_incidents(id) ON DELETE SET NULL`. Release and portal tables arrive with instructions (Phase 6).
* **Grants make INV-1 a fact of the database.** `afterme_api`: DML on the three plan tables; `SELECT` on incidents, actions, logs and holds; **no `INSERT`** on `escalation_incidents` or `incident_actions`; `UPDATE` only on `status, closed_at, closed_by, updated_at` (incidents), `status, updated_at` (actions) and `status, cancelled_reason, updated_at` (notifications); `SELECT, INSERT` on `notifications`; `INSERT` (no read-back) on `ingestion_probes`. `afterme_worker`: DML on everything the engine owns, `SELECT, INSERT` on `notification_logs`, `SELECT` on probes. `afterme_maintenance`: `DELETE` plus the filtered columns on probes, notifications and logs.
* **Dedupe keys.** Actions: `incident:{incident_id}:{kind}:{variant|stage_id}`. Notifications derived from an action carry the instant the action was scheduled for: `notif:{action_id}:{scheduled_epoch}:{channel}[:{device}]` and `notif:{action_id}:{scheduled_epoch}:contact:{contact_id}:email`, so a stage that a Hold rolled back and shifted can queue its messages again without colliding with the cancelled ones. Others: `prereminder:{user}:{due_at}:{channel}[:{device}]`, `allclear:{incident}:{contact}`, `allclear-user:{incident}:{channel}`, `holdnotice:{hold}:{user}:{channel}`.
* A Hold blocks contact-facing work until `exit_processed_at` is set, not merely `ended_at`.
* **Migration `0005` (found by the independent review, ESCALATION_ENGINE §13.2) adds three `BEFORE` triggers** because column grants cannot say which *values* a role may write. For `afterme_api` only (they test `current_user`): `notifications` accept an `INSERT` only of a `queued` row outside `contact_escalation`, and an `UPDATE` only of `queued → cancelled`; `incident_actions` only `pending → cancelled`; `escalation_incidents` only *open → closed* with `closed_at` previously null. A compromised API role therefore cannot forge an escalation message, requeue a sent one, mark an action executed or reopen a closed incident. It also takes from `afterme_worker` what it never used: `INSERT/UPDATE/DELETE` on the plan tables (it reads them) and `DELETE` on incidents, actions and notifications (retention belongs to `afterme_maintenance`).
* `ingestion_probes` has no sensitive content; the worker records the scan position in `system_flags` (`probe_watermark`).

### 3.5 Instructions

```sql
CREATE TABLE instruction_categories (                         -- seeded by migration
  id          text PRIMARY KEY CHECK (id ~ '^[a-z_]{2,32}$'),
  sort_order  smallint NOT NULL,
  is_active   boolean NOT NULL DEFAULT true
);
-- seed: personal, family, home, work, business, documents, insurance, pets, travel,
--       digital_accounts, other   (labels are localised in the app/portal by id)

CREATE TABLE instructions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  category_id          text NOT NULL REFERENCES instruction_categories(id),
  status               text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
  content_ciphertext   bytea,                                 -- AES-256-GCM of {"title","body"}
  content_key_version  integer NOT NULL,
  content_version      integer NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_instructions_id_user UNIQUE (id, user_id),
  CONSTRAINT ck_instructions_content CHECK (deleted_at IS NOT NULL OR content_ciphertext IS NOT NULL)
);
CREATE INDEX ix_instructions_user ON instructions(user_id) WHERE deleted_at IS NULL;

CREATE TABLE instruction_recipients (                         -- WHO gets WHAT, WHEN
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  instruction_id   uuid NOT NULL,
  contact_id       uuid NOT NULL,
  release_step_id  uuid NOT NULL,
  user_id          uuid NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_instruction_recipients UNIQUE (instruction_id, contact_id),
  FOREIGN KEY (instruction_id, user_id)  REFERENCES instructions(id, user_id)     ON DELETE CASCADE,
  FOREIGN KEY (contact_id, user_id)      REFERENCES trusted_contacts(id, user_id) ON DELETE CASCADE,
  FOREIGN KEY (release_step_id, user_id) REFERENCES escalation_steps(id, user_id) ON DELETE RESTRICT
);
CREATE INDEX ix_instruction_recipients_step ON instruction_recipients(release_step_id);

-- instruction_attachments  (1.1, Premium) — object key, size, mime, wrapped key, scan status
```

`ON DELETE RESTRICT` on `release_step_id` means a stage can't be removed while instructions are assigned to it. The API returns `409 stage_in_use` with the affected instruction IDs.

### 3.6 Incidents and timeline

```sql
CREATE TABLE escalation_incidents (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  plan_id               uuid NOT NULL REFERENCES escalation_plans(id) ON DELETE CASCADE,
  plan_version          integer NOT NULL,
  plan_snapshot         jsonb NOT NULL,                       -- IDs only; see ESCALATION_ENGINE §5.4
  missed_due_at         timestamptz NOT NULL,
  opened_at             timestamptz NOT NULL,
  anchor_at             timestamptz NOT NULL,                 -- max(missed_due_at, opened_at)
  grace_ends_at         timestamptz NOT NULL,
  status                text NOT NULL DEFAULT 'grace'
                        CHECK (status IN ('grace','escalating','escalated',
                                          'resolved','cancelled','voided')),
  contacts_messaged_at  timestamptz,                          -- set by dispatcher (§4.2 engine)
  closed_at             timestamptz,
  closed_by             text CHECK (closed_by IN ('user_checkin','user_safe',
                                                  'account_deleted','operator_void')),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_incidents_user_missed UNIQUE (user_id, missed_due_at),
  CONSTRAINT ck_incidents_closed CHECK
    ((status IN ('resolved','cancelled','voided')) = (closed_at IS NOT NULL)),
  CONSTRAINT ck_incidents_anchor CHECK (anchor_at >= missed_due_at AND anchor_at >= opened_at)
);
CREATE UNIQUE INDEX uq_incidents_one_open ON escalation_incidents(user_id)
  WHERE status IN ('grace','escalating','escalated');

ALTER TABLE checkin_events
  ADD CONSTRAINT fk_checkin_events_incident
  FOREIGN KEY (incident_id) REFERENCES escalation_incidents(id) ON DELETE SET NULL;

CREATE TABLE incident_actions (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id             uuid NOT NULL REFERENCES escalation_incidents(id) ON DELETE CASCADE,
  user_id                 uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind                    text NOT NULL CHECK (kind IN ('user_reminder','user_final_warning',
                                                        'execute_stage')),
  variant                 text CHECK (variant IN ('missed','midpoint','last_chance')),
  step_id                 uuid,                               -- from snapshot; no FK (history)
  scheduled_for           timestamptz NOT NULL,
  original_scheduled_for  timestamptz NOT NULL,               -- before any Hold shift
  status                  text NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending','executed','cancelled','held')),
  attempt_count           smallint NOT NULL DEFAULT 0,
  last_error_class        text,                               -- exception class only, no message
  executed_at             timestamptz,
  outcome                 jsonb,                              -- per-target results (IDs + reason codes)
  dedupe_key              text NOT NULL UNIQUE,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_incident_actions_due ON incident_actions(scheduled_for) WHERE status = 'pending';
CREATE INDEX ix_incident_actions_incident ON incident_actions(incident_id);
```

### 3.7 Releases and recipient portal

```sql
CREATE TABLE release_events (                                 -- "instruction X released to contact Y"
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  incident_id      uuid NOT NULL REFERENCES escalation_incidents(id) ON DELETE CASCADE,
  action_id        uuid NOT NULL REFERENCES incident_actions(id) ON DELETE CASCADE,
  instruction_id   uuid NOT NULL REFERENCES instructions(id),
  contact_id       uuid NOT NULL REFERENCES trusted_contacts(id),
  step_id          uuid NOT NULL,
  released_at      timestamptz NOT NULL,
  visible_after    timestamptz NOT NULL,                      -- released_at + SETTLE_DELAY
  revoked_at       timestamptz,
  revoke_reason    text CHECK (revoke_reason IN ('user_safe','user_checkin','instruction_removed',
                     'contact_removed','contact_opted_out','account_deleted','hold_rollback',
                     'operator')),
  first_viewed_at  timestamptz,
  last_viewed_at   timestamptz,
  view_count       integer NOT NULL DEFAULT 0,
  CONSTRAINT uq_release_events UNIQUE (incident_id, instruction_id, contact_id)
);
CREATE INDEX ix_release_events_incident_contact ON release_events(incident_id, contact_id);

CREATE TABLE portal_access (                                  -- one per (incident, contact) with releases
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  incident_id  uuid NOT NULL REFERENCES escalation_incidents(id) ON DELETE CASCADE,
  contact_id   uuid NOT NULL REFERENCES trusted_contacts(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz,
  CONSTRAINT uq_portal_access UNIQUE (incident_id, contact_id)
);

CREATE TABLE portal_tokens (                                  -- link tokens; minted by dispatcher
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  access_id        uuid NOT NULL REFERENCES portal_access(id) ON DELETE CASCADE,
  token_hash       bytea NOT NULL UNIQUE,
  notification_id  uuid,                                      -- which email carried it
  created_at       timestamptz NOT NULL DEFAULT now(),
  expires_at       timestamptz NOT NULL,                      -- 30 days
  first_used_at    timestamptz
);

CREATE TABLE portal_sessions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  access_id       uuid NOT NULL REFERENCES portal_access(id) ON DELETE CASCADE,
  session_hash    bytea NOT NULL UNIQUE,                      -- cookie value, hashed
  created_at      timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL,                       -- 60 min
  otp_verified_at timestamptz,
  elevated_until  timestamptz,                                -- otp_verified_at + 15 min
  ip_hash         bytea,
  revoked_at      timestamptz
);

CREATE TABLE portal_otp_challenges (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  portal_session_id  uuid NOT NULL REFERENCES portal_sessions(id) ON DELETE CASCADE,
  code_hash          bytea NOT NULL,                          -- HMAC(pepper, code)
  created_at         timestamptz NOT NULL DEFAULT now(),
  expires_at         timestamptz NOT NULL,                    -- 10 min
  attempts           smallint NOT NULL DEFAULT 0,             -- max 5
  consumed_at        timestamptz
);
CREATE INDEX ix_portal_otp_session ON portal_otp_challenges(portal_session_id);
```

**Phase 6 (migration `0006`, implemented) notes.**
* Creates `user_keys`, `instruction_categories` (seeded with the eleven categories), `instructions`, `instruction_recipients`, `release_events`, `portal_access`, `portal_tokens`, `portal_sessions` and `portal_otp_challenges` as specified in §3.5 and §3.7. `release_events.revoke_reason` also allows `recipient_removed`, and a CHECK ties `revoked_at` and `revoke_reason` together.
* **Grants keep the content boundary in the database.** `afterme_api`: read and write instructions and recipients; `SELECT, INSERT` on `user_keys` (no update or delete); `SELECT` on releases, portal access and tokens, with `UPDATE` limited to `revoked_at`, `revoke_reason` and the view counters (releases), `revoked_at` (access) and `first_used_at` (tokens); `INSERT` and a column-limited `UPDATE` on portal sessions and one-time-code challenges. It can **not** insert releases, portal access or tokens: those are the engine's (INV-1). A trigger refuses any change to a revoked release or access by the API role: revocation is one way. `afterme_worker`: `SELECT` on `instructions` for every column **except** `content_ciphertext`, nothing on `user_keys`; `SELECT, INSERT, UPDATE` on releases and portal access; `SELECT, INSERT` on tokens (the dispatcher mints them when a message is sent, storing only the hash). `afterme_maintenance`: `DELETE` of expired tokens, sessions and challenges.
* `instruction_recipients.release_step_id` refuses to leave a stage while an instruction is assigned to it, but the constraint is `DEFERRABLE INITIALLY DEFERRED` (checked at commit): a plain `RESTRICT` made deleting a whole account depend on the order its rows cascade in. Contacts are soft-deleted, so deleting a contact removes their recipient rows explicitly (and takes back their releases).
* A release revoked by a Hold rollback is brought back by the stage running again (the unique `(incident, instruction, contact)` row is reused); a release revoked for any other reason is never brought back.

### 3.8 Notifications (outbox)

```sql
CREATE TABLE notifications (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,  -- account owner
  audience             text NOT NULL CHECK (audience IN ('user','contact')),
  category             text NOT NULL CHECK (category IN ('user','contact_escalation','contact_other')),
  contact_id           uuid REFERENCES trusted_contacts(id),
  device_id            uuid REFERENCES devices(id) ON DELETE SET NULL,
  channel              text NOT NULL CHECK (channel IN ('push','email','sms')),
  template_key         text NOT NULL,
  template_version     smallint NOT NULL DEFAULT 1,
  params               jsonb NOT NULL DEFAULT '{}',           -- IDs/times only; NO content or addresses
  incident_id          uuid REFERENCES escalation_incidents(id) ON DELETE CASCADE,
  action_id            uuid REFERENCES incident_actions(id) ON DELETE SET NULL,
  status               text NOT NULL DEFAULT 'queued'
                       CHECK (status IN ('queued','sending','sent','failed','cancelled')),
  send_after           timestamptz NOT NULL,
  attempt_count        smallint NOT NULL DEFAULT 0,
  next_attempt_at      timestamptz,
  provider             text,
  provider_message_id  text,
  cancelled_reason     text,
  dedupe_key           text NOT NULL UNIQUE,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  sent_at              timestamptz,
  CONSTRAINT ck_notifications_contact CHECK ((audience = 'contact') = (contact_id IS NOT NULL)),
  CONSTRAINT ck_notifications_escalation CHECK
    (category <> 'contact_escalation' OR (incident_id IS NOT NULL AND action_id IS NOT NULL))
);
CREATE INDEX ix_notifications_due ON notifications(send_after) WHERE status = 'queued';
CREATE INDEX ix_notifications_incident ON notifications(incident_id);
CREATE INDEX ix_notifications_user_time ON notifications(user_id, created_at DESC);

CREATE TABLE notification_logs (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  notification_id      uuid NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
  attempted_at         timestamptz NOT NULL DEFAULT now(),
  provider             text NOT NULL,
  outcome              text NOT NULL CHECK (outcome IN ('accepted','rejected','error','delivered',
                                                        'bounced','complained')),
  provider_message_id  text,
  error_code           text,                                  -- provider code only; no PII
  latency_ms           integer
);
CREATE INDEX ix_notification_logs_notification ON notification_logs(notification_id);
```

Recipient **addresses are resolved at send time** from `user_profiles`/`users`/`trusted_contacts`/`devices`. This means opt-outs and edits are respected, and the outbox never duplicates PII.

### 3.9 Audit

```sql
CREATE TABLE audit_logs (                                     -- append-only
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at      timestamptz NOT NULL DEFAULT now(),
  actor_type       text NOT NULL CHECK (actor_type IN ('user','contact','system','operator')),
  actor_id         uuid,
  subject_user_id  uuid,                                      -- NO FK: survives deletion (pseudonymous)
  action           text NOT NULL,                             -- e.g. 'checkin.recorded'
  resource_type    text,
  resource_id      uuid,
  request_id       text,
  ip_hash          bytea,
  user_visible     boolean NOT NULL DEFAULT false,            -- shown in Activity feed
  metadata         jsonb NOT NULL DEFAULT '{}'                -- non-sensitive only
);
CREATE INDEX ix_audit_subject_time ON audit_logs(subject_user_id, occurred_at DESC);
CREATE INDEX ix_audit_action_time ON audit_logs(action, occurred_at DESC);
```

Action names are listed in [SECURITY §9](SECURITY.md#9-audit-logging). Monthly partitioning can be added when volume justifies it.

### 3.10 Billing

```sql
CREATE TABLE subscriptions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider            text NOT NULL CHECK (provider IN ('google_play')),
  product_id          text NOT NULL,
  purchase_token      text NOT NULL UNIQUE,                   -- needed for Play Developer API calls
  status              text NOT NULL CHECK (status IN ('active','in_grace','on_hold','paused',
                                                      'cancelled','expired','revoked')),
  current_period_end  timestamptz,
  auto_renewing       boolean,
  last_verified_at    timestamptz NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_subscriptions_user ON subscriptions(user_id);
```

`users.tier` is a cached value derived from subscriptions and updated by the billing service. Entitlement checks read `users.tier`.

### 3.11 System and operations

```sql
CREATE TABLE system_flags (
  key         text PRIMARY KEY,                               -- e.g. 'probe_watermark', 'min_client_version'
  value       jsonb NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  text NOT NULL
);

CREATE TABLE system_holds (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reason             text NOT NULL CHECK (reason IN ('ingestion','anomaly','operator')),
  started_at         timestamptz NOT NULL,                    -- may be backdated (last good probe)
  detected_at        timestamptz NOT NULL,
  ended_at           timestamptz,
  exit_processed_at  timestamptz,                             -- rollback + shift applied
  created_by         text NOT NULL,
  notes              text
);
CREATE INDEX ix_system_holds_open ON system_holds(started_at) WHERE ended_at IS NULL;

CREATE TABLE ingestion_probes (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  received_at  timestamptz NOT NULL DEFAULT now(),
  source       text NOT NULL
);
CREATE INDEX ix_ingestion_probes_time ON ingestion_probes(received_at);

CREATE TABLE service_heartbeats (
  service       text NOT NULL,
  instance_id   text NOT NULL,
  last_beat_at  timestamptz NOT NULL,
  started_at    timestamptz NOT NULL,
  version       text NOT NULL,
  PRIMARY KEY (service, instance_id)
);

CREATE UNLOGGED TABLE rate_limit_counters (                   -- non-authoritative; loss on crash is OK
  key           text NOT NULL,                                -- e.g. 'login:ip:<hash>'
  window_start  timestamptz NOT NULL,
  count         integer NOT NULL,
  expires_at    timestamptz NOT NULL,
  PRIMARY KEY (key, window_start)
);
```

## 4. Deletion behaviour

| Trigger | Behaviour |
|---|---|
| **Account deletion requested** | Same transaction: `users.status = 'pending_deletion'`; open incident → `voided` (all-clear to contacts already messaged); all releases revoked; schedule `inactive`; all sessions revoked; devices revoked; instruction ciphertext set to NULL and instructions soft-deleted; contact PII scrubbed; `user_keys` row deleted. **Hard delete** of the `users` row (cascading to all owned rows) by a maintenance job after 30 days. Audit rows remain with a pseudonymous `subject_user_id` until their retention ends. |
| **Contact deleted** | Soft delete; `email`/`phone` set to NULL; step and recipient links deleted; open-incident releases to them revoked. `display_name` is kept for the user's own history. |
| **Instruction deleted** | Soft delete; `content_ciphertext` set to NULL; recipients deleted; open-incident releases revoked. |
| **Stage removed** | Blocked (`RESTRICT`) while instructions are assigned to it. |
| **Device revoked / logout** | Session revoked; device push token cleared. |

Backups: deleted data disappears from live systems immediately and from backups once they age out (≤ 35 days, [DEPLOYMENT §6](DEPLOYMENT.md#6-backups-and-recovery)). The privacy policy states this.

## 5. Retention

| Data | Retention |
|---|---|
| Check-in events | 400 days, then deleted (counts kept as aggregates) |
| Incidents, actions, releases | Life of account |
| Notifications + logs | 90 days |
| Audit logs | 1 year (needs legal confirmation; [PRD D10](PRD.md#15-decisions-needed-from-the-product-owner)) |
| Expired auth/refresh/portal tokens, sessions | Purged 30 days after expiry or revocation |
| Ingestion probes | 30 days |
| Rate-limit counters | Until `expires_at` |
| Users pending deletion | Hard-deleted after 30 days |

A daily maintenance job (worker loop or scheduled job) runs the purges in small batches.

## 6. Database roles and grants

A real defense-in-depth layer for **INV-1 (backend authority)**: the API role **cannot create** incidents, timeline actions or releases.

| Role | Used by | Privileges |
|---|---|---|
| `afterme_owner` | Migrations only | Owns schema; DDL |
| `afterme_api` | `api` process | DML on app tables, **except**: no `INSERT` on `escalation_incidents`, `incident_actions`, `release_events`, `portal_access`, `portal_tokens`; `UPDATE` on those limited to columns used to *stop* or *observe* things (`status`, `closed_at`, `closed_by`, `revoked_at`, `revoke_reason`, view counters, `portal_tokens.first_used_at`, `updated_at`). `INSERT, SELECT` only on `audit_logs`. Phase 3: `SELECT, INSERT, UPDATE` (no `DELETE`) on `trusted_contacts` and `contact_verifications`, `SELECT, INSERT` only on `email_suppressions`. Phase 4: `SELECT, INSERT` only on `checkin_events` (append-only history). |
| `afterme_worker` | `worker` process | DML on app tables; `INSERT, SELECT` only on `audit_logs` |
| `afterme_maintenance` | Retention job | `DELETE` on purgeable tables, including old `audit_logs` and expired `contact_verifications` (Phase 3) |
| `afterme_readonly` | Future support/analytics | `SELECT` on non-sensitive tables; **no** access to `instructions.content_ciphertext`, `user_keys`, token tables |

The dispatcher only sends a `contact_escalation` notification if its `action_id` references an **executed `execute_stage` action of an open incident**. The API role can insert notifications (e.g. "send me a fresh link"), but it can't create actions, so it can't forge an escalation message.

## 7. Key queries and their indexes

| Query | Index |
|---|---|
| Due deadlines: `status='active' AND next_due_at <= :now` | `ix_checkin_cfg_due` (partial) |
| Due actions: `status='pending' AND scheduled_for <= :now` | `ix_incident_actions_due` (partial) |
| Due notifications: `status='queued' AND send_after <= :now` | `ix_notifications_due` (partial) |
| One open incident per user | `uq_incidents_one_open` (partial unique) |
| Check-in idempotency | `uq_checkin_events_idem` |
| Owner lists (contacts, instructions) | `ix_*_user` partial on `deleted_at IS NULL` |
| Activity feed | `ix_audit_subject_time` |

## 8. Migrations policy

1. Alembic, with autogenerate as a **starting point only**. Every migration is reviewed by hand.
2. One logical change per migration, with a descriptive name (`20261008_0001_initial_schema`).
3. **Expand → migrate → contract** for zero-downtime changes. Never drop or rename a column in the same release that stops using it.
4. CI runs `upgrade head → downgrade base → upgrade head` on an empty database, plus a schema-drift check (models vs migrations).
5. Production migrations run as a separate release step with the `afterme_owner` role, after a fresh backup snapshot.
6. Seed and reference data (categories, default flags) live in migrations. Test fixtures never do.
