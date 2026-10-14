# AfterMe backend

FastAPI + async SQLAlchemy + PostgreSQL. Phase 1 (see `docs/ROADMAP.md`) is the development
foundation and the authentication core; Phase 2 adds password reset (JSON + web page), change
password / email, profile updates, the Phase 2 security emails and the golden contract files for
the mobile app. Phase 3 adds trusted contacts: CRUD with tier limits, invitations with explicit
consent, the recipient web pages (accept, decline, opt-out), the global suppression list and
`GET /v1/me/entitlements`. Phase 4 adds the check-in system: the schedule (`ETag` / `If-Match`),
activation, I'M OK with idempotent replay and the per-user lock, check-in history and the
`GET /v1/home` aggregate. Phase 5 adds the escalation engine: the plan (`/v1/plan`), incidents (`/v1/incidents`, I'M SAFE), the worker process that opens incidents and runs their timeline behind a safety gate, the outbox dispatcher, the system Hold circuit breaker with the probe endpoint, and the operator CLI. The design documents in `../docs` are the source of truth.

## Requirements

| Tool | Version | Notes |
|---|---|---|
| uv | 0.9+ | Installs Python and the locked dependencies |
| Python | 3.13 (uv-managed) | Pinned in `.python-version`; `uv python install 3.13` |
| PostgreSQL | 14+ locally, 17 in CI | SQL stays compatible with 14; production targets 16+ |

Docker is not needed.

## First-time setup

```bash
cd backend
make setup
```

`make setup` runs, in order:

1. `uv sync`: creates `.venv` from `uv.lock`.
2. `scripts/dev_db_setup.sh`: idempotent; run as a PostgreSQL superuser (the Homebrew default OS
   user works). It creates the login roles `afterme_owner` (migrations, CREATEDB), `afterme_api`,
   `afterme_worker` and the no-login roles `afterme_maintenance`, `afterme_readonly`, plus the
   databases `afterme_dev` and `afterme_test` owned by `afterme_owner`. Role passwords come from
   `AFTERME_OWNER_DB_PASSWORD`, `AFTERME_API_DB_PASSWORD` and `AFTERME_WORKER_DB_PASSWORD`, with
   dev-only defaults. Nothing is written to disk.
3. `scripts/write_dev_env.py` creates `backend/.env` from `.env.example` (only if it does not exist
   yet): it puts `AFTERME_OWNER_DB_PASSWORD` / `AFTERME_API_DB_PASSWORD` (when set) into the two
   database URLs and appends a fresh Ed25519 JWT signing key and HMAC pepper from
   `scripts/generate_jwt_key.py --with-pepper`. The file is built in a private temporary file
   (mode 0600) and renamed into place, so a failure never leaves a half-written `.env`.
   `.env` is git-ignored and is read only when `AFTERME_APP_ENV` is unset or `dev`. With no `.env` file and `AFTERME_APP_ENV` unset the process **refuses to start** (Phase 9: a forgotten variable must not silently switch every production refusal off).
4. `alembic upgrade head` against `afterme_dev`, as `afterme_owner`.

## Everyday commands

| Command | What it does |
|---|---|
| `make run` | API on http://127.0.0.1:8000 with auto-reload (`uvicorn app.main:app`) |
| `make migrate` | `uv run alembic upgrade head` (dev database) |
| `make test` | `pytest --cov=app`: real PostgreSQL, coverage gate 85% on the full run |
| `make migrate-check` | migration round trip (upgrade, downgrade, upgrade) on a throwaway database; never touches `afterme_dev` |
| `make fmt` / `make fmt-check` | `ruff format` (+ safe `ruff check --fix`) / check only |
| `make lint` | `uv run ruff check .` |
| `make typecheck` | `uv run mypy app` (strict) |
| `make audit` | pip-audit; fails only on advisories that have a fix |
| `make latest-mail` | prints the newest file in `.dev_mail/` (signup code, reset link, notices) |
| `make contracts` | regenerates `docs/contracts/phase2` to `phase5` (`*.json`) after an intentional API change |
| `make worker` | the escalation worker: engine tick + outbox dispatcher (`python -m workers.engine`, connects as `afterme_worker`) |
| `make maintenance` | the retention job once (`python -m workers.maintenance`, `--every N` loops): scrubs the contacts of closed accounts once their all-clear has left and hard-deletes accounts 30 days after the request |
| `make admin ARGS="email-test --to ADDRESS"` / `ARGS="push-test --token TOKEN"` | prove a provider configuration end to end (DNS, keys, project) without touching an account: prints `ok: provider=… message_id=…` or the failure kind |
| `make admin ARGS="status"` | operator CLI: `status` (exit 1 if anything would page), `hold status`, `hold enter --reason "…"`, `hold exit [--include-ingestion]`, `incident void <id>`, `action retry <id>` |
| `make admin ARGS="beta-report [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--json]"` | the closed-beta review (TEST_PLAN §12): metrics for the period, then every incident in which a contact was messaged, with a timeline in minutes from the due time, per-contact delivery (`contact-1`, `contact-2`) and deterministic verdict hints; incidents that tripped a wrongful-alert-candidate rule say `NEEDS HUMAN REVIEW`. Read-only (a `READ ONLY` transaction, no audit row); only UUIDs, counts, template keys, statuses and times. Dates are UTC days, both inclusive |
| `make engine-gate` | the Phase 5 exit gate: the T0-T8 lifecycle 100 times in a row, then every engine suite |
| `make gameday` | the game-day rehearsal of OPS-01..03 against the real API and worker processes on a throwaway database (`afterme_gameday`, ports from 8010); prints a PASS/FAIL table, exit 0 only if all pass; `ARGS="--only ops-02"` for one scenario (see below and `docs/GAMEDAYS.md`) |
| `make check` | format check, lint, types, tests with the coverage gate, audit (CI additionally runs the migration round trip: `make migrate-check`) |

Coverage is not on by default, so a single file or `-k` run exits 0 when its tests pass:
`uv run pytest tests/unit/test_tokens.py`.

API docs (outside production): http://127.0.0.1:8000/v1/docs and `/v1/openapi.json`.

### Emails in development

`AFTERME_EMAIL_PROVIDER=console` writes every email (signup codes, reset links, security notices) to
`backend/.dev_mail/` as a text file readable only by you. Logs contain the file path only.

```bash
make latest-mail          # prints the newest message, e.g. the signup code or the reset link
```

### Trying the API locally (sign up, reset a password, change email)

Start the server (`make run`), then:

```bash
# 1. Sign up: a 6-digit code is mailed to .dev_mail/
curl -s -X POST localhost:8000/v1/auth/register/start -H 'content-type: application/json' \
  -d '{"email":"me@example.com","password":"correct horse battery staple",
       "display_name":"Me","timezone":"Asia/Kolkata"}'
make latest-mail                      # read the code
curl -s -X POST localhost:8000/v1/auth/register/verify -H 'content-type: application/json' \
  -d '{"email":"me@example.com","code":"123456","password":"correct horse battery staple",
       "device":{"platform":"android","app_version":"1.0.0+1","os_version":"15","locale":"en"}}'

# 2. Forgot password: the answer is always 202; the mail holds http://localhost:8000/a/reset#pr_...
curl -s -X POST localhost:8000/v1/auth/password/forgot -H 'content-type: application/json' \
  -d '{"email":"me@example.com"}'
make latest-mail                      # copy the link into a browser, choose a new password
```

The reset page (`/a/reset`) is plain server-rendered HTML: open the link from the email in a
browser; the `#pr_...` fragment is copied into the form by a small script and never sent to the
server until you submit. After the reset every session is signed out, so sign in again.
`PUBLIC_BASE_URL` (default `http://localhost:8000`) is the origin used in that link. The CSRF
cookie is `Secure` (`__Host-` prefix), which browsers keep only on `http://localhost` or HTTPS.
So the reset page cannot be completed from the Android emulator's browser at plain-HTTP
`http://10.0.2.2:8000`: the cookie is dropped and `POST /a/reset` answers with the 403 page. Use
one of these instead:

- open the emailed link in a browser on the host machine (`localhost`), or
- run `adb reverse tcp:8000 tcp:8000` and set `PUBLIC_BASE_URL=http://localhost:8000`, so the
  emulator's own `localhost` reaches the server, or
- put an HTTPS tunnel in front of the server and set `PUBLIC_BASE_URL` to its `https://` origin.

Signed-in calls take `Authorization: Bearer <access_token>` (`$TOKEN` below is the
`access_token` from the login or verify response):

```bash
curl -s -X PATCH localhost:8000/v1/me/profile -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d '{"display_name":"Asha","phone_e164":"+919876543210"}'
curl -s -X POST localhost:8000/v1/auth/password/change -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"current_password":"correct horse battery staple","new_password":"a brand new passphrase 77"}'
# Email change needs a fresh /v1/auth/reauth first (5 minutes), then:
curl -s -X POST localhost:8000/v1/auth/email/change/start -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d '{"new_email":"new@example.com"}'
make latest-mail                      # the 6-digit code for the new address
curl -s -X POST localhost:8000/v1/auth/email/change/verify -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d '{"code":"123456"}'
```

### Trying trusted contacts (add a contact, read the invitation link)

```bash
# Add a contact (a free account may have 1, premium 25). The invitation is "sent" to .dev_mail/.
curl -s -X POST localhost:8000/v1/contacts -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"display_name":"Mom","relationship":"mother","email":"mom@example.com"}'
make latest-mail      # the invitation: it holds .../c/open#ci_... (accept/decline)
                      # and .../c/optout#oo_... (stop emails)
```

Open the `/c/open#ci_...` link in a browser **on the host machine** (the CSRF cookie is
`Secure`, see the note above). The page shows the invitation; *Accept* or *Decline* answers it,
and the account holder gets a notice mail (`make latest-mail` again). The `/c/optout#oo_...` link
offers "stop emails from this sender" or "Never contact me about AfterMe again" (global
suppression: later contacts with that address are created but never mailed).

```bash
curl -s localhost:8000/v1/contacts -H "authorization: Bearer $TOKEN"              # list
curl -s -X PATCH localhost:8000/v1/contacts/$ID -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d '{"priority":2,"phone_e164":"+919876543210"}'
curl -s -X POST localhost:8000/v1/contacts/$ID/invitation -H "authorization: Bearer $TOKEN"   # resend
curl -s -X DELETE localhost:8000/v1/contacts/$ID -H "authorization: Bearer $TOKEN"            # 204
curl -s localhost:8000/v1/me/entitlements -H "authorization: Bearer $TOKEN"        # limits, usage
```

To try a premium limit locally, set the tier in the dev database (there is no billing yet):
`psql afterme_dev -c "UPDATE users SET tier='premium' WHERE email_normalized='me@example.com'"`.

### Golden contract files

`../docs/contracts/phase2/` (auth and profile) and `../docs/contracts/phase3/` (contacts and
entitlements) hold a scrubbed request/response example for every JSON endpoint (`index.json` lists
them), plus the main error shapes (`plan_limit_reached`, `contact_duplicate`,
`cannot_be_own_email`, `invalid_state`, `rate_limited`, `email_unverified`, ...). `tests/contracts`
replays a full session per phase and fails when the API output differs from the committed files;
the mobile tests parse the same files. After an intentional API change run `make contracts`, review the diff and tell the
mobile side. The files contain fictional placeholders only.

## Tests

`uv run pytest` needs only a running PostgreSQL with the roles from `dev_db_setup.sh`.

* The suite creates `AFTERME_TEST_DB_NAME` (default `afterme_test`) as `afterme_owner` if it is
  missing and runs the migrations once per session. The app under test connects as `afterme_api`,
  so a missing GRANT fails a test.
* Every test starts from empty tables (TRUNCATE as the owner). Tests are order-independent and
  can be run repeatedly.
* Time is driven by `FrozenClock`; there are no sleeps.
* Connection knobs: `AFTERME_TEST_PG_HOST`, `AFTERME_TEST_PG_PORT`, and the role password
  variables above.

Layout: `tests/unit` (pure functions), `tests/integration` (API + database),
`tests/security` (authorization matrix incl. web pages, DB grants, log-leak, migrations/drift,
ownership rule), `tests/contracts` (golden files for the mobile app).

To run the suite next to other work on the same machine use a scratch database (PostgreSQL 14
cannot harden a database created by the owner role, so create it with the script):

```bash
AFTERME_TEST_DB_NAME=afterme_scratch scripts/dev_db_setup.sh
AFTERME_TEST_DB_NAME=afterme_scratch uv run pytest
dropdb afterme_scratch
```

## Configuration

All settings are environment variables with the `AFTERME_` prefix, validated at startup by
`app/core/config.py`. `.env.example` is the dev template; `docs/DEPLOYMENT.md` §4 is the full
platform-level list (it also names variables that arrive in later phases).

"Required" means the process refuses to start in `staging`/`prod` unless the variable is set
explicitly (not left at its default). **(S)** marks a secret: it comes from the secret manager,
is held as `SecretStr`, and never appears in logs or validation errors.

| Variable | Default | Required in staging/prod | Constraint |
|---|---|---|---|
| `APP_ENV` | none (`dev` when `.env` exists) | yes | `dev`, `test`, `staging`, `prod`. A `.env` file can never change it. Unset with no `.env`: startup is refused. In `dev` and `test` a database URL that is not on this machine is refused. |
| `DEBUG` | `false` | no | Must be `false` in staging/prod. |
| `LOG_LEVEL` | `INFO` | no | `DEBUG`, `INFO`, `WARNING`, `ERROR`. JSON logs in staging/prod, console in dev. `DEBUG` is refused in staging/prod. |
| `PUBLIC_BASE_URL`, `API_BASE_URL` | `http://localhost:8000` | yes | Absolute URL, no trailing `/`; `https` in staging/prod. `PUBLIC_BASE_URL` forms the problem `type` URLs and the origin of the password-reset link `{PUBLIC_BASE_URL}/a/reset#<token>` in emails: it must be the address of the web pages as users reach them. |
| `DATABASE_URL` **(S)** | dev URL (`afterme_api`) | yes | `postgresql+psycopg://` URL of the `afterme_api` role. |
| `MIGRATION_DATABASE_URL` **(S)** | dev URL (`afterme_owner`) | yes (migration job) | Role `afterme_owner`; used by Alembic only. |
| `DB_POOL_SIZE` | `10` | no | 1 to 100. |
| `DB_MAX_OVERFLOW` | `5` | no | 0 to 100. |
| `DB_STATEMENT_TIMEOUT_MS` | `15000` | no | 100 to 600000. |
| `API_LOCK_TIMEOUT_MS` | `5000` | no | 100 to 60000. |
| `JWT_SIGNING_KEYS` **(S)** | none | yes (all envs) | JSON object `{kid: Ed25519 private key PEM}`; other key types are rejected. |
| `JWT_ACTIVE_KID` | none | yes (all envs) | Must be a key of `JWT_SIGNING_KEYS`. |
| `JWT_ISSUER`, `JWT_AUDIENCE` | `afterme-dev`, `afterme-app` | yes | Must be set explicitly so a dev token is never valid elsewhere. |
| `ACCESS_TOKEN_TTL_SECONDS` | `900` | no | 60 to 3600. |
| `SESSION_IDLE_DAYS` | `60` | no | 1 to 365; not above `SESSION_ABSOLUTE_DAYS`. |
| `SESSION_ABSOLUTE_DAYS` | `365` | no | 1 to 730. |
| `HMAC_PEPPER` **(S)** | none | yes (all envs) | At least 32 bytes. Keys code, IP, e-mail and rate-limit hashes. |
| `HMAC_PEPPER_PREVIOUS` **(S)** | none | no | Optional, at least 32 bytes; accepted during pepper rotation. |
| `EMAIL_PROVIDER` | `console` | yes | `console` (dev) or `recording` (tests); both are refused in staging/prod. Real providers: `resend`, `postmark`, `smtp` (+ an optional fallback). |
| `EMAIL_FROM` | `AfterMe <no-reply@afterme.invalid>` | yes | Sender address. |
| `DEV_MAIL_DIR` | `backend/.dev_mail` | no | Where the console provider writes messages (git-ignored). |
| `TRUSTED_PROXY_HOPS` | `0` | yes | Number of trusted reverse proxies in front of the app. `0` means no proxy (the socket peer is the client); `1` for a single load balancer such as Cloud Run. Must be set explicitly in staging/prod; a wrong value makes every per-IP rate limit and every stored `ip_hash` use the proxy address (too low) or lets clients choose their own address (too high). 0 to 10. |
| `MIN_CLIENT_VERSION` | `0.0.0` | no | `major.minor.patch`; older apps get `426 upgrade_required`. |
| `ARGON2_TIME_COST` | `3` | no | Staging/prod: at least 2 (OWASP). Lower values are accepted only with `APP_ENV=test`. |
| `ARGON2_MEMORY_COST_KIB` | `65536` | no | Staging/prod: at least 19456 (OWASP). Test only below that. |
| `ARGON2_PARALLELISM` | `4` | no | 1 to 16. |
| `RATE_LIMIT_ENABLED` | `true` | no | May be `false` only in dev and test. |
| `WORKER_DATABASE_URL` **(S)** | dev URL (`afterme_worker`) | yes | The worker's role; the only role that can create incidents. |
| `PROBE_TOKEN` **(S)** | none | yes | 32+ bytes. Its presence turns the ingestion Hold trigger on; `POST /internal/probe` needs it. |
| `TICK_SECONDS`, `GRACE_MIN_MINUTES`, `GRACE_MAX_MINUTES`, `STAGE_MIN_GAP_MINUTES`, `STAGE_MAX_OFFSET_MINUTES`, `MIN_RELEASE_OFFSET_MINUTES`, `FINAL_WARNING_LEAD_MINUTES`, `SETTLE_DELAY_SECONDS`, `INGESTION_PROBE_INTERVAL_SECONDS`, `INGESTION_STALE_SECONDS`, `HOLD_EXIT_FRESH_SECONDS`, `HOLD_RECOVERY_BUFFER_MINUTES`, `ANOMALY_FLOOR_PER_HOUR`, `ACTION_MAX_ATTEMPTS` | spec defaults | no | `docs/ESCALATION_ENGINE.md` §13. Refused at startup: `SETTLE_DELAY_SECONDS` not above `INGESTION_STALE_SECONDS`; in staging/prod `MIN_RELEASE_OFFSET_MINUTES` below 1440 or `SETTLE_DELAY_SECONDS` below 300. |

Beyond the table, staging and prod refuse to start with development email providers, non-HTTPS
base URLs, a missing or short pepper, missing JWT keys, debug mode, weak Argon2 parameters,
disabled rate limiting, or implicit database URL, JWT issuer/audience or proxy hops. OpenAPI and
the docs UI are off in `prod`. Every problem is reported at once, without secret values.

**Client IPs and proxies.** The app works out the client address itself, from `X-Forwarded-For`
through `AFTERME_TRUSTED_PROXY_HOPS` hops (`app/core/net.py`). Always start uvicorn with
`--no-proxy-headers` (the Makefile does), otherwise uvicorn rewrites the peer address from the
header first and a client on loopback can choose its own address. IPv6 clients are rate-limited
per /64 network, not per address.

### Production start command

`backend/Dockerfile` builds one image for every process (`uv sync --frozen --no-dev`, the Python
version of `.python-version`, a non-root user, no secrets in any layer); the command chooses the
process: the API by default, `python -m workers.engine`, `python -m workers.maintenance --every
900`, `python -m cli.admin …`, `alembic upgrade head`. The API command is the one below with the
port taken from `PORT` (default 8080). The image is built, and checked to import, by the `docker`
job of `.github/workflows/backend.yml`. Outside a container the process is started like this, with
the environment variables above supplied by the platform:

```bash
uv run alembic upgrade head          # migration job, as afterme_owner, before the rollout
uvicorn app.main:app --host 0.0.0.0 --port "${PORT:-8000}" \
  --workers 2 --no-proxy-headers --no-access-log --no-server-header
```

`--no-proxy-headers` is mandatory (client IP handling is in the app), `--no-access-log` because
the app writes its own structured access log without query strings. Set `--workers` to the CPU
count of the instance and size `DB_POOL_SIZE` per worker.

### The escalation engine (Phase 5)

```
make worker            # in a second terminal: opens incidents, runs the timeline, sends the outbox
make admin ARGS="status"
```

* **Who can do what.** Only the worker creates incidents, actions and messages. The API role cannot
  `INSERT` them (a database grant), and the API process never imports `app/engine`. The API reads
  incidents and can stop one: an I'M OK before anyone was messaged, or I'M SAFE.
* **Local development.** Emails go to `.dev_mail/` (console provider), push is logged only. With
  no `PROBE_TOKEN` the ingestion Hold trigger is off, so deadlines open incidents normally. To try
  the Hold: set `AFTERME_PROBE_TOKEN` (32+ characters) and `POST /internal/probe` with
  `X-Probe-Token`, or `make admin ARGS='hold enter --reason try-it'`.
* **Trying a miss quickly.** Activate a schedule (a verified contact and a plan are needed), then
  move the deadline into the past in the database:
  `UPDATE checkin_configurations SET next_due_at = now() - interval '1 minute' WHERE user_id = '…'`.
  The next tick (15 s) opens the incident; stages follow at `grace` and `offset` minutes, and a
  contact message waits 5 minutes (`AFTERME_SETTLE_DELAY_SECONDS`) before it is sent.
* Configuration: `docs/ESCALATION_ENGINE.md` §13 and §13.1 (every parameter is `AFTERME_<NAME>`).

### Game-day rehearsal (Phase 10)

`make gameday` rehearses the operational game days of `docs/TEST_PLAN.md` §7 locally, against the
**real** processes: OPS-01 (probe path and ingress down for 15 simulated minutes: Hold, backdated
start, rollback and shift on exit), OPS-02 (the worker `SIGKILL`ed for 30 simulated minutes:
heartbeat page, anchor rule, a stage put back with `incident_delayed`, nothing sent twice) and
OPS-03 (the Resend credentials rejected, then both providers: fallback, backoff, the backlog page,
the drain), in about five minutes.

```bash
make gameday                         # all three; exit 0 only if every check passes
make gameday ARGS="--only ops-02"    # ops-01, ops-02, ops-03
```

* It needs the `.venv` and a local PostgreSQL reachable as a superuser by `psql -d postgres` (like
  `mobile/tool/integration.sh`). It creates, migrates and drops **only** `afterme_gameday` (never
  `afterme_dev`, `afterme_test`, `afterme_it`) and starts uvicorn and `python -m workers.engine` on
  the first free ports from 8010, with test support on (a random shared token), rate limits off, a
  one-second worker tick and the test clock. `APP_ENV=test` keeps `backend/.env` out of it.
* Each scenario starts from a freshly created database and fresh users. OPS-03 drives the real
  `Engine` and `Dispatcher` in-process (a worker subprocess cannot take an injected HTTP transport)
  with an `httpx.MockTransport` for the two providers.
* A check that asserts something a design document promises and fails prints `FAIL (defect)`.
  Everything it started is stopped on exit, on Ctrl-C and on the next run; run it twice if in doubt.
* What it cannot prove (real providers, a real uptime check, a real pager, two replicas) is the
  staging procedure in `docs/GAMEDAYS.md`. The pure parts of the harness are unit-tested
  (`tests/unit/test_gameday_checks.py`).

### Endpoints (Phases 1 to 5)

Full contracts: `docs/API_SPEC.md` §2 (registration, login, tokens, passwords, email), §3
(sessions, `/me`, entitlements), §7 (contacts), §13.1 and §13.2 (web pages) and §14 (health).
Error codes: §1.1.

| Method and path | Access | Result |
|---|---|---|
| `POST /v1/auth/register/start` | public | 202 `code_sent` (identical for new, unverified and verified emails) |
| `POST /v1/auth/register/verify` | public | 201 tokens, user (email, 6-digit code and signup password) |
| `POST /v1/auth/register/resend` | public | 202, throttled to one code per 60 s |
| `POST /v1/auth/login` | public | 200 tokens; 401 `invalid_credentials`; 403 `email_unverified`; 429 while locked |
| `POST /v1/auth/refresh` | public (refresh token) | 200 new token pair; 401 `session_revoked` |
| `POST /v1/auth/logout` | authenticated | 204, revokes the current session |
| `POST /v1/auth/logout-all` | authenticated | 204, revokes every session |
| `POST /v1/auth/reauth` | authenticated | 204, opens the 5-minute re-authentication window |
| `GET /v1/auth/sessions` | authenticated | active sessions, `current` flag |
| `DELETE /v1/auth/sessions/{session_id}` | owned | 204; another user's or unknown id: 404 |
| `POST /v1/auth/password/forgot` | public | 202 `email_sent`, identical for every address; mails a 30-minute single-use link to verified accounts only |
| `POST /v1/auth/password/change` | authenticated | 204; revokes the other sessions; 401 `invalid_credentials` shares the `reauth` budget |
| `POST /v1/auth/email/change/start` | re-auth (5 min) | 202 `code_sent` always; code to the new address, notice to the old |
| `POST /v1/auth/email/change/verify` | authenticated | 200 (body of `GET /v1/me`); 400 `invalid_code` |
| `GET /v1/me` | authenticated | id, email, tier, status, profile, created_at |
| `PATCH /v1/me/profile` | authenticated | 200 (body of `GET /v1/me`); any non-empty subset of display_name, phone_e164, country_code, timezone, locale |
| `GET /v1/me/entitlements` | authenticated | tier, limits (contacts 1/25, instructions 3/200, stages 2/10, custom_offsets) and usage |
| `GET /v1/contacts` | authenticated | `{items}` ordered by priority, then created_at (max 25) |
| `POST /v1/contacts` | authenticated | 201 contact; 403 `plan_limit_reached`; 409 `contact_duplicate`; 422 `cannot_be_own_email`; 429 (20 creations and 10 invitations per day); queues the invitation |
| `GET /v1/contacts/{id}` | owned | 200 contact; another user's or unknown id: 404 |
| `PATCH /v1/contacts/{id}` | owned | 200 contact; a new email resets verification and re-invites |
| `DELETE /v1/contacts/{id}` | owned | 204; soft delete that scrubs email, phone and label |
| `POST /v1/contacts/{id}/invitation` | owned | 202 `queued`; 409 `invalid_state` unless pending or bounced; 429 after 3 per 7 days |
| `GET /c/open`, `GET /c/optout` | public web page | landing pages for the emailed links (read the `#ci_` / `#oo_` fragment); never change state |
| `POST /c/session` | public web form + CSRF | token → the invitation page (changes nothing) |
| `POST /c/invite/accept`, `POST /c/invite/decline` | public web form + CSRF | answer an invitation once (decline may add `never_contact`) |
| `POST /c/optout/confirm`, `POST /c/optout` | public web form + CSRF | the two choices; `scope` = `this_person` or `everyone` (global suppression); 20 POSTs per hour per IP on all `/c` routes |
| `GET /a/reset` | public web page | the reset form; never changes state, no database access |
| `POST /a/reset` | public web form + CSRF | token, new_password, csrf; 200 / 400 / 403 / 422 / 429 HTML pages |
| `GET /a/assets/web.css` | public | the one stylesheet of the web pages |
| `GET /v1/checkin/schedule`, `PUT`, `POST …/activate`, `POST …/deactivate`, `POST /v1/checkins`, `GET /v1/checkins`, `GET /v1/home` | authenticated | Phase 4: see API_SPEC §5 and §6 |
| `GET /v1/plan`, `PUT /v1/plan` | authenticated | the escalation plan: `ETag`/`If-Match` (`"plan-<version>"`); 422 field errors, 403 `plan_limit_reached`, 409 `incident_open` |
| `GET /v1/incidents/current`, `GET /v1/incidents`, `GET /v1/incidents/{id}` | authenticated / owned | the incident and its timeline; 404 for a stranger's id |
| `POST /v1/incidents/{id}/safe` | re-auth + `Idempotency-Key` | I'M SAFE: cancels, queues the all-clear, restarts the schedule |
| `GET /v1/instruction-categories`, `GET /v1/instructions`, `POST`, `GET/PATCH/DELETE /v1/instructions/{id}` | authenticated / owned | Phase 6: content is sealed with the owner's key; the list has no body; 403 `plan_limit_reached`, 422 `release_stage_too_early`; a route to someone, switching one off or deleting it needs a fresh password while check-ins are on |
| `GET /c/release`, `POST /c/release/{session,code,verify,view,new-link,end}` | public web + CSRF + portal session | the recipient portal: link → session → one-time code → content (every content page is a POST response); a withdrawn release says so |
| `GET /v1/activity` | authenticated | Phase 7: the Activity feed, newest first, `cursor` paged; names and titles composed for the owner at read time |
| `POST /v1/me/export` | re-auth | Phase 7: the whole account as one JSON download (instructions decrypted); 3 per hour; audited |
| `DELETE /v1/me` | re-auth + `{"confirm":"DELETE"}` | Phase 7: closes the account (incident voided with an all-clear, content erased, key deleted, sessions ended); 202 with `purge_after` |
| `GET/POST /a/delete`, `GET/POST /a/delete/confirm` | public web + CSRF | Phase 7: delete without the app: an emailed single-use link, then the password |
| `GET/POST /a/login`, `GET/POST /a/checkin`, `POST /a/safe`, `POST /a/logout` | public web + CSRF + web session | Phase 7: I'M OK and I'M SAFE from a browser when the phone is lost (a one-hour session) |
| `PUT /v1/devices/current`, `DELETE /v1/devices/current/push-token` | authenticated | Phase 8: the phone's push registration (a token has one holder; omitted keeps it, `null` removes it) |
| `POST /webhooks/email/{resend,postmark}` | provider signature / Basic auth | Phase 8: delivery, bounce and complaint events (bare 404 when unconfigured, 401 when unverified, 204 otherwise) |
| `GET /test/clock`, `POST /test/clock/{advance,reset}`, `GET /test/mail` | `X-Test-Token`, only when enabled | Phase 7: the movable clock and the mail reader for integration tests (never in production) |
| `POST /internal/probe` | `X-Probe-Token` | the uptime monitor's heartbeat (feeds Hold); 404 where no token is configured |
| `GET /health/live`, `GET /health/ready` | public | liveness; readiness (database reachable and Alembic at head, else 503) |

Errors are RFC 9457 `application/problem+json` with `type`, `title`, `status`, `code`, `detail`
and `request_id`.

## Code layout

```
app/
  main.py          create_app() factory; module-level `app` for uvicorn (created lazily)
  core/            config, logging (+redaction), errors (RFC 9457), clock, db, middleware, net
  api/             v1 router assembly, health, shared dependencies (auth, reauth, rate limits)
  auth/            models, schemas, repository, services (signup/login/sessions in service.py,
                   passwords and email in account_service.py), router, JWT tokens, codes, links
  users/           profile model, GET /v1/me, PATCH /v1/me/profile, GET /v1/me/entitlements
  contacts/        trusted contacts, invitations, suppression list: models, schemas, repository
                   (owner-scoped ContactRepository + the contact-facing Portal/Suppression
                   repositories), service, portal_service (what a contact can do), tokens, router
  web/             server-rendered pages under /a and /c (Jinja2 templates, CSS, CSP/CSRF helpers)
  audit/           audit_logs model and the append-only writer
  security/        Argon2id passwords + blocklist, HMAC/SHA-256 helpers, rate limiting, envelope
                   crypto (AES-256-GCM), KMS provider interface + local dev provider, the vault
  notifications/   EmailProvider interface, console/recording providers, text templates (16)
  checkins/        schedule (pure deadline computation, no I/O), models, repository, service
                   (schedule, activation, I'M OK incl. the incident branch, history), router
  home/            GET /v1/home aggregate (read-only: schedule, readiness, incident, activity)
  plans/           the escalation plan: models, pure rules, service, router; releases seam
  instructions/    categories, instructions and recipients: models, schemas, owner-scoped
                   repository, service (seals content with the owner's key), router
  releases/        release events, portal access/tokens/sessions/OTP: models, repository
                   (creation by the engine; revocation one way), portal_service (the recipient
                   portal's logic: every request re-checks contact, account, incident, release)
  incidents/       models, snapshot, owner-scoped repository, closing routine (resolve / I'M SAFE /
                   void), service and router (read + stop only), timeline view
  engine/          WORKER-ONLY (the API never imports it): timeline, gate, opener, executor,
                   dispatcher, hold, runtime, store, releases seam
  ops/             Hold/probe/heartbeat models, POST /internal/probe, operator admin functions
workers/           engine.py: `python -m workers.engine`
cli/               admin.py: `python -m cli.admin` (the operator's command line)
migrations/        Alembic (one revision per change; hand-reviewed)
scripts/           dev_db_setup.sh        roles and databases (idempotent, run as a superuser)
                   write_dev_env.py       creates backend/.env from .env.example
                   generate_jwt_key.py    new Ed25519 key (+ pepper with --with-pepper)
                   migrate_check.sh       migration round trip on a throwaway database
                   audit_deps.py          pip-audit wrapper (fails only on fixable advisories)
                   gameday.py             the OPS-01..03 game-day rehearsal (+ gameday_support/)
```

Each module follows `router → service → repository → models` (ARCHITECTURE §4.3). Repository
methods for user-owned rows require a keyword-only `owner_id`; a test enforces this.

## Migrations

```bash
uv run alembic revision -m "short description" --rev-id 0003   # then edit by hand
uv run alembic upgrade head
uv run alembic downgrade -1
```

Alembic uses `AFTERME_MIGRATION_DATABASE_URL` (the `afterme_owner` role) with the synchronous
psycopg driver. Use `op.f("name")` for explicit constraint names so the naming convention is not
applied twice. The test suite checks upgrade → downgrade → upgrade and that the models match the
migrated schema, including CHECK constraints and partial indexes.

## CI

`.github/workflows/backend.yml` runs on a PostgreSQL 17 service: format check, ruff, mypy, the
migration round trip, pytest with the coverage gate, and the dependency audit. A second job runs
the gitleaks secret scan over the full history. The `docker` job builds `backend/Dockerfile`
(nothing is pushed) and runs `python -c "import app.main"` inside it, checks that the image does
not run as root and that its API command carries `--no-proxy-headers`.
`.github/workflows/nightly.yml` runs the T0-T8 lifecycle and every engine suite 100 times
(`make engine-gate`) and the concurrency suite 100 times, every night.
`.github/workflows/emulator.yml` runs `mobile/tool/integration.sh` on an Android emulator, weekly
and on demand.

## Known limitations

* The initial migration seeds no reference data or default flags. `system_flags` is created (as
  the documented schema requires) but stays empty: Phase 1 reads `MIN_CLIENT_VERSION` from the
  environment, and the first flags that need a stored default arrive with the phase that reads
  them, in that phase's migration.
* Emails are sent right after the request transaction commits, not through an outbox. A crash
  between COMMIT and sending loses that email; the user can request a new code. Phase 8 moves all
  sending to the transactional outbox and dispatcher.
* Phase 2 sends `forgot`/`email change start` emails after the response (a FastAPI background
  task) so delivery time cannot reveal whether an account exists; a crash before sending loses the
  email, as above. A pending (unverified) signup never expires yet (the purge job arrives with the
  maintenance work), but a signup holding an address is superseded when its mailbox owner verifies
  an email change to it.
* Notifications (Phase 8): the adapters (FCM HTTP v1, Resend, Postmark, SMTP), the fallback chain,
  the webhooks and the "contact unreachable" notices are built and tested against mocked
  transports; **nothing has been run against a real provider or a real phone** (that needs the
  owner's accounts: DEPLOYMENT §10). Emails that carry a secret (codes, reset links) go through
  the same provider chain but not the outbox, so a crash between commit and send loses one and the
  person asks again.
* The web pages cover the password reset, the account-deletion page and the lost-phone
  check-in pages (`/a`), and the contact invitation, decline, opt-out and release pages (`/c`).
  The "new link" page links to the app by name only, because App Links (`assetlinks.json`) are
  set up with the deployment phase.
* Test support (Phase 7): the clock offset is read by every `now()` of the API and the worker but
  not by database column defaults (`now()` in DDL), so a few `created_at` values are real time
  while a test clock is on. Mail reading works with the `console` provider on the same machine
  only. Both exist for the integration suite and are refused in production.
* Retention (`app/maintenance/retention.py`, the maintenance job): closed accounts are removed and
  their contacts scrubbed; messages and their log 90 days after their incident closed (never
  while it is open), direct-mail receipts 90 days, probes 30 days, check-in events 400 days,
  expired invitations and portal tokens, sessions and codes 30 days after they ended; login
  sessions and their refresh tokens 30 days after they expired, were revoked or were used
  (never a live session, never a closing account's); devices 90 days after they were last seen
  when no live session runs on them and their owner has no open incident; audit records after
  `AUDIT_RETENTION_DAYS` (default 365, at least 90; counsel confirms the period), except the trail
  of an incident that is still open and anything about an account that is being deleted. Not
  purged: `email_suppressions` (hashes only) and `rate_limit_counters` (trimmed on use).
* `staging`/`prod` need a real email provider (`resend`, `postmark` or `smtp`) and a push
  provider (`fcm`): the `console` and `recording` providers are refused there on purpose.
* The maintenance job (Phase 7) does not yet purge unverified signups older than 24 h, expired
  tokens and expired rate-limit windows (rate-limit rows of a key are trimmed when that key is
  hit).
* Contacts (Phase 3): stage and recipient links do not exist yet, so deleting a contact removes
  none; bounce handling (`bounced`) and the retention purge of expired invitations arrive with the
  email provider and maintenance work. An opt-out link of a contact that was deleted since does
  nothing, because the address was scrubbed at deletion. A suppressed address shows
  `invitation_send_count` 0 on the contact (as specified); the response to creating it is
  otherwise identical to any other. The `afterme_api` role cannot delete contacts or
  invitations by design: invitations are invalidated by moving `expires_at` to the present.
