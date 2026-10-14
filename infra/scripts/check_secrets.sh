#!/usr/bin/env bash
# Check that every secret the services mount has an ENABLED version. Reads no secret value.
#   infra/scripts/check_secrets.sh <project-id> [--with-previous-pepper]
set -euo pipefail
project="${1:?usage: check_secrets.sh <project-id>}"
names="database-url worker-database-url maintenance-database-url migration-database-url jwt-signing-keys hmac-pepper probe-token email-api-key email-webhook-secret email-fallback-api-key email-fallback-webhook-secret"
[ "${2:-}" = "--with-previous-pepper" ] && names="$names hmac-pepper-previous"
missing=0
for n in $names; do
  count="$(gcloud secrets versions list "$n" --project "$project" --filter='state=ENABLED' --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$count" -ge 1 ]; then echo "ok       $n"; else echo "MISSING  $n"; missing=1; fi
done
exit "$missing"
