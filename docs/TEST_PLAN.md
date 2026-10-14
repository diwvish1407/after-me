# AfterMe — Test Plan

| | |
|---|---|
| **Status** | Draft v0.1 — awaiting product-owner approval |
| **Related** | [ESCALATION_ENGINE](ESCALATION_ENGINE.md) · [SECURITY](SECURITY.md) · [API_SPEC](API_SPEC.md) |

---

## 1. Strategy

1. **The escalation engine gets the most testing**, with deterministic time, real PostgreSQL, property-based and concurrency tests. A wrongful alert or release is a **severity-1** defect.
2. **Real database in tests.** Integration and engine tests run against PostgreSQL. Mocking the DB would hide locking and constraint behaviour, which the engine depends on.
3. **Deterministic time.** Tests drive a `FrozenClock` ([ARCHITECTURE §4.5](ARCHITECTURE.md#45-time)). There are no `sleep`s.
4. **Security tests are generated from the route table**, so a new endpoint can't skip authorization tests.
5. **Fast feedback.** Unit tests run in seconds; the full backend suite runs in minutes. CI gates every merge.

| Level | Backend | Mobile |
|---|---|---|
| Unit | Pure functions, services with fakes | Controllers, interceptors, mappers, validators |
| Integration | API + real Postgres (httpx ASGI client) | Widget tests with fake repositories |
| Engine | Engine + Postgres + FrozenClock + fake providers | — |
| Property-based | Hypothesis (deadline math, stateful engine model) | — |
| Concurrency | Multiple workers/connections, injected interleavings | — |
| End-to-end | Staging: real app ↔ backend with the test clock router | `integration_test` on emulator/device |
| Manual | Portal, emails | Devices, OEMs, accessibility, notifications, biometrics |

## 2. Tooling

| Purpose | Tool |
|---|---|
| Backend tests | pytest, pytest-asyncio, Hypothesis, httpx (ASGI transport), coverage |
| DB for tests | Local PostgreSQL (dev); PostgreSQL service container in CI. The app under test connects as `afterme_api`. Every test starts from empty tables (TRUNCATE as `afterme_owner`): per-test rollback is not possible because some bookkeeping (rate-limit counters, failed-login counters, code attempts, failure audit records) commits on independent connections. Concurrency tests use isolated databases. |
| Fakes | `FrozenClock`, `RecordingEmailProvider`, `RecordingPushProvider`, `LocalKeyProvider` |
| Mobile | `flutter_test`, `mocktail`, `integration_test`, Flutter accessibility guideline matchers |
| Static analysis | ruff, mypy, `flutter analyze` |
| Security | pip-audit/OSV, gitleaks, custom authz-matrix and log-leak tests |

## 3. Backend functional tests (by module)

| ID range | Module | Key cases |
|---|---|---|
| AUTH-01…25 | Auth | Signup start/verify/resend; identical responses for existing email; code attempts and expiry; login success/failure/lockout; timing equalisation; refresh rotation, 30 s retry grace, reuse → session revoked; logout / logout-all; reauth window (4:59 ok, 5:01 rejected); password change revokes others; forgot/reset (web) single-use and expiry; email change flow |
| PROF-01…08 | Profile | Validation (IANA tz, E.164, display-name rules); timezone change recomputes `next_due_at`; blocked during incident |
| CON-01…20 | Contacts | CRUD; duplicate email; own email rejected; tier limit; invitation queued only if not suppressed; accept/decline via portal (POST only); opt-out (this user / everyone → suppression); bounce webhook → `bounced`; resend limits; email change resets verification; delete scrubs PII and removes links |
| CHK-01…20 | Check-in | Schedule CRUD with `If-Match` (428/412); activation requirements; deactivate needs reauth; check-in idempotency replay; check-in resolves a grace incident; `409 safe_required` when messaged; history pagination |
| PLAN-01…15 | Plan | Stage 1 offset = grace; ordering and gaps; max offset; tier presets/limits; foreign contact → 404; delete stage in use → 409; incident open → 409 |
| INS-01…18 | Instructions | CRUD; encryption round-trip; ciphertext ≠ plaintext in DB; AAD binding (swapped ciphertext fails); release stage ≥ 24 h; recipients must be own contacts/stages; list excludes body; delete wipes ciphertext; tier limits |
| REL-01…15 | Portal | Fragment token exchange; expired/revoked tokens; OTP send limits, attempts, expiry; elevated session 15 min; view only visible, unrevoked releases for that (incident, contact); `visible_after` respected; Hold-window releases hidden; fresh-link request is generic; views audited |
| NOT-01…15 | Notifications | Outbox dedupe; retry/backoff schedule; fallback provider switch; addresses resolved at send; opted-out/suppressed → cancelled; push payload has no content; templates render with all params; no rendered email or push contains instruction content (asserted) |
| AUD-01…08 | Audit | Each sensitive operation writes exactly the expected action; metadata contains no forbidden keys; `user_visible` feed filtering |
| DEL-01…08 | Deletion/export | Export contains decrypted instructions and requires reauth; delete flow effects ([DATABASE §4](DATABASE.md#4-deletion-behaviour)); purge job after 30 days; audit survives |

**Phase 4 status of CHK-\* (built; `backend/tests/integration/test_checkin_schedule.py`, `test_checkins.py`, `test_home.py`, `test_profile_timezone_schedule.py`, `tests/unit/test_schedule.py`).** Covered: schedule read/update with `If-Match` (428, 412, no-op PUT), validation, activation requirements (`no_contacts` stand-in), idempotent activate/deactivate, deactivate needs re-auth, an open incident blocks every change, timezone change recomputes the deadline, check-in on active and inactive schedules, idempotency replay (sequential and concurrent), the lock-wait race, 503 on lock timeout, rate limit with replays exempt, history pagination (ties, bounds, bad cursors), `client_reported_at` leniency, Home readiness and activity, owner scoping. Also: step-up for lengthening an active schedule (needed, expires after 5 minutes, not needed for shortening, time/reminder only, or an inactive schedule), baseline and last check-in never move backwards under concurrent restarts, a replay returns the stored JSON verbatim, `incident_open` makes a check-in a retryable 503, and a database error at COMMIT leaves nothing behind (ENG-FS-01). **Not yet coverable (no incident model until Phase 5):** "check-in resolves a grace incident" and "`409 safe_required` when messaged". ENG-FS-14 (DST vectors) and ENG-PBT-01 are in `tests/unit/test_schedule.py` (Hypothesis over every accepted IANA zone, plus a deterministic sweep that provably reaches gaps and overlaps).

## 4. Escalation engine tests

### 4.1 Lifecycle tests

**ENG-LC-01: the critical T0–T8 scenario** ([ESCALATION_ENGINE §14](ESCALATION_ENGINE.md#14-worked-example-the-t0t8-lifecycle)). One automated test drives the whole lifecycle through the **public API + engine ticks** with a `FrozenClock`:

```python
async def test_eng_lc_01_full_lifecycle(world):            # world = api client + engine + clock + fakes
    u = await world.user(tz="Asia/Kolkata", schedule=("20:00", 1))
    mom, bro = await world.accepted_contacts(u, "Mom", "Brother")
    s1, s2 = await world.plan(u, grace=180, stages=[(180, [mom]), (1440, [bro])])
    house = await world.instruction(u, "House emergency", recipients=[(bro, s2)])
    await world.activate(u)

    await world.at("2026-10-13T19:30+05:30").checkin(u)                         # T0
    assert await world.next_due(u) == ist("2026-10-14T20:00")

    await world.run_until(ist("2026-10-14T20:00:15"))                           # T1
    inc = await world.current_incident(u)
    assert inc.status == "grace" and world.push.sent(u, "incident_missed")
    assert world.email.contact_messages() == []

    await world.run_until(ist("2026-10-14T22:45:15"))                           # T2
    assert world.push.sent(u, "incident_midpoint") and world.push.sent(u, "incident_last_chance")

    await world.run_until(ist("2026-10-14T23:00:15"))                           # T3
    assert (await world.current_incident(u)).status == "escalating"
    assert world.email.sent_to(mom) == []                                       # settle delay

    await world.run_until(ist("2026-10-14T23:05:30"))                           # T4
    assert world.email.sent_to(mom, "contact_alert")

    await world.run_until(ist("2026-10-15T19:00:15"))
    assert world.push.sent(u, "release_final_warning")

    await world.run_until(ist("2026-10-15T20:05:30"))                           # T5
    page = await world.portal(bro).open_latest_link().verify_otp()
    assert "House emergency" in page.text

    r = await world.at(ist("2026-10-15T21:00")).checkin(u, expect=409)          # T6
    assert r.code == "safe_required"

    await world.reauth(u); await world.safe(u, inc.id)                          # T7
    await world.run_dispatch()
    assert world.email.sent_to(mom, "contact_all_clear") and world.email.sent_to(bro, "contact_all_clear")
    assert (await world.portal(bro).reload()).shows("no longer available")

    before = world.email.contact_messages(incident=inc.id)                      # T8
    await world.run_until(ist("2026-10-22T21:00"), step="15m")
    assert world.email.contact_messages(incident=inc.id) == before              # nothing new for this incident
    assert (await world.incidents(u))[-1].missed_due_at == ist("2026-10-16T20:00")  # schedule resumed
    world.audit.assert_sequence(u, [...])                                       # full expected trail
    world.logs.assert_no_secrets()                                              # leak test (SEC-25)
```

| ID | Scenario |
|---|---|
| ENG-LC-01 | Full T0–T8 (above) |
| ENG-LC-02 | Check-in during grace → `resolved`; **zero** contact notifications created |
| ENG-LC-03 | Check-in inside the settle delay after stage 1 → I'M OK accepted; queued messages cancelled; releases revoked; no contact email sent |
| ENG-LC-04 | User never returns → all stages execute; incident `escalated`; releases stay viewable; no new incidents |
| ENG-LC-05 | Account deletion mid-incident → `voided`; all-clear to contacts already messaged; releases revoked |
| ENG-LC-06 | Plan with an empty stage (contact deleted) → stage executes as a no-op, recorded |
| ENG-LC-07 | Multi-day interval (every 3 days) and late-night deadline (00:30) |
| ENG-LC-08 | Instruction deactivated between final warning and release → not released; user summary reflects it |

### 4.2 Invariant tests

One or more dedicated tests per invariant ([ESCALATION_ENGINE §2](ESCALATION_ENGINE.md#2-safety-invariants)):

| ID | Asserts |
|---|---|
| ENG-INV-1 | No API route creates incidents/actions/releases (route scan + DB grant test: `afterme_api` `INSERT` on `release_events` → permission denied) |
| ENG-INV-2 | After a committed check-in, no contact-facing message enters `sending` for that incident (checked under all interleavings in ENG-CONC/ENG-PBT) |
| ENG-INV-3 | Client-supplied times have no effect (send absurd `client_reported_at`; outcomes unchanged) |
| ENG-INV-4 | Every gate check, forced to fail individually, prevents execution (fault-injection parametrised over G1…G9) |
| ENG-INV-5 | Running ticks twice on identical state produces no new rows (snapshot diff) |
| ENG-INV-6 | Pending/declined/opted-out/bounced/suppressed contacts never receive escalation messages or releases |
| ENG-INV-7 | Adding a contact/instruction mid-incident never adds actions; removing does narrow |
| ENG-INV-8 | Late-opened incident gets the full grace from `opened_at`; release never before anchor + 24 h |
| ENG-INV-9 | A release stage with an unexecuted final warning stays pending; > 30 min → held + alert |
| ENG-INV-10 | During Hold, no incidents open and no contact-facing messages are sent; all-clears still sent |

### 4.3 Failure-scenario tests

Each of FS-01…FS-28 in [ESCALATION_ENGINE §11](ESCALATION_ENGINE.md#11-failure-scenario-catalogue) has a test `ENG-FS-NN`. Highlights:

| ID | Technique |
|---|---|
| ENG-FS-01 | Inject a DB error at commit in the check-in service → 5xx, no partial rows, client-retry path verified |
| ENG-FS-05/06 | Raise inside the action executor after N statements → rollback; next tick succeeds; exactly one effect |
| ENG-FS-07 | Fake provider accepts, then the dispatcher "crashes" before tx B → resend uses the same idempotency key |
| ENG-FS-08 | Freeze the worker for 6 h of clock time while the API runs → late incidents get the full grace |
| ENG-FS-09/10 | Stop probes (no rows) for 20 min across a stage time → Hold backdated; stage rolled back if undelivered; shift applied; reminder to user |
| ENG-FS-13 | Open 30 incidents within an hour → anomaly Hold; requires manual exit |
| ENG-FS-14 | DST vectors ([ESCALATION_ENGINE §3.3](ESCALATION_ENGINE.md#33-verified-test-vectors)) for New York, London, plus Sydney, Santiago, Tehran (historical), Kathmandu (+05:45) |
| ENG-FS-22 | 4 concurrent workers over 500 due users → each incident/action/notification exactly once |
| ENG-FS-25 | Insert a check-in event bypassing the service → incident not opened; critical alert emitted |

### 4.4 Property-based tests (Hypothesis)

| ID | Property |
|---|---|
| ENG-PBT-01 | `compute_next_due` over all IANA zones × random baselines (1970–2100) × intervals × times: bounds, wall-time match (except gaps), determinism |
| ENG-PBT-02 | Timeline materialisation: reminders inside grace; stages at anchor + offset; final warnings 60 min before release stages; dedupe keys unique |
| ENG-PBT-03 | **Stateful model test** (`RuleBasedStateMachine`). Rules: advance clock (random steps), tick, check-in, I'M SAFE (with/without reauth), delete contact, deactivate instruction, contact opt-out, probe gap (outage), provider failure. After **every** step, invariants INV-2/5/6/7/8/9/10 are checked against the DB. |

### 4.5 Concurrency tests

| ID | Scenario |
|---|---|
| ENG-CONC-01 | Check-in vs stage execution with an injected pause *inside* the worker transaction (test hook after locks are acquired) → the check-in waits, then sees the correct state |
| ENG-CONC-02 | Check-in vs dispatcher tx A (both orders) → either the message is cancelled, or `safe_required` + all-clear |
| ENG-CONC-03 | Concurrent duplicate check-ins (same key, different keys) |
| ENG-CONC-04 | API lock timeout → `503` + successful client retry with the same key |
| ENG-CONC-05 | Multiple workers + dispatchers under load; zero duplicates by dedupe key |


**Phase 5 status (built; `backend/tests/engine/`, `backend/tests/unit/test_engine_pure.py`, `backend/tests/unit/test_plan_rules.py`, `backend/tests/integration/test_plan.py`).** Run the exit gate with `make engine-gate` (the T0-T8 lifecycle **100 times in a row**, then every engine suite).

| Plan ID | Where | Notes |
|---|---|---|
| ENG-LC-01 | `test_lifecycle.py::test_the_full_lifecycle_t0_to_t8` | Through the real API, engine and dispatcher on the frozen clock; without releases (Phase 6) |
| ENG-LC-02/03/04/05/06/07 | `test_lifecycle.py`, `test_incidents.py` | LC-05 exercises the engine side (`void_open_incident`); the deletion endpoint arrives later |
| ENG-LC-08 | Phase 6 | needs instructions |
| ENG-INV-1 | `test_invariants.py`, `tests/security/test_db_grants.py`, authorization matrix | route scan, import isolation, DB grants |
| ENG-INV-2 | `test_concurrency.py`, `test_stateful.py` | both interleavings, plus a check after every simulated step |
| ENG-INV-3/4/5/6/7/8/9/10 | `test_invariants.py`, `test_engine_pure.py`, `test_incidents.py`, `test_dispatch.py`, `test_hold.py` | INV-4 per gate (unit and engine level) |
| ENG-FS-05/06/07/08/11/12/13/21/22/23/25/26/28 | `test_failures.py`, `test_concurrency.py`, `test_hold.py`, `test_incidents.py` | FS-09/10 in `test_hold.py` (backdating, gap scan) |
| ENG-FS-14 | `tests/unit/test_schedule.py` | Hypothesis plus a sweep over transition-heavy zones |
| ENG-PBT-02 | `test_engine_pure.py` | Hypothesis |
| ENG-PBT-03 | `test_stateful.py` | **Deviation:** 20 seeded simulations of 60 random steps (ticks, jumps, check-ins, I'M SAFE, contact deletion/opt-out, operator Hold, provider failure, operator void) with invariants checked after every step, instead of `RuleBasedStateMachine` (the system is async and database-backed); a failure is reproduced by its seed |
| ENG-CONC-01/02/03/05 | `test_concurrency.py` | pauses injected inside the worker/dispatcher transaction; 4 workers over 24 users |
| ENG-CONC-04 | `tests/integration/test_checkins.py` | API lock timeout → 503 and a successful retry with the same key (a Phase 4 test; this table used to point at `test_concurrency.py`) |
| Review findings F-01..F-17 | `test_review_findings.py` | one or more tests per finding that was fixed (ESCALATION_ENGINE §13.2): void restarts the schedule; an unevaluable Hold sends nothing; forged and out-of-stage rows are cancelled and the API role is refused at the database; the batch is not starved during a Hold; the summary is not sent when nobody was told or during a Hold; ambiguous attempts get an all-clear; rollback reaches back a settle delay; give-up counted from the first attempt and paged; infrastructure errors never hold an action and an operator can retry; every due user is reached whatever the batch size; G8 narrows a stage; two workers enter one Hold |
| Owner decisions on F-03, F-12, F-05a | `test_owner_decisions.py`, `test_stateful.py` | a stage more than 5 min late is put back with the spacing kept and the person warned again (tolerance, later stages, second stage, Hold, check-in after, releasing stage keeps the 60-minute lead); step-up for plan edits, removing/deactivating/re-addressing a contact who is in a stage (and none when the schedule is off, the plan is unchanged, or the contact is in no stage); the anomaly threshold arithmetic and the same-hour baseline; the simulation gained an `outage` step and a lateness invariant, and was mutation-checked |

**Phase 5, mobile half (built; `mobile/test/features/plan/`, `mobile/test/contracts/phase5_contract_test.dart`, `mobile/test/helpers/fake_plan_server.dart`).** 1784 Flutter tests pass (1505 before this half, 1668 before the step-up and the Home banner), coverage gate green. The plan repository and controller run against `FakePlanServer`, which mirrors the backend (ETag/If-Match 412/428, stage 1 = grace, ordering and gaps, tier presets, stage limit 403, 404 for foreign ids, 409 `incident_open`, an unchanged body bumps nothing); `phase5_contract_test` parses every file in `docs/contracts/phase5/index.json` and checks the recorded headers; 9 accessibility-matrix entries were added (plan step: custom delays account, changed elsewhere, delay refused; done step: contact and plan missing, stage missing, stage that tells no one; Plan tab: no stages, two stages, cannot load). Step-up and Home banner: `FakePlanServer` and `InMemoryContactsRepository` answer 403 `reauth_required` like the backend (plan change while active; remove, re-address or switch off a contact who is in a stage while the schedule is not inactive; asked after 404/412/409/422); tests cover prompt-and-retry-once with the same body and `If-Match`, cancel, wrong password, recent password, unchanged plan, not-in-stage, schedule off (onboarding), and the 403 wire mapping. Home: `pickSafetyNetGap`, the banner per gap kind, its absence (inactive, incident, unknown, per-contact issues), combination with offline/pending/expired/readiness, and the fix flow. 9 accessibility-matrix entries were added (6 Home gap states, 3 password-sheet reasons). Nothing in the mobile suite runs against a live backend. The incident, history and I'M SAFE endpoints have no app models until Phase 7: only their shape, headers and failure mapping are tested.

**Phase 6 status (built; backend `tests/integration/test_instructions.py`, `tests/engine/test_release.py`, `tests/unit/test_crypto.py`, `tests/contracts/test_phase6_contracts.py`).**

| Plan ID | Where | Notes |
|---|---|---|
| INS-01…18 | `test_instructions.py` | CRUD; categories in order; the database holds only ciphertext (format byte, no title or body, a distinct ciphertext per seal); a ciphertext moved to another row, another user, or tampered with does not open; validation (empty, too long, control characters, text-direction overrides, NFC, line endings, 20,000 four-byte characters); unknown fields; release stage under a day; foreign contact or stage is 404 and creates nothing; one recipient once; unverified contact allowed; free plan limit 3 and a delete frees a place; usage in entitlements and Home; PATCH (content, status, recipients), empty/null PATCH; DELETE wipes the ciphertext and frees the stage; `stage_in_use`; isolation (404 everywhere); the worker role can read neither content nor keys |
| ENG-LC-08 | `test_release.py` | the full lifecycle with a real release: assigned, missed, released, link, code, read, I'M SAFE, taken back, all-clear |
| REL-01…15 | `test_release.py` | landing is static and a GET changes nothing; only a hash of the token is stored; unknown/malformed tokens give one page; expired link offers a fresh one (and an unknown token gets the same answer and no email); no content without the code; the code goes to the verified address and holds no content; five wrong codes lock it, a fourth code in an hour is refused, a new code replaces the old, an expired code is refused; elevation lasts 15 minutes and the session an hour; `visible_after` and Hold windows respected; each contact sees only their own; revocation by instruction switched off, recipient removed, contact deleted, opt-out, I'M SAFE; a Hold rollback takes it back and the re-run restores it; CSRF pair on every POST; cookie attributes |
| SEC-12/13/14/15/16/18/19/20/25 | `test_release.py`, `test_instructions.py`, `test_authorization_matrix.py` | scoped sessions; CSRF; GET changes nothing; headers; XSS payloads escaped in the portal; the API role cannot create releases, access or tokens nor un-revoke; ciphertext swap; no notification, mail, push, audit record or log line carries the text, a link or a code |
| SEC-24 | `tests/unit/test_config.py` | production refuses `KMS_PROVIDER=local` and a malformed KEK |
| Crypto | `test_crypto.py` | round trip and format; fresh nonce; AAD binding to owner, row and key version; tamper and truncation; KMS wrap bound to the user; rotation with a previous key |

**Phase 6, mobile half (built; `mobile/test/features/instructions/`, `mobile/test/contracts/phase6_contract_test.dart`, `mobile/test/core/security/secure_screen_test.dart`, `mobile/test/helpers/fake_instructions_server.dart`).** `FakeInstructionsServer` mirrors the backend (title/body rules, unknown category, free limit 3, 404 for a foreign contact or stage, duplicate recipient, release stage under 24 h, step-up 403) and also answers over the fake network for the real Dio repository; `phase6_contract_test` parses every file in `docs/contracts/phase6/index.json`, problems included, and checks the 403/404/409/422 mapping. FLAG_SECURE: reference counting, a replaced page never clears it, a tab switch, Home and sign-out clear it, the onboarding editor, and the MethodChannel call. Step-up: prompt-and-retry-once, cancel, wrong password, never-asked cases (text edit, switching on, nobody receives, onboarding). The draft never reaches storage or a log (asserted). New times: one `PUT /plan` then the instruction, one stage shared by two people, two stages in one save (premium), the free plan's limit, a plan failure sends nothing, an instruction failure keeps the draft and the retry reuses the stage, a `412` is retried once silently, one password sheet, onboarding asks nothing, existing stages unchanged. Accessibility-matrix entries for every new screen state. Not covered: FLAG_SECURE on a device (manual, §5.3). 2222 Flutter tests pass (1784 before this half).

**Phase 7 status (backend half; `backend/tests/engine/test_activity.py`, `test_export.py`, `test_deletion.py`, `test_web_checkin.py`, `backend/tests/integration/test_test_support.py`, `backend/tests/contracts/test_phase7_contracts.py`).**

| Plan ID | Where | Notes |
|---|---|---|
| AUD-01…08 (feed) | `test_activity.py` | the owner sees who viewed what (names and titles composed at read time; the audit rows hold neither); newest first, paged by cursor, only the owner's; a view lists what was visible *then* (a later deletion does not rewrite it); bad cursor `422`; unauthenticated `401` |
| DEL-01…03 (export) | `test_export.py` | refused without a fresh password and not audited; decrypted instructions, incidents with releases, activity, check-ins; no credentials, ciphertext, key material or other accounts; 3 per hour; an instruction that cannot be opened is listed as an error, never dropped |
| DEL-04…08 (deletion) | `test_deletion.py` | needs the password **and** the word DELETE; sessions, login and refresh die at once; content wiped, key deleted, contacts scrubbed, address and password overwritten, confirmation sent to the old address; another account untouched; deleting during an alarm voids the incident, sends the all-clear to the contact who was told and nothing to anyone else, and the maintenance job then scrubs that contact; released content is unreadable; purge after 30 days and not before, cascading, active accounts never; the public page (link then password; same answer for every address; CSRF; bad tokens; one use) |
| CHK-21…28 (web) | `test_web_checkin.py` | host cookie attributes and email notice; every page needs a session and a CSRF pair; one hour or sign-out ends it; sign-in rate limit; I'M OK once however often the form is sent; a settled miss; once contacts are told the page asks for I'M SAFE and the password, a wrong password changes nothing, the all-clear is sent, a repeated form is one event; another person's incident cannot be closed |
| TST-01…06 | `test_test_support.py` | not mounted unless enabled; token on every call; the clock moves forward for everything that reads it; bad steps refused; console mail is readable; refused in production, token required outside tests |
| Grants | `test_db_grants.py`, `test_migrations.py` | API may delete a wrapped key but not rewrite it; the maintenance role removes users and scrubs contacts but reads neither addresses, hashes, content nor keys and cannot update an audit row |
| Contracts | `test_phase7_contracts.py` | `docs/contracts/phase7`: the feed (two pages, bad cursor), export, deletion and their problems |

**Phase 7 status (mobile half; built, widget/unit level).** `mobile/test/features/incidents/` (153: models with every unknown value, the I'M SAFE controller's key discipline, Home Grace/Notified/`requires=safe`, the sheet, timeline, history/detail), `test/features/plan/plan_editor_*` (120: draft rules, controller answers, screen), `test/features/activity/`, `test/features/privacy/` (export, delete, closed-account notice), `test/core/upgrade/upgrade_gate_test.dart` (426 gate), `test/features/offline/offline_behaviour_test.dart`, `test/core/platform/file_export_test.dart`, `test/contracts/phase7_contract_test.dart` (every golden of `docs/contracts/phase7`, including the two incident goldens with releases and all five problems), and the accessibility matrix extended by about 70 screens at 2.0 text scale in light and dark. Coverage gates added at 90% for `lib/features/incidents/`, `features/activity/`, `features/privacy/`, `core/upgrade/`, `core/freshness/`; `lib/features/plan/` stays at 90% with the editor (99.7%).

**MOB-61…65 (`mobile/integration_test/`, emulator ↔ dev backend with the test clock; `mobile/tool/integration.sh`).** 61 onboarding to an active plan (the contact accepts through the real public pages); 62 I'M OK and the history; 63 a missed deadline, the Grace screen, I'M OK, nobody contacted; 64 escalation, the contact alerted, I'M SAFE with the password, the all-clear sent; 65 account deletion from Settings. **Run on the `AfterMe_API_36` emulator against the real backend with the test clock on 2026-10-11: all six cases pass** (61 ~22 s, 62 ~20 s, 63 ~24 s, 64 ~38 s, 64b I'M OK refused with `safe_required` then I'M SAFE ~27 s, 65 ~31 s; the whole script, cold emulator boot included, 5 min 21 s). A negative control (worker stopped) fails MOB-63 with the missing state, the screen text and the server's view. Not covered by the suite: the system document picker, system permission dialogs and biometric lock, an instruction release to the portal, the Hold circuit breaker, multi-stage plans and the web `/a/checkin` page; there is no CI emulator job yet.

**Phase 8 status (backend half; `backend/tests/notifications/`, `backend/tests/engine/{test_delivery,test_webhooks,test_retention}.py`, `backend/tests/integration/test_devices.py`, `backend/tests/unit/{test_notification_config,test_admin_provider_tests}.py`, `backend/tests/contracts/test_phase8_contracts.py`).**

| Plan ID | Where | Notes |
|---|---|---|
| NOT-01…03 | `test_providers.py` | every provider answer becomes the right failure kind (FCM v1: unregistered / invalid token / quota / unavailable / permission / `401` with one forced refresh; Resend and Postmark by status and error code; SMTP by reply code); the notification id is Resend's idempotency key; service-account JWT signed and verified, cached and refreshed; the metadata server is asked with its header; a network error is transient and leaks nothing |
| NOT-04…06 | `test_chain_and_html.py`, `test_delivery.py` | fallback takes over for an unusable provider and not for a refused address; a failing provider is skipped for 60 s and retried after; everything cooling down still tries; the row records the provider that really sent; retry honours `Retry-After`; give-up after a day tells the person and leaves the contact |
| NOT-07…09 | `test_delivery.py`, `test_webhooks.py` | a refused address: contact `bounced`, address suppressed, nothing more sent, audit shown, person told by email and by a push that names nobody; a dead push token is forgotten and the email still arrives; webhooks: bad signature / stale timestamp / wrong password change nothing, delivered once however often delivered, hard bounce, soft bounce, complaint across accounts, own-address bounce only logged, Postmark Basic auth, malformed body |
| NOT-10…12 | `test_delivery.py`, `test_phase8_contracts.py` | no email subject, text or HTML and no push of a whole released incident contains instruction text; every email has its HTML twin, escaped; every push carries only a type, a version and an incident id, `visibility: PRIVATE`, a known channel and high priority |
| NOT-13…15 | `test_notification_config.py`, `test_retention.py`, `test_devices.py`, `test_admin_provider_tests.py` | production refuses a real provider without key/secret, a non-FCM push provider, a `.invalid` sender; the factory builds the configured chain; notifications and logs are purged after 90 days (not unfinished ones), probes after 30, check-in events after 400, as the real maintenance role; device registration (keep / change / remove; one holder; a web session has none; logout clears); `email-test`/`push-test` print kinds, not addresses |
| E2E-01…03, OPS-03 | **not run** | need the owner's Firebase projects, email provider, DNS and a staging environment (DEPLOYMENT §10 checklist) |

## 5. Security and authorization tests

### 5.1 Authorization matrix (generated)

A test enumerates **every** route in the FastAPI app and checks it against a registry:

```python
ROUTE_POLICY = {
  ("GET",  "/v1/contacts/{contact_id}"): Owned("contact_id", factory=make_contact),
  ("POST", "/v1/checkins"):              Authenticated(),
  ("POST", "/v1/auth/login"):            Public(rate_limited=True),
  ...
}
```

- A route **missing** from the registry fails the build.
- `Authenticated` routes: no token → 401; expired → 401; revoked session → 401; tampered signature or `alg` → 401.
- `Owned` routes: user B with user A's ID → **404** (never 403, never 200); the response body has no data from A.
- Re-auth routes: without fresh reauth → `403 reauth_required`.

### 5.2 Targeted security tests

| ID | Test | Expected |
|---|---|---|
| SEC-01 | User A reads/updates/deletes B's contact, instruction, stage, incident | 404, no changes |
| SEC-02 | A assigns B's contact or stage as a recipient | 404 (service) and FK violation if forced at the DB level |
| SEC-03 | Unknown fields (`next_due_at`, `status`, `user_id`, `tier`) in any body | 422 |
| SEC-04 | Attempt to call release/escalation endpoints (fuzz common paths) | 404/405; route scan proves none exist |
| SEC-05 | Replay `POST /checkins` with the same key; with a new key after token expiry | Same result; 401 |
| SEC-06 | Replay `POST /incidents/{id}/safe` after the reauth window | 403 |
| SEC-07 | Refresh-token reuse outside the grace window | Session revoked; security email |
| SEC-08 | JWT `alg: none`, wrong `aud`/`iss`, wrong `kid`, HS256-signed with the public key | 401 |
| SEC-09 | Login brute force per IP and per account; `X-Forwarded-For` spoofing beyond trusted hops | 429 / lockout; spoofed header ignored |
| SEC-10 | Enumeration: register/forgot responses identical; login timing for unknown vs known email within tolerance | Pass |
| SEC-11 | OTP brute force: 6th attempt rejected; 4th send in an hour rejected | Pass |
| SEC-12 | Portal session for (incident X, contact C) cannot view other contacts' or incidents' releases | 404 |
| SEC-13 | Portal POST without/with a wrong CSRF token | 403 |
| SEC-14 | GET on every portal/account route changes no state (DB snapshot unchanged) | Pass |
| SEC-15 | Security headers on web routes (CSP, HSTS, frame-ancestors, no-referrer, no-store, noindex) | Present |
| SEC-16 | XSS payloads in instruction title/body and display names render escaped in portal and emails | Pass |
| SEC-17 | Display name with URLs/brand terms rejected | 422 |
| SEC-18 | DB grants: `afterme_api` cannot `INSERT` incidents/actions/releases/portal access, nor `UPDATE`/`DELETE` audit logs | Permission denied |
| SEC-19 | Ciphertext swap between two instructions/users fails decryption | Pass |
| SEC-20 | Notification payloads (push data, email bodies, outbox `params`) never contain instruction title/body | Pass |
| SEC-21 | Rate limits on every limited route ([API_SPEC §16](API_SPEC.md#16-rate-limits)) | 429 + `Retry-After` |
| SEC-22 | Body-size limit and pagination caps | 413 / clamp |
| SEC-23 | Test-only router absent when `APP_ENV=prod`; startup fails if forced on | Pass |
| SEC-24 | Production startup refuses insecure config (local KMS, console email, debug, weak engine params) | Pass |
| SEC-25 | **Log-leak test**: all logs captured during ENG-LC-01 contain no password, token, OTP, instruction text or contact email | Pass |
| SEC-26 | Suspended user: no contact-facing actions | Pass |

**Phase 9 status (the SEC-* suite, `backend/tests/security/` and the files named below).** Every row now has a test that was shown able to fail (the test-writing pass broke the app on purpose for SEC-06, 13, 14, 15, 16, 17, 21, 22 and 23, and each matching test failed). Page caps answer `422`, not a clamp.

| ID | Where | Notes |
|---|---|---|
| SEC-01 | `test_authorization_matrix.py` (owned routes), `integration/test_instructions.py`, `test_plan.py`, `test_sessions.py` | other user with the real second-user fixture and a random id, `404` both |
| SEC-02 | `test_sec_02_composite_foreign_keys.py` | cross-owner `instruction_recipients` and `escalation_step_contacts` refused by the database, as `afterme_api` and as the owner; PATCH with a foreign contact or stage is `404` |
| SEC-03 | `test_sec_03_unknown_fields_sweep.py` | every body-taking route, top level and nested; a completeness test against the OpenAPI schema fails the build for a new route without a case |
| SEC-04 | matrix `test_no_route_can_trigger_escalation_or_release` | route scan, plus `TEST_SUPPORT_ROUTE_POLICY` for the four `/test/*` routes |
| SEC-05 | `integration/test_checkins.py`, `engine/test_idempotency_binding.py` | replay, expired token, and (Phase 9) a key used for another operation is `409 idempotency_key_reused` |
| SEC-06 | `test_sec_06_reauth_replay.py` | the window closing between the first request and the replay |
| SEC-07 | `integration/test_refresh.py` | reuse outside the grace revokes and emails once |
| SEC-08 | `unit/test_tokens.py`, matrix | `alg: none`, wrong `aud`/`iss`/`kid`, HS256 with the public key, on every protected route |
| SEC-09 | `integration/test_rate_limits.py` | per IP; per (account, network); spread over networks blocks nobody; `X-Forwarded-For` beyond trusted hops; IPv4-mapped and short headers |
| SEC-10 | `integration/test_timing_parity.py`, `test_login.py` | Argon2 operation counts equal for wrong password, unknown address and **locked account** (Phase 9) |
| SEC-11 | `engine/test_release.py`, `integration/test_register.py`, `test_email_change.py` | attempts counted before comparison |
| SEC-12 | `test_sec_12_cross_incident_portal.py`, `engine/test_release.py` | the same contact in two incidents |
| SEC-13 | `test_sec_13_csrf_with_sessions.py`, matrix | seven wrong ways per POST, with a web and a portal session |
| SEC-14 | `test_sec_14_get_safety.py`, matrix | every web GET with each kind of session and every API GET after a release; 34 tables snapshotted |
| SEC-15 | `test_sec_15_security_headers.py` | built as staging so HSTS is on; error and session pages too |
| SEC-16 | `test_sec_16_xss.py` | markup in every free-text field through the whole lifecycle: pages and every email's HTML twin |
| SEC-17 | `test_sec_17_name_rules.py`, `unit/test_validation.py` | register, profile, contact name and label; look-alike spellings (Phase 9) |
| SEC-18 | `test_db_grants.py`, `test_migrations.py`, `test_notification_boundary.py` | including the notification allow-list and the retention role guards |
| SEC-19 | `integration/test_instructions.py`, `unit/test_crypto.py` | swapped ciphertext, other user, other key version |
| SEC-20 | `engine/test_release.py`, `engine/test_delivery.py`, `test_log_leak_lifecycle.py` | push data, mail, outbox params, logs, audit |
| SEC-21 | `integration/test_rate_limits.py`, `test_sec_21_rate_limit_values.py`, `test_sec_21_missing_limiters.py` | every limiter in API_SPEC §16, with its documented value |
| SEC-22 | `test_sec_22_size_and_paging_limits.py`, `test_sec_22_size_and_page_caps.py` | at the limit and limit+1, declared and streamed |
| SEC-23 | `test_sec_23_test_support_boundaries.py`, `test_sec_23_test_support_exposure.py`, `integration/test_test_support.py` | real provider, staging, production, the router guard, an unauthenticated reset |
| SEC-24 | `unit/test_config.py`, `unit/test_notification_config.py` | production refusals, now including unset environment, DEBUG logging, database TLS, short webhook password |
| SEC-25 | `test_log_leak.py` (four flows), `test_log_leak_lifecycle.py` (the whole lifecycle), `engine/test_logs.py` | production JSON formatter at DEBUG; operator tables included |
| SEC-26 | `test_sec_26_suspended_owner.py`, `test_sec_26_queued_before_suspension.py` | an undoing message (all-clear, withdrawn alert) is deliberately still sent: taking an alarm back is the one contact-facing action a suspension must not stop |

The two sets for SEC-21, 22, 23 and 26 were written independently and overlap; both pass. Merging them is housekeeping.

### 5.3 Mobile security checks
Release APK inspection: no secrets or API keys beyond public Firebase config; `allowBackup=false`; cleartext (the app's own `AppConfig` and zone checks, not the platform config, which does not bind `dart:io`); exported components list (asserted by `tool/check_manifest_permissions.dart` in CI); FLAG_SECURE on instruction screens (manual + instrumentation); tokens only in secure storage (inspect app data on an emulator); no sensitive output in `adb logcat` during a full flow.

## 6. Mobile tests

| ID | Area | Cases |
|---|---|---|
| MOB-01…10 | API client | Single-flight refresh under 5 concurrent 401s; rejected refresh (400/401/403/422, bad body) → logout; transient refresh failure (offline, timeout, 5xx, 429) → session kept and only that request fails; refresh response handled once on a cold start; idempotency key stable across retries; retry only idempotent/keyed requests; error mapping (409 codes, 426, 429) |
| MOB-11…20 | Check-in controller | idle → sending → success; network error → pending persisted → retried on resume; 409 → safe flow; success shown only after 200 |
| MOB-21…30 | Home state mapping | Each state in [USER_FLOWS §4](USER_FLOWS.md#4-home-screen-states) from API fixtures; readiness banner priority |
| MOB-31…45 | Screens (widget) | Onboarding steps; contact add/edit; instruction create with recipients/stage; plan editor validation; reauth/confirm sheets; settings |
| MOB-46…50 | Accessibility | `androidTapTargetGuideline`, `labeledTapTargetGuideline`, `textContrastGuideline` on key screens; layouts at text scale 2.0 without overflow; semantics labels for status |
| MOB-51…55 | App lock | Lock on cold start/timeout (fake auth service); fallback path; disabled state |
| MOB-56…60 | Notifications | Payload → route mapping; foreground display; token refresh → `PUT /devices/current` *(Phase 8, built: `test/contracts/phase8_contract_test.dart` reads `push_payloads.json` so a server type without an app mapping fails; `test/features/notifications/` (push message parsing and routing, the coordinator's token life, flows, privacy: no token or payload in any log), `test/core/push/` (both adapters against a fake platform and mocked channels); manual on a real phone with the dev Firebase project: real token, delivery foreground/background/killed, the three channels and PRIVATE lock-screen rendering, `getInitialMessage` on Android 13+, no `VIBRATE`)* |
| MOB-61…68 | Integration (`integration_test`, dev backend + test clock) | Onboarding → active plan; check-in; simulated miss → grace UI → I'M OK; escalation → I'M SAFE with reauth; export and delete; **Phase 10:** MOB-66 release to the contact's portal and its revocation, MOB-67 two stages with two contacts (+ I'M SAFE after stage 1 only), MOB-68 operator Hold (grace stays, nothing reaches the contact, I'M OK still closes it). The Hold is entered through a host-side helper (`mobile/tool/it_host.py`, 127.0.0.1, token-guarded, fixed commands) because the phone cannot run the operator CLI |

**Phase 4 status of MOB-11…30 (built).** The check-in state machine (MOB-11…20) is `test/features/checkin/checkin_controller_test.dart` (success only after a 200; the key is stored before the request, reused on every retry, after process death and on resume; 409, 429, 426, 401, 503 and storage failures); Home state mapping (MOB-21…30) is `home_status_test.dart`, `home_controller_test.dart` and `home_screen_test.dart`. Repositories are tested over a fake Dio adapter (`checkin_data_test.dart`, `home_data_test.dart`); `phase4_contract_test.dart` parses every file in `docs/contracts/phase4` and asserts the recorded headers. Coverage gates added: `lib/features/checkin`, `lib/features/home`, `lib/core/time` (90%). Review and owner-decision additions: a pending tap survives a real sign-out (`pending_survives_signout_test.dart`), is dropped after 12 h on restore and before every retry (boundaries 12 h exactly / 11 h 59 m / negative age; open offline, resume, "Try again", 429 wait; mutation-checked), and the schedule screen follows a confirmed check-in; the password sheet for a longer interval (sheet then one retry with the same `If-Match`, cancel keeps the edits, wrong password, shortening / time-only / inactive need none; `problem_reauth_required_lengthen` in the contract test). MOB-61…65 (integration against the dev backend) were manual in Phase 4 (walked on the emulator, including an offline tap, process kill and relaunch) and are automated from Phase 7 (`mobile/integration_test/`, `mobile/tool/integration.sh`).

## 7. End-to-end and operational tests (staging)

| ID | Scenario |
|---|---|
| E2E-01 | Full lifecycle with a real device, real email to test inboxes and real FCM (staging project), **in real time**: configuration refuses the test clock together with a real email provider (`config.py`, Phase 9), so the staging run uses the shortest grace period the product allows (60 minutes, a Premium test account, and the deadline placed by a database UPDATE: about 1 h 10 min per rehearsal) and, for a release, a stage 24 h out: about a day. The emulator suite (MOB-61…68, test clock, real processes) is where the whole lifecycle is proven at speed |
| E2E-02 | Lost phone: escalation running → web `/a/checkin` → I'M SAFE → all-clear |
| E2E-03 | Contact journey on mobile browsers (Chrome Android, Safari iOS, Gmail in-app browser) |
| OPS-01 | **Game day: ingress outage.** Block the probe/ingress for 15 min → Hold → recovery → shift verified for incidents that were open, and the anchor rule for a deadline that passed inside the Hold (rehearsed by `make gameday`) |
| OPS-02 | Kill all workers 30 min → heartbeat page → restart → correct catch-up |
| OPS-03 | Invalid email-provider credentials → retries → fallback provider → backlog alert |
| OPS-04 | Database failover (managed HA) during load → no duplicate effects; API 503s retried by clients |
| OPS-05 | Backup restore into a scratch instance; app boots against it; data spot-checked |

**Phase 10 status.** What can be rehearsed without your accounts is built: `make gameday` (backend/scripts/gameday.py) runs OPS-01, OPS-02 and OPS-03 against a throwaway database with the real API and worker processes ([GAMEDAYS.md](GAMEDAYS.md) is the procedure for the real thing in staging); `python -m cli.admin beta-report` produces the incident review the beta needs ([BETA_PLAN §7](BETA_PLAN.md#7-reviewing-an-escalated-incident)); `.github/workflows/nightly.yml` runs the lifecycle 100× every night and `.github/workflows/emulator.yml` the emulator suite weekly. **Not run, because they need what only you can supply:** E2E-01…03, OPS-03/04/05 against real providers and infrastructure, and the manual sheet on real phones ([MANUAL_TEST_SHEET.md](MANUAL_TEST_SHEET.md)).

## 8. Manual test checklist (before each beta/production release)

- *The executable version of this list, with steps, expected results and severities, is [MANUAL_TEST_SHEET.md](MANUAL_TEST_SHEET.md).*
- **Devices:** Pixel (stock Android 15/16), Samsung (One UI), Xiaomi/Redmi (HyperOS, aggressive battery), Oppo/OnePlus (ColorOS); one low-end device (≤ 3 GB RAM); Android 8.0 (minSdk) emulator.
- **Accessibility:** TalkBack full journey (onboarding → check-in → I'M SAFE); font size max + display size max; dark mode; reduce motion.
- **Permissions:** notifications denied/granted/revoked later; no biometrics enrolled; device without screen lock.
- **Lifecycle:** process death during check-in (pending survives); app update with an existing session; reinstall (secure storage cleared → login).
- **Network:** airplane mode, flaky network (throttled), captive portal.
- **Notifications:** delivery with the app killed, Doze, battery saver; lock-screen privacy (public version).
- **Emails:** rendering in Gmail (web/Android/iOS), Outlook, Apple Mail; plain-text part; dark-mode email clients; links with fragments open correctly.
- **Copy review:** every user and contact message against [USER_FLOWS §15](USER_FLOWS.md#15-wording-rules).

## 9. Performance tests

| ID | Target |
|---|---|
| PERF-01 | `POST /v1/checkins` p95 < 500 ms at 50 rps (staging-size DB with 100k users) |
| PERF-02 | 10,000 users due in the same minute → all incidents opened within 2 min (1 worker) |
| PERF-03 | Dispatcher ≥ 50 messages/s with a fake provider |
| PERF-04 | `GET /v1/home` p95 < 300 ms |
| PERF-05 | App cold start < 2 s on a mid-range device; no jank (> 16 ms frames) on Home |

**Phase 11 status.** `make perf` (backend/scripts/perf.py, 100,000 seeded users, real API and worker on a throwaway database) measured on an Apple M2 laptop with PostgreSQL 14, everything local, so indicative only: PERF-01 p95 19 ms (0 errors of 3,000, each stored once), PERF-04 p95 ≤ 25 ms in four Home states, PERF-02 10,000 incidents opened by +71 s with no duplicates, PERF-03 176 msg/s with 20–50 ms simulated provider latency. PERF-01 and PERF-02 **failed** before Phase 11 (p95 1,132 ms; last incident +534 s): fixed by migration `0011` (13 indexes, plans in `backend/tests/perf/PLANS.md`), concurrent engine units (4 at a time, each its own per-user transaction), a narrower reminder scan and an outbox drain loop. `tests/perf/test_hot_path_plans.py` keeps the hot paths on indexes and pins per-request round trips. **Re-measure on staging (Cloud SQL, Cloud Run).** PERF-05: on the emulator, time to first frame fell from 908 to 632 ms (profile build) and cold start now makes 2 requests instead of 7; **a real mid-range phone is still needed** for the target and for frame timings (`mobile/tool/perf_startup.sh --device <serial>`).

## 10. CI gates

| Stage | Backend | Mobile |
|---|---|---|
| Format | `ruff format --check` | `dart format --set-exit-if-changed .` |
| Lint / types | `ruff check`, `mypy app` | `flutter analyze` |
| Tests | `pytest` (all suites) with PostgreSQL service | `flutter test --coverage` |
| Migrations | `alembic upgrade head && alembic downgrade base && alembic upgrade head` + drift check | — |
| Security | `pip-audit`, gitleaks | dependency audit, gitleaks |
| Build | Docker image build | `flutter build apk --flavor dev` (compile check) |
| Coverage | `escalation/`, `checkins/`, `releases/`, `notifications/` ≥ 95% branch; overall ≥ 85% | ≥ 70% lines (controllers/interceptors ≥ 90%) |

Engine lifecycle and concurrency tests are also run **100× in a nightly job** to catch flakiness.

## 11. Defect severity

| Sev | Definition | Examples | Release blocker |
|---|---|---|---|
| **S1** | Safety or privacy failure | Wrongful alert/release; cross-user data exposure; sensitive data in logs or notifications; check-in impossible | Always |
| **S2** | Core feature broken, no workaround | Can't add a contact; reminders not sent; portal unusable | Always |
| S3 | Degraded, workaround exists | Wrong copy, minor layout issue at 200% text | Case by case |
| S4 | Cosmetic | Spacing, typos in non-critical text | No |

## 12. Release acceptance criteria

**Closed beta (Play closed testing):**
- All **M** requirements implemented; zero open S1/S2.
- All ENG-*, SEC-*, AUTH-* tests green; nightly 100× lifecycle run green for 7 consecutive nights.
- Manual checklist done on ≥ 3 OEMs; Phase 9 security review complete; privacy policy and terms live.
- Game days OPS-01…OPS-03 passed in staging.

**Production:**
- Closed test ≥ 14 days with ≥ 12 opted-in testers (if a personal developer account).
- **Zero** wrongful contact messages during beta (every escalated incident reviewed).
- Crash-free sessions ≥ 99.5%; ANR rate below Play's bad-behaviour thresholds.
- OPS-04/05 passed; alerts routed to a person; Data safety form and store listing complete.
