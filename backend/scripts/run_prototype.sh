#!/usr/bin/env bash
# The laptop prototype server: the API, the escalation worker and an ngrok tunnel on one
# fixed public address, with the Mac kept awake while it runs. Ctrl-C stops everything.
#
#   backend/scripts/run_prototype.sh your-name.ngrok-free.app
#
# Needs: Postgres running, `ngrok config add-authtoken <token>` done once, and in
# backend/.env AFTERME_PUBLIC_BASE_URL / AFTERME_API_BASE_URL set to https://<that domain>.
# Only the API port is published; the database and the rest of the laptop stay private.
set -euo pipefail

DOMAIN="${1:-${AFTERME_NGROK_DOMAIN:-}}"
if [ -z "$DOMAIN" ]; then
  echo "usage: $0 <your-static-domain.ngrok-free.app>" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"
LOGS="${AFTERME_PROTOTYPE_LOGS:-$HOME/AfterMe-server-logs}"
mkdir -p "$LOGS"

uv run alembic upgrade head

pids=()
cleanup() {
  echo "stopping…"
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# No --reload: this is a server people use, not an editor session.
uv run uvicorn app.main:app --host 127.0.0.1 --port 8000 --no-access-log --no-proxy-headers \
  >>"$LOGS/api.log" 2>&1 &
pids+=($!)
uv run python -m workers.engine >>"$LOGS/worker.log" 2>&1 &
pids+=($!)
# Keep the Mac awake (display may sleep) for as long as this script runs.
caffeinate -i -s -w $$ &
pids+=($!)

for _ in $(seq 1 30); do
  curl -sf http://127.0.0.1:8000/health/ready >/dev/null && break
  sleep 1
done

echo "API + worker running. Logs: $LOGS"
echo "Public address: https://$DOMAIN"
ngrok http 8000 --url "https://$DOMAIN" --log stdout --log-level warn >>"$LOGS/ngrok.log" 2>&1 &
pids+=($!)
# macOS bash 3.2 has no `wait -n`: watch the processes instead.
while :; do
  for pid in "${pids[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "a process stopped; see $LOGS" >&2
      exit 1
    fi
  done
  sleep 5
done
