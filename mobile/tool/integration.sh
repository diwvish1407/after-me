#!/usr/bin/env bash
# Phase 7 integration suite (TEST_PLAN §6, MOB-61..65): the real app on an Android
# emulator against the real dev backend, with the test clock.
#
# What it does, and always cleans up after:
#   1. recreates the throwaway database `afterme_it` (never `afterme_dev`) and migrates it;
#   2. starts the API (127.0.0.1:8000) and the worker against it, both with test support on
#      and one shared random token, rate limits off and a 2-second worker tick; their logs
#      and the mail directory go to a temporary directory;
#   3. uses the attached emulator/device, or boots the AVD headless and waits for it;
#   4. runs every integration_test/mob6*_test.dart (or the ones named), one app install each;
#   5. on a failure prints the tail of the worker and API logs (the tests, which run on the
#      phone, cannot read them); stops what it started.
#
# Usage (from anywhere):
#   mobile/tool/integration.sh                         # all five tests
#   mobile/tool/integration.sh --only mob63_missed_grace_test.dart
#   mobile/tool/integration.sh --keep-emulator         # leave a booted emulator running
#   mobile/tool/integration.sh --device emulator-5554  # a specific attached device
#
# Needs: uv and the backend's .venv (make setup), PostgreSQL running locally with a
# superuser reachable by `psql -d postgres` (your OS user), Flutter, the Android SDK with the
# AVD named by AFTERME_IT_AVD (default AfterMe_API_36). Port 8000 must be free: the app's
# dev flavor (config/dev.json) talks to http://10.0.2.2:8000.
#
# Safe to run twice: the database is dropped and recreated, nothing is left running.
set -euo pipefail

MOBILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$(cd "$MOBILE_DIR/../backend" && pwd)"

IT_DB="afterme_it" # fixed on purpose: this script drops it.
PORT=8000
AVD="${AFTERME_IT_AVD:-AfterMe_API_36}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB="${ADB:-$SDK/platform-tools/adb}"
EMULATOR="${EMULATOR:-$SDK/emulator/emulator}"
OWNER_PW="${AFTERME_OWNER_DB_PASSWORD:-afterme_owner_dev}"
API_PW="${AFTERME_API_DB_PASSWORD:-afterme_api_dev}"
WORKER_PW="${AFTERME_WORKER_DB_PASSWORD:-afterme_worker_dev}"
BOOT_TIMEOUT=300

KEEP_EMULATOR=0
DEVICE=""
ONLY=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-emulator) KEEP_EMULATOR=1 ;;
    --device) DEVICE="${2:?--device needs a serial}"; shift ;;
    --only) ONLY+=("${2:?--only needs a file name}"); shift ;;
    -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

for tool in uv psql flutter openssl curl; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done
[[ -x "$ADB" ]] || die "adb not found at $ADB (set ANDROID_HOME)"
[[ -d "$BACKEND_DIR/app" ]] || die "backend not found at $BACKEND_DIR"

# --- state kept for the cleanup ---------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/afterme-it.XXXXXX")"
API_PID=""
WORKER_PID=""
EMULATOR_PID=""
STARTED_EMULATOR=0
TOKEN="$(openssl rand -hex 32)" # 64 characters; never printed

kill_tree() {
  local pid="$1" child
  [[ -n "$pid" ]] || return 0
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_tree "$child"
  done
  kill "$pid" 2>/dev/null || true
}

cleanup() {
  local code=$?
  set +e
  say "Cleaning up"
  kill_tree "$WORKER_PID"
  kill_tree "$API_PID"
  if [[ "$STARTED_EMULATOR" == 1 && "$KEEP_EMULATOR" == 0 ]]; then
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1
    sleep 2
    kill_tree "$EMULATOR_PID"
  elif [[ "$STARTED_EMULATOR" == 1 ]]; then
    echo "    emulator left running as $SERIAL (--keep-emulator)"
  fi
  echo "    logs: $WORK"
  return "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Redacts the test token from anything shown.
scrub() { sed "s/$TOKEN/<test-token>/g" "$1"; }

# --- 0. the port must be free: never touch somebody else's server ------------------------
if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/health/live" 2>/dev/null; then
  die "something already answers on 127.0.0.1:$PORT. Stop it first: the app's dev flavor (config/dev.json) needs this port for the throwaway backend."
fi

# --- 1. database ---------------------------------------------------------------------
say "Database $IT_DB (recreated)"
if [[ ! -x "$BACKEND_DIR/.venv/bin/uvicorn" ]]; then
  (cd "$BACKEND_DIR" && uv sync --frozen)
fi
psql -X -q -d postgres -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS $IT_DB WITH (FORCE)" >/dev/null
(
  cd "$BACKEND_DIR"
  AFTERME_DEV_DB_NAME="$IT_DB" AFTERME_TEST_DB_NAME="${AFTERME_TEST_DB_NAME:-afterme_test}" \
    ./scripts/dev_db_setup.sh >"$WORK/db_setup.log" 2>&1
) || { cat "$WORK/db_setup.log" >&2; die "database setup failed"; }

DB_HOST="localhost:5432"
URL_API="postgresql+psycopg://afterme_api:$API_PW@$DB_HOST/$IT_DB"
URL_WORKER="postgresql+psycopg://afterme_worker:$WORKER_PW@$DB_HOST/$IT_DB"
URL_OWNER="postgresql+psycopg://afterme_owner:$OWNER_PW@$DB_HOST/$IT_DB"

say "Migrating $IT_DB"
(
  cd "$BACKEND_DIR"
  AFTERME_MIGRATION_DATABASE_URL="$URL_OWNER" .venv/bin/alembic upgrade head \
    >"$WORK/migrate.log" 2>&1
) || { cat "$WORK/migrate.log" >&2; die "migration failed"; }

# --- 2. API and worker ------------------------------------------------------------------
# One environment for both processes, so they share the test clock (it lives in the
# database) and the same token. backend/.env supplies keys and pepper; every variable set
# here wins over it. APP_ENV stays unset (dev) so that .env is read at all.
mkdir -p "$WORK/mail"
backend_env=(
  "AFTERME_DATABASE_URL=$URL_API"
  "AFTERME_WORKER_DATABASE_URL=$URL_WORKER"
  "AFTERME_MIGRATION_DATABASE_URL=$URL_OWNER"
  "AFTERME_MAINTENANCE_DATABASE_URL=$URL_OWNER"
  "AFTERME_TEST_SUPPORT_ENABLED=true"
  "AFTERME_TEST_SUPPORT_TOKEN=$TOKEN"
  "AFTERME_RATE_LIMIT_ENABLED=false"
  "AFTERME_TICK_SECONDS=2"
  "AFTERME_DEV_MAIL_DIR=$WORK/mail"
)

say "Starting the API on 127.0.0.1:$PORT and the worker"
(
  cd "$BACKEND_DIR"
  exec env "${backend_env[@]}" .venv/bin/uvicorn app.main:app \
    --host 127.0.0.1 --port "$PORT" --no-access-log --no-proxy-headers
) >"$WORK/api.log" 2>&1 &
API_PID=$!
(
  cd "$BACKEND_DIR"
  exec env "${backend_env[@]}" .venv/bin/python -m workers.engine
) >"$WORK/worker.log" 2>&1 &
WORKER_PID=$!

wait_for() { # description timeout_seconds command...
  local what="$1" timeout="$2" waited=0
  shift 2
  until "$@" >/dev/null 2>&1; do
    sleep 1
    waited=$((waited + 1))
    if (( waited >= timeout )); then
      echo "--- worker.log" >&2; tail -n 20 "$WORK/worker.log" | sed "s/$TOKEN/<test-token>/g" >&2
      echo "--- api.log" >&2; tail -n 20 "$WORK/api.log" | sed "s/$TOKEN/<test-token>/g" >&2
      die "timed out after ${timeout}s waiting for $what"
    fi
    kill -0 "$API_PID" 2>/dev/null || die "the API process exited (see $WORK/api.log)"
    kill -0 "$WORKER_PID" 2>/dev/null || die "the worker process exited (see $WORK/worker.log)"
  done
}
wait_for "the API to be ready" 60 curl -fsS "http://127.0.0.1:$PORT/health/ready"
wait_for "the worker to start" 60 grep -q "worker.started" "$WORK/worker.log"
wait_for "test support (GET /test/clock)" 20 \
  curl -fsS -H "X-Test-Token: $TOKEN" "http://127.0.0.1:$PORT/test/clock"

# --- 3. the device ----------------------------------------------------------------------
SERIAL="$DEVICE"
if [[ -z "$SERIAL" ]]; then
  SERIAL="$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi
if [[ -z "$SERIAL" ]]; then
  [[ -x "$EMULATOR" ]] || die "no device attached and no emulator binary at $EMULATOR"
  say "Booting $AVD headless"
  "$EMULATOR" -avd "$AVD" -no-window -no-audio -no-snapshot -no-boot-anim \
    >"$WORK/emulator.log" 2>&1 &
  EMULATOR_PID=$!
  STARTED_EMULATOR=1
  SERIAL=""
  waited=0
  while [[ -z "$SERIAL" ]]; do
    sleep 2
    waited=$((waited + 2))
    SERIAL="$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
    (( waited < BOOT_TIMEOUT )) || die "the emulator did not appear within ${BOOT_TIMEOUT}s"
    kill -0 "$EMULATOR_PID" 2>/dev/null || die "the emulator exited (see $WORK/emulator.log)"
  done
fi
say "Waiting for $SERIAL to finish booting"
waited=0
until [[ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
  sleep 2
  waited=$((waited + 2))
  (( waited < BOOT_TIMEOUT )) || die "$SERIAL did not finish booting within ${BOOT_TIMEOUT}s"
done
until "$ADB" -s "$SERIAL" shell pm path android >/dev/null 2>&1; do sleep 1; done
# Animations off: the tests wait on state, not on motion.
for key in window_animation_scale transition_animation_scale animator_duration_scale; do
  "$ADB" -s "$SERIAL" shell settings put global "$key" 0 >/dev/null 2>&1 || true
done
# Is the emulator's port 8000 reaching the host? (10.0.2.2 is the host's loopback.)
"$ADB" -s "$SERIAL" shell "echo ok" >/dev/null

# --- 4. the tests -------------------------------------------------------------------------
cd "$MOBILE_DIR"
if [[ ${#ONLY[@]} -gt 0 ]]; then
  FILES=()
  for name in "${ONLY[@]}"; do
    name="${name##*/}"
    FILES+=("integration_test/${name%.dart}.dart")
  done
else
  FILES=(integration_test/mob6*_test.dart)
fi

declare -a RESULTS=()
FAILED=0
for file in "${FILES[@]}"; do
  [[ -f "$file" ]] || die "no such test file: $file"
  name="$(basename "$file" .dart)"
  say "Running $name on $SERIAL"
  start=$SECONDS
  set +e
  flutter test "$file" -d "$SERIAL" --flavor dev \
    --dart-define-from-file=config/dev.json --dart-define="TEST_TOKEN=$TOKEN" \
    >"$WORK/$name.log" 2>&1
  code=$?
  set -e
  took=$((SECONDS - start))
  scrub "$WORK/$name.log" | grep -v '^$' | tail -n 40
  if [[ $code -eq 0 ]]; then
    RESULTS+=("PASS  $name  (${took}s)")
  else
    FAILED=1
    RESULTS+=("FAIL  $name  (${took}s, exit $code)")
    echo "--- last 20 lines of the worker log ($WORK/worker.log)"
    tail -n 20 "$WORK/worker.log" | sed "s/$TOKEN/<test-token>/g"
    echo "--- last 20 lines of the API log ($WORK/api.log)"
    tail -n 20 "$WORK/api.log" | sed "s/$TOKEN/<test-token>/g"
  fi
done

echo
say "Results"
printf '    %s\n' "${RESULTS[@]}"
exit "$FAILED"
