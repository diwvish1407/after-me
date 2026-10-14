#!/usr/bin/env bash
# A steady trickle of database-touching requests for the OPS-04 game day. STAGING ONLY.
#   infra/scripts/load_ready.sh https://api.staging.afterme.app 600     # for 600 seconds
# GET /health/ready runs a query on the database, needs no account and writes nothing. It prints a
# line a second: "<time> ok=N 503=N other=N" so a failover shows as a run of 503s and a recovery.
set -euo pipefail
base="${1:?usage: load_ready.sh <https://api.staging...> [seconds]}"
seconds="${2:-300}"
case "$base" in *staging*) ;; *) echo "refusing: this is for staging" >&2; exit 2 ;; esac
end=$(( $(date +%s) + seconds ))
while [ "$(date +%s)" -lt "$end" ]; do
  ok=0; bad=0; other=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    code="$(curl -sS -o /dev/null -m 5 -w '%{http_code}' "$base/health/ready" 2>/dev/null || echo 000)"
    case "$code" in 200) ok=$((ok+1));; 503) bad=$((bad+1));; *) other=$((other+1));; esac
  done
  echo "$(date -u +%H:%M:%S) ok=$ok 503=$bad other=$other"
done
