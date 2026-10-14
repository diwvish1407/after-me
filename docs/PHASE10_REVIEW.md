# AfterMe — Phase 10 independent review

| | |
|---|---|
| **Status** | Findings dispositioned 2026-10-12 |
| **Scope** | Everything built in Phase 10: the Hold exit change, configuration bounds, `beta-report`, the operator `user` commands, `provision_roles.sql`, the game-day harness, the container image and workflows, the emulator helper, the mobile changes and the new documents |
| **Result** | **0 S1, 3 S2, 34 S3, 35 S4.** Nothing breaks INV-1…10 or can cause a wrongful alert or release. All three S2 and the safety-relevant S3 are fixed |

## Disposition

| Finding | Disposition |
|---|---|
| **BETA-1 (S2)** the report selected incidents by the day they opened | **Fixed**: listed when contacts were first messaged or the incident closed in the period, or while it is still open; tests for both directions |
| **D-1 (S2)** sessions and tokens never purged although the policy said they were | **Fixed**: retention rules and migration `0010` (sessions, refresh and auth tokens 30 days after expiry; devices 90 days idle; audit records `AUDIT_RETENTION_DAYS`) |
| **D-2 (S2)** policy said everything is erased 30 days after deletion | **Fixed in the draft**: pseudonymous audit records and opt-out hashes are named as what remains |
| BETA-2…BETA-5 | **Fixed**: Hold rule covers incidents opened inside a Hold, the header names the database, role and revision and refuses an unmigrated one, still-open incidents have their own line, a coverage line states what retention has already removed |
| USR-1 `unsuspend` left a dead incident | **Fixed**: refused while an incident is open (void it first); `status` warns |
| M-1 an incident push tap could be swallowed by the plan editor | **Fixed**: urgent types are never asked or dropped; Home is pushed on top of the draft; a save in flight is waited for |
| M-2 instruction titles carried across accounts on a shared phone | **Fixed**, with a mutation-checked test |
| D-33 contact screens had no `FLAG_SECURE` | **Fixed** (add, detail, edit, onboarding's first contact) |
| C-1 `emulator.yml` was invalid (`runner` in job-level `env`) | **Fixed**; all five workflows checked for context misuse |
| G-1…G-4, G-6, G-9 harness checks that could not fail; PG\* and pid-reaping hazards | **Fixed**; each named check has a unit test that makes it fail; 47 of 47 pass on the real processes |
| C-2 `integration.sh` / `dev_db_setup.sh` used inherited `PG*` | **Fixed**: refused unless the host is this machine |
| PROV-1 passwords visible in `ps` / DDL logs | **Documented** in the script header |
| CFG-1 `GRACE_MAX_MINUTES` / `STAGE_MAX_OFFSET_MINUTES` could exceed the database CHECKs | **Fixed** (start-up refusal) |
| D-3…D-11, D-14…D-35 documents that disagreed with the code | **Fixed** (policy and terms drafts, BETA_PLAN, TESTER_GUIDE, MANUAL_TEST_SHEET, GAMEDAYS, DEPLOYMENT, TEST_PLAN, ROADMAP, README) except: |
| D-10 key management: only the local KMS exists | **Open, by design**: the cloud adapter is a Phase 12 item; recorded as a counsel point |
| D-14 `/legal/privacy` and `/legal/terms` are served by nothing | **Open, owner action**: publish the final texts as static pages (BETA_PLAN entry checklist) |
| M-3, M-4 (parked pending records on `clear()`, clipboard exception class) and the remaining S4 | **Open**, listed in the report below |

---

## Report as delivered by the reviewer

# AfterMe Phase 10 independent review

Read-only. Nothing edited, staged, committed or run against PostgreSQL or the emulator. Severity scale: docs/TEST_PLAN.md section 11.
Confidence: CONFIRMED = code path traced (or document checked against code); PLAUSIBLE = depends on an environment I could not execute.

Method: areas 1-5 were read and traced by me. Areas 6 (game day), 7-8 (CI, Docker, it_host), 9 (mobile) and 10 (documents) were delegated to three read-only reviewers; I spot-verified their highest-impact claims (C-1 `runner` context in job env, M-1 swallowed notification tap, D-1 sessions never purged, D-14 no `/legal/*` route, D-18 no `afterme-admin` executable, Dockerfile CMD, build_release.sh shell guard) and carried the rest as reported.

## Counts

| Severity | Count |
|---|---|
| S1 (safety or privacy failure) | 0 |
| S2 | 3 (BETA-1, D-1, D-2) |
| S3 | 34 |
| S4 | 35 |

No finding breaks INV-1..10 or can cause a wrongful alert or release. The S2 items are: the review instrument can miss an incident that reached a contact (BETA-1), and two privacy-policy promises the retention job does not keep (D-1, D-2).

---

## Area 1: hold.py `_auto_exit` (SOUND, two small gaps)

The new rule is correct in every edge case I traced:

* Window = `now - HOLD_EXIT_FRESH` (600 s). Exit needs (a) at least one probe in the window, (b) a probe `before` the window start no more than INGESTION_STALE (180 s) earlier, (c) no gap above 180 s over `[before, *probes, now]`.
* Exactly-INGESTION_STALE gap: `> stale` fails the exit, `now - last <= stale` does not trigger entry. Consistent at both ends.
* Probe exactly at window start: it is in `times` (`>=`), `before` uses `<`; the gap before to start is still checked. Correct.
* Recovery at R: while `start <= R`, `before` is an outage-side probe L and the L to R gap is above stale, so no exit. First possible exit is `now > R + 600 s`, with `before == R`. The Hold therefore ends 10 continuous minutes after the first fresh probe, as documented (and the shift covers the extra minutes because the window end is the exit instant).
* Late single probe (gap 190 s) then regular probing: blocked until `before >= R2`. Correct.
* Hold with no probes ever (first deploy, monitor not yet configured): `last is None` starts the Hold at `now`; first probe at R exits at R + 600 s plus one tick. Correct and fail-safe.
* Retention: probes are kept 30 days (retention.py:58). A Hold would have to last 30 days to lose its `before` row.
* Multiple workers: `_serialise` takes the advisory lock in each transaction; `_auto_exit` reads and ends inside it.
* `_scan_probe_history` runs first in the same tick and `_overlaps_existing` is true for the open Hold, so the outage gap is not recorded a second time.

| ID | Sev | File:line | Finding | Conf |
|---|---|---|---|---|
| HOLD-1 | S4 | hold.py:211-223; config.py:183-184 | No config relation ties `HOLD_EXIT_FRESH_SECONDS` to the probe interval and tick. Scenario: `HOLD_EXIT_FRESH_SECONDS=30` with 60 s probes: the window holds a probe in only half of the ticks and `before` must also qualify; with 1-10 s the Hold can effectively never end, so nothing reaches contacts and every deadline keeps shifting. Default 600 is fine. A check "fresh >= probe interval + 2 ticks" in `_check_engine` would close it. Tests (test_hold.py:208-226) cover the 7-vs-10 minute regression only: no test for a gap of exactly stale inside the window, a probe exactly at the window start, or a missing `before`. | PLAUSIBLE (config), CONFIRMED (test gap) |

## Area 2: GRACE_MIN_MINUTES >= 60

Nothing sets it below 60 anywhere (tests/support.py, .env.example, docs, .github, scripts; grep over the whole tree). The check lives in `_check_engine`, called from `_check_hardening`, so it applies in every environment. The unit test is correct. README.md:240 does not list the new refusal (docs only).

| ID | Sev | File:line | Finding | Conf |
|---|---|---|---|---|
| CFG-1 | S4 | config.py:175-176, 179; migration 0004:127, 170; plans/models.py:34, 59 | The same class of mismatch is still open on the upper bounds: `GRACE_MAX_MINUTES` accepts up to 10 080 while the CHECK is `BETWEEN 60 AND 4320`; `STAGE_MAX_OFFSET_MINUTES` accepts up to 525 600 while the CHECK is `60..43200`. An operator who raises them gets a plan editor that accepts the value and an insert that fails with a 500. Not a safety issue (fails before saving). | CONFIRMED |

## Area 3: `beta-report` (app/ops/beta.py)

Checked and sound:

* Privacy: only UUIDs, counts, template keys, statuses, reason codes, times. No name, address, phone, instruction text or token column is selected anywhere (`_all_holds` leaves `notes`/name out; `plan_snapshot` is IDs only; `outcome` JSON is read only for `result` counters). Every text-column value passes `_label` (`[A-Za-z0-9_.:-]{1,64}`, no `@`, space or `+`, so addresses, phone numbers and provider prose become `other`). The JSON and text forms are built from one document. Argparse errors echo only the operator's own input.
* Read-only: first statement in `session.begin()` is `SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY`; test asserts `SHOW transaction_read_only`. All SQL is SQLAlchemy expressions (no string building); dates are parsed with a strict regex.
* Data-model fit: `CLOSED_BY` has exactly the four closers and every `close_incident` caller sets one; `contacts_messaged_at` is set in the dispatcher's tx A for every escalation-category message before the provider call (dispatcher.py:337-340), so a failed or `sending` message still lists the incident; link-bearing first messages are escalation category (`executor.py:70`); `NOTIFICATION_STATUSES` and `LOG_OUTCOMES` match the CHECKs, so the `+= n` indexing cannot KeyError. Worker role has SELECT on every table used (migrations 0001, 0002, 0003, 0004, 0006).
* Empty database: zero counts and "none in this period"; no exception.

| ID | Sev | File:line | Finding | Conf |
|---|---|---|---|---|
| BETA-1 | S2 | beta.py:685-705 (`_incident_rows` filters on `opened_at`); docs/BETA_PLAN.md:97, 99, 107; test_beta_report.py:428 ("incidents belong to the day they opened") | The list of incidents "in which a contact was messaged" is selected by the day the incident OPENED, not the day contacts were first messaged. Scenario: a tester sets a 24-72 h grace (free presets go to 3 days). Incident opens Monday 08:00, first contact is messaged Wednesday 08:00. The documented morning check `beta-report --since <yesterday>` (Wed run, `--since Tue`) lists nothing; the weekly `--since <monday>` run on the next Monday misses an incident opened the Friday before and messaged on Monday. "0 escalated, 0 need review" is then read as "no contact was reached", and the S1 acceptance rule (zero wrongful, every escalated incident reviewed) is checked with an instrument that undercounts. Fix: select on `contacts_messaged_at` (or the union of both) and say which in the header. | CONFIRMED |
| BETA-2 | S3 | beta.py:1032-1056 `_hints` (`opened_within_24h_of_hold_exit`) | The Hold rule fires only when `ended_at <= opened_at < ended_at + 24h`. An incident opened inside a Hold's (backdated) window, in the detection gap, is exactly what exit processing shifts (`opened_at <= window_end`, hold.py:418), but is not flagged. Nor is an incident opened before the Hold whose check-in was lost in the outage and which then messaged contacts after the shift: only context `stage_delayed` fires, so while it is open (or closed by operator void) it is not a review candidate. Fix: fire when any Hold overlaps `[missed_due_at, contacts_messaged_at]`. | CONFIRMED |
| BETA-3 | S3 | maintenance/retention.py:41-58; maintenance/accounts.py:119; models: escalation_incidents.user_id ON DELETE CASCADE | The evidence the report reads is purged without trace. Notifications (and their logs) are deleted 90 days after creation once their incident is closed: a report over an older period still lists the incident (`contacts_messaged_at` stays) but with no contacts and "0 messaged". Hard-deleting an account 30 days after closure cascades the user's incidents, actions and notifications away, so a wrongful alert followed by account deletion disappears from the next report entirely (only `accounts.deleted` counts). The report does not say either. BETA_PLAN's "review within 24 h" mitigates, but the weekly or end-of-beta report is not safe. | CONFIRMED |
| BETA-4 | S3 | beta.py:1228-1257 (`beta_report`), 1259-1285 (`format_text`) | The report does not say which database or environment it read (no `APP_ENV`, database name, alembic revision or schema head). Run against an empty or wrong database (staging instead of production, a restored copy) it prints a clean report indistinguishable from a quiet beta. | CONFIRMED |
| BETA-5 | S3 | beta.py:155, 1081 (`still_open_over_24h` is context only), 1274 (review header) | `REVIEW ... 0 NEED HUMAN REVIEW` counts only the five wrongful-candidate rules. An incident that reached contacts and is still open (the person has not confirmed they are fine; for a tester that is often "phone off for the weekend") raises only the context rule `still_open_over_24h`, so the header can read 0 while an alert to real people is unresolved. The block is listed, but the number operators copy into the beta log excludes it. | PLAUSIBLE |
| BETA-6 | S4 | cli/admin.py:213-216; beta.py `Period` | On a database that is not migrated (or behind) the first query raises and the operator gets a raw traceback (exit 1, fail-safe but opaque). Days are UTC, so for an operator in IST `--since <yesterday>` starts at 05:30 local; documented, but a trap for the daily command. | CONFIRMED |

## Area 4: `user set-tier | suspend | unsuspend` and `operator.*` audit

Checked and sound:

* Lock order: `select User.id` (no lock) then `EngineStore.lock_user` (config row, SKIP LOCKED, busy gives a clean "refused") then `users FOR UPDATE`. Same order as account deletion (config then user). No path I found takes users FOR UPDATE and then the config row (contact create locks users only), so no deadlock with API or engine. The engine never writes `users`. Dispatcher re-checks `user.status` under the per-user lock, so a suspension between tx A and send is seen, except for a message already `sending` (inherent).
* Revocation: `revoke_all` sets `revoked_at` on every `sessions` row (app and web share the table); refresh needs a non-revoked session and `status == 'active'` (service.py:521); bearer (deps.py:163), web session (account_session.py:85,141), login (service.py:380), web login, password reset and email-verify paths all refuse non-active. `revoke_reason 'operator'` is in the CHECK. Portal pages for the person's contacts also stop (`_resolve`, portal_service.py:201): documented in SECURITY §13.
* Contacts of a suspended person: queued escalation and reminders are cancelled `account_inactive`; undoing messages (all-clear, withdrawn) are still sent (F-17, deliberate); `incident void` sends a withdrawn alert to the contacts who were told.
* `set-tier` touches only `users.tier`, `updated_at`; tier is read per request (deps.py:185) and at create time; the engine never reads it (grep). A downgrade deletes nothing; over-limit counts are printed.
* Audit: action names registered in `KNOWN_ACTIONS`; free text allowed only for the three actions, 1..200 chars, category C* refused (control, format incl. bidi, surrogate, private use); not logged; `user_visible=False`; operator name sanitised (`_safe_operator`); no DB CHECK on `audit_logs.action`.

| ID | Sev | File:line | Finding | Conf |
|---|---|---|---|---|
| USR-1 | S3 | ops/users.py:236-262 (suspend note), 285-297 (unsuspend); engine/gate.py:82-84; ops/admin.py engine_status | Suspend with an open incident, then unsuspend, leaves a dead incident. G5 cancels every action that falls due while the user is not active and nothing re-creates them; `unsuspend` re-checks only `next_due_at` on an *active* schedule (an `incident_open` schedule has none), so it prints nothing; `uq_incidents_one_open` stops a new incident; `status` has no "open incident with nothing pending" page. Scenario: abuse report, operator suspends A (incident in grace), unsuspends two days later; A never signs in again; contacts are never told, silently. The `suspend` output does warn ("unsuspend does not bring them back"), the `unsuspend` output does not. Workaround: `incident void` (which resumes the schedule). Fix: refuse or warn on unsuspend with an open incident whose actions are all cancelled, and add that state to `status` pages. | CONFIRMED |
| USR-2 | S4 | audit/writer.py:310-319 | `validate_operator_text` rejects category C* only; U+2028/U+2029 (Zl/Zp) and exotic spaces pass although the docstring promises "no newline". No HTML or log sink exists today, so no injection, but the free text can carry names or addresses the operator types, and `audit_logs` has no purge rule at all (D-3), so it is kept forever. | CONFIRMED |
| USR-3 | S4 | ops/users.py:287-296 | The unsuspend note says the incident opens "unless the person checks in before that" (next tick, 15 s). Every session was revoked by `suspend` and `unsuspend` does not restore them, so the person cannot; with a passed deadline the person always receives "you missed your check-in" notices (not contact-facing, grace >= 60 min). Wording only. | CONFIRMED |
| USR-4 | S4 | users/deletion.py:147,187; account_service.py:146 | A suspended person cannot use self-service export or deletion (all paths require `active`) and the operator has no command for either; the privacy policy promises both. Needs a support route. | PLAUSIBLE |

## Area 5: backend/scripts/provision_roles.sql

Checked and sound: roles are created without privileged attributes and the script verifies `rolsuper/rolcreaterole/rolcreatedb/rolreplication/rolbypassrls` afterwards (loud, fail-safe); CONNECT and TEMP are revoked from PUBLIC and CONNECT given only to the five login roles; schema `public` ownership normalised on 14 and 15+; `REVOKE CREATE ... FROM PUBLIC`; default privileges revoke PUBLIC EXECUTE on functions created later by the owner; no table grants (migrations do them, only for roles that exist, so provisioning must run first, as documented); dev passwords (`_dev$`) and short passwords refused; idempotent (`WHERE NOT EXISTS`, ALTER ROLE re-applies); the dev-only `GRANT afterme_maintenance TO afterme_owner` is correctly absent; trigger guards keyed on `current_user = 'afterme_api'/'afterme_maintenance'` hold because the roles log in directly; adjacent string literals in the `GRANT CONNECT` format are valid. `afterme_owner` has no CREATEDB (prod) unlike dev.

| ID | Sev | File:line | Finding | Conf |
|---|---|---|---|---|
| PROV-1 | S3 | provision_roles.sql:11-15, 90-93; docs/DEPLOYMENT.md:247 | The passwords are passed with `psql -v ...=…` (visible in `ps` and shell history for the run) and then sent as `ALTER ROLE ... PASSWORD 'plaintext'` (and inside the `SELECT ... ~ '_dev$'` check). PostgreSQL logs DDL text under `log_statement = ddl|all`, which managed services commonly set; the header's "nothing is written to disk" is true of the script only. Fix: send SCRAM verifiers computed client-side, or `SET log_statement = 'none'` plus read the passwords from files via `\set x \`cat ...\`` / `\password`. | CONFIRMED (documented PostgreSQL behaviour) |
| PROV-2 | S4 | provision_roles.sql:20-22, 100-106, 134 | `afterme_readonly` is promised "for an operator's investigation" but no migration grants it anything (only tests/security/test_db_grants.py mentions it) and it has no CONNECT: it is a role that can read nothing. Also "re-applies the lock-downs" is overstated: only attributes are checked, not membership: a runtime role granted `afterme_owner`, `pg_read_all_data` or `pg_write_all_data` by hand survives a re-run. | CONFIRMED |

## Area 6: game day (scripts/gameday.py, gameday_support/)

Sound: database name pinned by regex to `afterme_gameday[a-z0-9_]{0,30}` and refused if protected, enforced twice; all four URLs carry it; children run with every `AFTERME_*` stripped and `APP_ENV=test`; no secrets written to disk; mail files 0600 in a 0700 dir; `Report.passed` requires non-empty and all OK, so FAIL, exception, timeout and defect rows exit non-zero; OPS-03.9 counts accepted sends per notification id from the mock (a missing id counts as 0) and is a real check; OPS-01.2/.3/.6/.9b/.10-.13 can fail.

| ID | Sev | File:line | Finding | Conf |
|---|---|---|---|---|
| G-1 | S3 | ops01.py:201-210, 248-258 | OPS-01.4 "B's stage ran ... and its message did not leave" is asserted at the first Hold step (about L+195 s) while B's alert has `send_after` about L+375 s: `mails == 0` is true even if the Hold gate were broken. Only "stage executed" is a real assertion; .11/.12 catch a leak later. | CONFIRMED |
| G-2 | S3 | ops01.py:519-530 | OPS-01.15 "no wrongful alert" reads `contact_alert` mails of A, A2, R, B2 at about L+59 min; A, A2 and R have grace 180 so their wrongful alert would be about L+186..220 min, beyond the run. Only B2 is exercised (and .5 covers it); other templates (all-clear, withdrawn, release) are not counted. docs/GAMEDAYS.md:111-112 has the same blind spot. | CONFIRMED |
| G-3 | S3 | ops02.py:382-406 | OPS-02.13 "every dedupe key once" can never fail on the key half (`notifications.dedupe_key` is UNIQUE); the mail-count half derives its template set from `sent` rows only (a mail for a template with no `sent` row is invisible) and has no minimum count. | CONFIRMED |
| G-4 | S3 | procs.py:60-70, 112-149 | `DROP DATABASE`/`dev_db_setup.sh` (including `ALTER ROLE ... PASSWORD '<dev default>'`, cluster-wide) use the inherited `PG*` environment (PGHOST, PGSERVICE, PGHOSTADDR) while the processes use `AFTERME_GAMEDAY_PG_HOST` or localhost. With PG* pointing at a shared or staging cluster the roles there get the dev passwords. Same pattern in mobile/tool/integration.sh (C-2). | PLAUSIBLE |
| G-5 | S4 | procs.py:136-143 | A run resets `afterme_owner/api/worker` passwords to the defaults (or the env), so a dev `.env` with custom passwords stops working until `make db`. | PLAUSIBLE |
| G-6 | S3 | procs.py:32, 244-269 | Pidfile reaping: `_looks_ours` is a substring match ("uvicorn", "workers.engine", "cli.admin") and `reap_stale` does `killpg(SIGKILL)`; after reboot or PID reuse it can kill the developer's own `make run` server and children; two concurrent runs share the pidfile and reap each other. No start-time, work-dir or port check. | PLAUSIBLE |
| G-7 | S4 | procs.py:226-233, 333-346; stack.py:103-152 | `port_is_free` can report a wildcard-bound port as free on macOS and `wait_for` checks readiness before process liveness, so a foreign AfterMe API on that port can answer before our uvicorn fails with EADDRINUSE. | PLAUSIBLE |
| G-9 | S4 | ops01.py:275, 332; ops03.py:431-432, 552; gameday.py:198-204 | Smaller vacuous conjuncts: .5 true for an empty alert list and before `send_after`; .8 reminder not tied to the Hold; OPS-03.5 asserts one page string absent rather than `pages == []`; a run with only "FAIL (defect)" rows deletes logs and database; no manifest of required check ids. | CONFIRMED |

## Area 7: Docker and CI

Sound: image runs as uid 10001 with root-owned code; no secrets or `.env` copied; `--no-proxy-headers` explicit in CMD (and grepped in CI), so FORWARDED_ALLOW_IPS cannot re-enable it; API, worker, maintenance and migrations are all runnable from the one image; triggers are `pull_request` only (never `pull_request_target` or `workflow_run`); `permissions: contents: read`; no `|| true` or `continue-on-error`; `shell: bash` has pipefail so `make engine-gate | tee` fails the job; the concurrency loop ends with `test "$failures" -eq 0`; caches are ref-scoped; `inputs.only` goes through env.

| ID | Sev | File:line | Finding | Conf |
|---|---|---|---|---|
| C-1 | S3 | .github/workflows/emulator.yml:74 | `TMPDIR: ${{ runner.temp }}` is under job-level `env:`, where the `runner` context is not available (allowed: github, needs, strategy, matrix, vars, secrets, inputs). GitHub rejects the file ("Unrecognized named-value 'runner'"); the weekly and manual run never start, so the only CI job that drives the real app against the real backend does not exist. YAML parses locally, so only a linter or GitHub finds it. Fix: put it in the step's `env:` or use `${RUNNER_TEMP:-/tmp}` in integration.sh. | CONFIRMED (documented context table) |
| C-2 | S3 | mobile/tool/integration.sh:125-133; backend/scripts/dev_db_setup.sh:46-80 | `psql -d postgres ... DROP DATABASE afterme_it WITH (FORCE)` and `ALTER ROLE ... PASSWORD <dev default>` run against whatever `PGHOST/PGUSER/PGSERVICE` points at, while the app URLs hardcode localhost. A developer with a staging superuser exported gets real roles reset to published passwords. No local-only guard. | PLAUSIBLE |
| C-3 | S4 | mobile/tool/it_host.py:36, 92-93, 111-115 | Hardening gaps (script path avoids them): an empty `IT_HOST_TOKEN` makes `compare_digest(b"", b"")` pass; the body is read before auth with no timeout (local DoS); `IT_OWNER_URL` is trusted (no database-name guard). Bind is 127.0.0.1, every request needs `X-Test-Token`, comparison is constant time, argv is fixed, tier is whitelisted, SQL parameterised: not reachable from the network or a browser. | CONFIRMED (low impact) |
| C-4 | S4 | mobile/tool/it_host.py:54-64 | `/hold/status` does `json.loads(stdout)` but app logging writes to stdout (core/logging.py:175); any future log line on that path turns MOB-68 into a 400. | CONFIRMED mismatch |
| C-5 | S4 | integration.sh:267-274 vs emulator.yml:151-159 | `scrub()` redacts the test token only for console output; per-suite logs are uploaded raw (14-day retention). Per-run token, low impact. | PLAUSIBLE |
| C-6 | S4 | nightly.yml:101-103 | The 100x concurrency step has no `if: !cancelled()`; when `make engine-gate` fails the step is skipped, losing the flakiness figure (job is red either way). | CONFIRMED |
| C-7 | S4 | backend/Dockerfile:30-56; .github/dependabot.yml | Base images are mutable tags; dependabot has no `docker` ecosystem. | CONFIRMED |
| C-8 | S4 | backend.yml:137-142 | `${{ steps.python.outputs.version }}` (from PR-controlled `.python-version`) is interpolated into the shell script; whitespace is stripped but `;`/`$()` survive. No privilege gain today. | CONFIRMED pattern |
| C-9 | S4 | backend/.dockerignore:7-14 | `*.pem`, `*.key`, `*.p12`, `google-services.json`, `.dev_mail` lack `**/` so they match only at the context root; the Dockerfile COPYs app/, workers/, cli/, migrations/ whole. No such file exists today. | PLAUSIBLE |
| C-10 | S4 | Dockerfile:36-41; backend.yml:117; emulator.yml:5,17 | Cites SECURITY_REVIEW F10 (the net.py fix) for `--no-proxy-headers`; "five suites (mob61..65)" is stale (eight); the docker job proves only `import app.main`, never `create_app()`/`load_settings()` in the image. | CONFIRMED |
| C-11 | S4 | all workflows | Third-party actions are pinned by floating tag (`subosito/flutter-action@v2`, `gitleaks/gitleaks-action@v2`, `reactivecircus/android-emulator-runner@v2.30.1`, `astral-sh/setup-uv@v10`), not SHA; the major versions used (`checkout@v7`, `setup-uv@v10`, `setup-java@v6`, `upload-artifact@v7`) could not be verified offline: a non-existent tag fails every workflow at once. | PLAUSIBLE |

## Area 8: it_host.py / integration.sh

See C-2 to C-5. Sound: bound to 127.0.0.1 only; browser abuse blocked by the custom header (preflight gets 501, no CORS); token from `openssl rand -hex 32`, passed by env and header, never printed; no shell, fixed `python -m cli.admin` argv; CLI uses the worker URL overridden to `afterme_it`; trap kills the helper tree; a taken port makes the helper exit before anything is sent a token.

## Area 9: mobile

Sound: pending-tap flush on cold start, signed-out, unknown auth, app lock; `LeaveGuards` is in-memory and unregisters on dispose; pending check-in is keyed per user id, never read for another account, parked before overwritten, cleared by id on closure; `SCREENSHOT_MODE` is refused with `APP_ENV=prod`, refused on the production package id (so a staging env on the prod id fails closed), `main.dart` shows a misconfigured-build page, `SecureScreens` is the only caller of `setSecure`, `prod.json` has no key, `build_release.sh` takes no pass-through flags and rejects any non-false mention (an escaped key fails closed because the app then refuses to start); the clipboard gateway copies only version, build, environment and API host and never reads the clipboard; Home no longer depends on a warm instruction list (aggregate drives readiness); closure keeps app lock and pre-prompt (device-bound), removes onboarding keys, session, push registration and the account's pending check-in; spinner and transition changes hide nothing.

| ID | Sev | File:line | Finding | Conf |
|---|---|---|---|---|
| M-1 | S3 | features/plan/presentation/plan_editor_screen.dart:134; notifications/application/push_coordinator.dart:601-604, 652-656; app/leave_guards.dart | A notification tap, including an incident one, can be consumed without opening the incident. While the plan editor is dirty and a save is in flight, `ask` returns false at once: no dialog, no navigation, tap dropped (Home is only refreshed in memory); the person has to find Home and I'M SAFE by hand. With the dialog open ("Leave without saving?", no hint that a notification caused it) "Keep editing" is the natural answer and a second tap is discarded on purpose (`_confirming`). If the editor lives in a retained shell branch, `isGuarding` can stay true after "Leave" and re-raise the dialog on later taps. Not a silent loss when the dialog is answered, hence S3. Fix: incident notifications should not be blockable, or the dialog should name the incident. | CONFIRMED (saving branch), PLAUSIBLE (rest) |
| M-2 | S3 | features/onboarding/application/setup_controller.dart:147 | `instructions: state.value?.instructions ?? const []` keeps the previous account's instruction summaries (titles) across an auth-driven rebuild; `setupControllerProvider` is not invalidated on sign-out or `LocalAccountData.wipe`. Shared phone: A saves an instruction in onboarding and logs out; B signs up in the same process and, if B's list read has no value, sees A's title as "saved". Regression from the Phase 10 start-up read change. | PLAUSIBLE |
| M-3 | S4 | pending_checkin_store.dart:176; local_account_data.dart:38 | `clear()` removes only the main slot, not the parked `checkin.pending.<id>`; used when the closed account's id cannot be read; parked records of accounts that never sign in again persist (id, tap time, key). Known-id closure path is correct. | CONFIRMED |
| M-4 | S4 | core/platform/clipboard_gateway.dart:23 | Catches only `PlatformException`; `MissingPluginException` escapes the "Copy diagnostic text" handler with no snackbar. | CONFIRMED |

## Area 10: documents vs code

| ID | Sev | Document:line | Finding | Conf |
|---|---|---|---|---|
| D-1 | S2 | legal/PRIVACY_POLICY_DRAFT.md:78 | "Sessions and one-time tokens: removed 30 days after they expire or are revoked." retention.py purges only notifications, email_receipts, ingestion_probes, checkin_events, contact_verifications, portal_tokens, portal_sessions, portal_otp_challenges. `sessions` (ip_hash, user_agent), `refresh_tokens` and `auth_tokens` (including a `payload` with the new address) are never deleted until the account is hard-deleted; backend/README "Known limitations" says so. | CONFIRMED |
| D-2 | S2 | PRIVACY_POLICY_DRAFT.md:81 | "the remaining records are erased 30 days later": `audit_logs` has no FK (survives deletion, with subject id and ip_hash; `account.purged` row added) and `email_suppressions` rows survive; the policy never says pseudonymous audit records outlive deletion. | CONFIRMED |
| D-3 | S3 | PRIVACY_POLICY_DRAFT.md:77, section 11 point 4 | Audit records "[1 year: counsel to confirm]": there is no audit purge rule or job; retention is unbounded; open point 4 does not say so. | CONFIRMED |
| D-4 | S3 | PRIVACY_POLICY_DRAFT.md:76 | "400 days, then only totals": `checkin_events` is deleted outright; no aggregate exists. | CONFIRMED |
| D-5 | S3 | PRIVACY_POLICY_DRAFT.md:85 | Export "gives you a file with your information": export (users/export.py) omits devices, sessions, audit/security and delivery records and truncates at 10 000 rows. | CONFIRMED |
| D-6 | S3 | PRIVACY_POLICY_DRAFT.md:33 | "opt out ... so that no AfterMe user can email them again": only the "Never contact me about AfterMe again" scope writes a suppression; "Stop emails from X's AfterMe" does not; hard bounces also store a hash (unreachable.py:116) which is not disclosed. | CONFIRMED |
| D-7 | S3 | legal/TERMS_DRAFT.md:42 | "Once someone opts out, AfterMe will not message them for any user": true only for the global scope. | CONFIRMED |
| D-8 | S3 | PRIVACY_POLICY_DRAFT.md:37 | An alert "never contains the text ...; a separate message gives a link": `contact_alert_with_release` is one email containing alert text and the link (executor.py:70). | CONFIRMED |
| D-9 | S3 | PRIVACY_POLICY_DRAFT.md:59 | FCM gets "a generic message (You have a check-in due)": real `PUSH_COPY` (render.py:28-55) reveals escalation state ("Your contacts have been notified", "Information will be shared in 1 hour"), payload carries `type` and `incident_id`; Firebase installation ID not listed (PLAUSIBLE). | CONFIRMED |
| D-10 | S3 | PRIVACY_POLICY_DRAFT.md:57, 67 | "wrapped by a key-management service": only `LocalKms` exists; `gcp_kms` raises "not available in this build"; production-like environments refuse `local` (config.py:484), so nothing production-like starts yet; not in counsel's open points. | CONFIRMED |
| D-11 | S3 | PRIVACY_POLICY_DRAFT.md:31-33 | Not disclosed for contacts: `contact_verifications.ip_hash` and consent text version, `portal_sessions.ip_hash`, per-release first/last viewed and view count. | CONFIRMED |
| D-12 | S4 | PRIVACY_POLICY_DRAFT.md:20-21 | Phone numbers are stored but no SMS/WhatsApp sender exists; device rows (platform, app/OS version, locale, last_seen) have no retention row. | CONFIRMED |
| D-13 | S4 | PRIVACY_POLICY_DRAFT.md | Server request logs (route, status, latency) and hashed rate-limit keys not mentioned. | PLAUSIBLE |
| D-14 | S3 | BETA_PLAN.md:62; TESTER_GUIDE.md:71; PLAY_STORE.md:38 | Policy and terms "live at /legal/privacy and /legal/terms": no route serves them (no "legal" in app/); sign-up consent and About link to 404s; no step builds them (checked). | CONFIRMED |
| D-15 | S4 | BETA_PLAN.md:47 | "first four rows ... last three": table has six rows and row 4 straddles; row 2 is emulator.yml which has never run (and C-1). | CONFIRMED |
| D-16 | S4 | BETA_PLAN.md:167 | Notice text "deadlines were moved by the same amount": pending stages are shifted by window + 30 min; passed deadlines open a later incident with full grace. | CONFIRMED |
| D-17 | S3 | GAMEDAYS.md:123 (and G-8) | Still reports "Hold ended 7.2 minutes after the first fresh probe ... expect 7 to 8 minutes" as an open finding; this phase's hold.py fix makes it 10+ minutes; an operator following the doc would accept a premature exit as a pass and stale line numbers. | CONFIRMED |
| D-18 | S3 | GAMEDAYS.md (about 20x), DEPLOYMENT.md section 12 steps 5/7/10, BETA_PLAN.md:52,142 | `afterme-admin ...` does not exist as an executable (no `[project.scripts]`); real forms are `python -m cli.admin` / `make admin ARGS=`. Sub-commands and flags otherwise match cli/admin.py. | CONFIRMED |
| D-19 | S4 | GAMEDAYS.md:297 | "beta log (BETA_PLAN.md, if present)": the log is "a spreadsheet is fine". | CONFIRMED |
| D-20 | S3 | DEPLOYMENT.md:256; TEST_PLAN.md:341 | "missed-check-in rehearsal takes about 1 h 10 min": only if the deadline is placed by a database UPDATE (schedule enforces MIN_WINDOW 12 h; 60-minute grace needs Premium; free presets start at 3 h). | CONFIRMED |
| D-21 | S4 | DEPLOYMENT.md section 12 step 1 | "PostgreSQL 14 ... keeps public owned by the bootstrap user": provision_roles.sql re-owns it or raises. | CONFIRMED |
| D-22 | S4 | DEPLOYMENT.md step 2/3 | "webhook secrets of at least 32 characters": only Postmark's; Resend's is a `whsec_` secret; script minimum is 24 characters. | CONFIRMED |
| D-23 | S4 | DEPLOYMENT.md section 1 | staging row says "beta backend"; BETA_PLAN/PLAY_STORE say the Play beta runs on production. | CONFIRMED |
| D-24 | S4 | TEST_PLAN.md:341 | "SECURITY_REVIEW F-19": no such row (F-01..F-17). | CONFIRMED |
| D-25 | S3 | ROADMAP.md Phase 10 status | "built and verified" while the Dockerfile header says it could not be built on its author's machine, emulator.yml is marked not executed, the backend `docker` job and nightly have never run; "42 checks pass" not verifiable by reading. | CONFIRMED / PLAUSIBLE |
| D-26 | S4 | backend/README.md Known limitations | "other retention rows have grants but no job": retention.py exists; real residue is audit_logs, sessions, refresh_tokens, auth_tokens, devices. | CONFIRMED |
| D-27 | S3 | TESTER_GUIDE.md:50 | Scenario 8 "second contact": free tier is one contact; Premium not grantable to testers (BETA_PLAN decision 6 open); limits not mentioned. | CONFIRMED |
| D-28 | S3 | TESTER_GUIDE.md:47-50 | #6 "right after #5 press I'M SAFE", #8 "release as part of #5": release stages are >= 1440 min and I'M SAFE revokes releases; following the order never shows a release; no timing for the contact alert. | CONFIRMED |
| D-29 | S4 | TESTER_GUIDE.md:63 | Diagnostic text lacks "phone model" (version, build, environment, API host). | CONFIRMED |
| D-30 | S4 | TESTER_GUIDE.md:49,52,63 | Menu names: "Help and about" not "Help"; "About AfterMe"; App lock is under Settings, Security. | CONFIRMED |
| D-31 | S4 | TESTER_GUIDE.md:16 | "one longer session in the first week": scenarios 7-11 are Week 2. | CONFIRMED |
| D-32 | S3 | MANUAL_TEST_SHEET.md:74 (D07) | "5 wrong in 15 min: calm lock message and email": I'M SAFE password uses `REAUTH_PER_SESSION` (plain rate limit); lock plus email is for 10 failed sign-ins. | CONFIRMED |
| D-33 | S3 | MANUAL_TEST_SHEET.md:91 (F01) | Contact screens expected blank in recents ("S1 if captured"): no `SecureScreen` under features/contacts; protected only with app lock on. | CONFIRMED |
| D-34 | S3 | MANUAL_TEST_SHEET.md:71 (D04) | "Two stages, different contacts" needs Premium (free: 1 contact); no tier step. | CONFIRMED |
| D-35 | S4 | MANUAL_TEST_SHEET.md:8, F06, F08 | "debuggable staging build": a sideloaded staging release build is not debuggable (run-as, full logcat). | PLAUSIBLE |

Unverifiable by reading: "40 of 42 grant tests passed" (DEPLOYMENT section 12), the measured game-day timings (205/206 s, 185 s).

## Checked and found sound (summary)

* hold.py `_auto_exit` new rule in all listed edge cases; Hold ends after 10 continuous minutes; no path to a Hold that never ends with default settings.
* GRACE_MIN floor applied in every environment; no test or doc conflicts.
* beta-report privacy and read-only enforcement; no rule or metric uses a value outside `CLOSED_BY`, `NOTIFICATION_STATUSES`, `LOG_OUTCOMES`; `contacts_messaged_at` covers every escalation-category message including failed ones.
* `user suspend/unsuspend/set-tier`: lock order, completeness of session/refresh/web revocation, refusal paths (unknown, busy, pending_deletion), audit hygiene (free text only on three actions, never logged, never user-visible).
* provision_roles.sql: no DDL/superuser path for a runtime role, PUBLIC access closed, idempotent, dev passwords refused.
* game day: database name pinning, env stripping, exit-code aggregation, OPS-03.9.
* Docker image: non-root, no secrets, proxy headers off explicitly; workflows have no pull_request_target and least permissions.
* it_host.py: loopback-only, token-gated, fixed commands.
* Mobile: SCREENSHOT_MODE cannot reach a prod build (Dart and shell guards), pending check-in never sent as another account, push cold-start handling.
