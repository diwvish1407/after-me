#!/usr/bin/env bash
# Copy the probe token from Secret Manager into the Cloud Monitoring uptime check's X-Probe-Token
# header. Terraform creates the check with a placeholder and ignores the header afterwards, so the
# token never reaches Terraform state. Run it after the first apply and after every rotation of the
# probe-token secret.
#
#   infra/scripts/set_probe_header.sh <project-id> <uptime-check-id>
#
# <uptime-check-id> is `terraform output uptime_check_id`. You need secretAccessor on probe-token
# and monitoring.uptimeCheckConfigs.update (the project Owner has both).
set -euo pipefail
project="${1:?usage: set_probe_header.sh <project-id> <uptime-check-id>}"
check="${2:?the uptime check id}"

token="$(gcloud secrets versions access latest --secret probe-token --project "$project")"
[ "${#token}" -ge 32 ] || { echo "the probe-token secret is shorter than 32 characters" >&2; exit 1; }
access="$(gcloud auth print-access-token)"

# The body goes through stdin (-d @-) so the token is not on the command line.
body="$(printf '{"httpCheck":{"headers":{"X-Probe-Token":"%s","X-Probe-Source":"gcp-uptime"}}}' "$token")"
code="$(printf '%s' "$body" | curl -sS -o /dev/null -w '%{http_code}' -X PATCH \
  -H "Authorization: Bearer $access" -H 'Content-Type: application/json' -d @- \
  "https://monitoring.googleapis.com/v3/projects/${project}/uptimeCheckConfigs/${check}?updateMask=httpCheck.headers")"
unset token body access
if [ "$code" = "200" ]; then echo "uptime check updated"; else echo "update failed: HTTP $code" >&2; exit 1; fi
