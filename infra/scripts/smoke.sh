#!/usr/bin/env bash
# Smoke tests against a deployed environment, through the PUBLIC domain. Used by deploy.yml and
# usable by hand.  infra/scripts/smoke.sh https://api.staging.afterme.app
#
# 1. GET /health/live   -> 200
# 2. GET /health/ready  -> 200 (database reachable AND the schema is at the code's Alembic head)
# 3. GET /v1/version    -> any answer below 500 is accepted (the route may not exist; a 5xx is a failure)
# 4. POST /internal/probe without a token -> 401 (the route exists and a probe token is configured;
#    404 would mean no token is configured, which production refuses to start without). The real
#    probe, with the token, is the uptime check's job: CI never holds that token.
# Retries for up to 3 minutes: a fresh revision and the load balancer need a moment.
set -euo pipefail
base="${1:?usage: smoke.sh <https://api.example>}"
deadline=$(( $(date +%s) + 180 ))

status() { curl -sS -o /dev/null -m 10 -w '%{http_code}' "$@" 2>/dev/null || echo 000; }

wait_for() { # description expected-regex method path
  local code
  while :; do
    code="$(status -X "$3" "$base$4")"
    if [[ "$code" =~ $2 ]]; then echo "ok   $1 ($code)"; return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then echo "FAIL $1: got $code, wanted $2" >&2; return 1; fi
    sleep 5
  done
}

wait_for "GET /health/live" '^200$' GET /health/live
wait_for "GET /health/ready" '^200$' GET /health/ready
wait_for "GET /v1/version" '^[1-4][0-9][0-9]$' GET /v1/version
wait_for "POST /internal/probe (no token)" '^401$' POST /internal/probe
echo "smoke tests passed"
