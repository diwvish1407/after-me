#!/usr/bin/env bash
# Generate the application secrets that are random and put them into Secret Manager. Run from your
# own machine, in the repository. Nothing is printed, nothing is written to disk.
#
#   infra/scripts/add_app_secrets.sh <project-id> <jwt-kid>
#
# Adds: jwt-signing-keys, hmac-pepper, probe-token, email-fallback-webhook-secret (a Postmark
# Basic-auth password). It does NOT add the provider keys: email-api-key (Resend), email-fallback-api-key
# (Postmark) and email-webhook-secret (Resend's whsec_... signing secret) come from the providers;
# paste them with:   gcloud secrets versions add <name> --project <p> --data-file=-
# Re-running adds NEW versions (a rotation): only do it for a secret you mean to rotate.
set -euo pipefail

project="${1:?usage: add_app_secrets.sh <project-id> <jwt-kid>}"
kid="${2:?the key id, e.g. k20261012 (must equal jwt_active_kid in terraform.tfvars)}"
root="$(cd "$(dirname "$0")/../.." && pwd)"

add() { gcloud secrets versions add "$1" --project "$project" --data-file=- --quiet >/dev/null; echo "added a version of $1"; }
rand() { openssl rand -base64 96 | tr -d '\n=+/' | cut -c1-"$1" | tr -d '\n'; }

keys="$(cd "$root/backend" && uv run python scripts/generate_jwt_key.py --kid "$kid" --with-pepper)"
printf '%s' "$keys" | sed -n "s/^AFTERME_JWT_SIGNING_KEYS='\(.*\)'\$/\1/p" | tr -d '\n' | add jwt-signing-keys
printf '%s' "$keys" | sed -n 's/^AFTERME_HMAC_PEPPER=//p' | tr -d '\n' | add hmac-pepper
unset keys
rand 64 | add probe-token
rand 48 | add email-fallback-webhook-secret
