#!/usr/bin/env bash
# Create the AfterMe database roles and the database, and store the four database URLs in Secret
# Manager. Run it ON THE ADMIN VM (infra/README.md section 6): the database has no public address.
#
#   sudo apt-get ... (the VM's startup script already installed psql and openssl)
#   ./db_bootstrap.sh <project-id> <staging|prod> <database-private-ip>
#
# It asks for the password of the built-in `postgres` administrator (set it first with
# `gcloud sql users set-password postgres --instance=... --prompt-for-password`). The four role
# passwords are generated here, held in shell variables only, written to Secret Manager and handed
# to psql; nothing is written to disk, nothing is printed. Running it again rotates all four
# passwords (provision_roles.sql is idempotent), after which the services must be redeployed so
# that they read the new secret versions.
set -euo pipefail

project="${1:?usage: db_bootstrap.sh <project-id> <staging|prod> <database-private-ip>}"
env="${2:?staging or prod}"
host="${3:?private IP of the Cloud SQL instance}"
sql="${PROVISION_SQL:-$HOME/provision_roles.sql}"

case "$env" in
  staging) db="afterme_staging" ;;
  prod) db="afterme" ;;
  *) echo "env must be staging or prod" >&2; exit 2 ;;
esac
[ -r "$sql" ] || { echo "copy backend/scripts/provision_roles.sql to $sql first (gcloud compute scp --tunnel-through-iap)" >&2; exit 2; }

# URL-safe, 40 characters, no padding or symbols: no escaping is ever needed inside a URL.
gen() { openssl rand -base64 96 | tr -d '\n=+/' | cut -c1-40; }
owner_pw="$(gen)"; api_pw="$(gen)"; worker_pw="$(gen)"; maintenance_pw="$(gen)"

read -r -s -p "Password of the postgres administrator: " PGPASSWORD; echo
export PGPASSWORD PGSSLMODE=require PGCONNECT_TIMEOUT=10

# 1. roles and database. -v values are visible in `ps` on THIS VM only, which nobody else uses.
psql -X -v ON_ERROR_STOP=1 -h "$host" -U postgres -d postgres \
  -v db="$db" -v owner_pw="$owner_pw" -v api_pw="$api_pw" -v worker_pw="$worker_pw" \
  -v maintenance_pw="$maintenance_pw" -f "$sql"

# 2. the four URLs (sslmode=require is what Settings insists on)
put() { # secret-name role password
  printf 'postgresql+psycopg://%s:%s@%s:5432/%s?sslmode=require' "$2" "$3" "$host" "$db" \
    | gcloud secrets versions add "$1" --project "$project" --data-file=- --quiet >/dev/null
  echo "stored a new version of secret $1"
}
put database-url afterme_api "$api_pw"
put worker-database-url afterme_worker "$worker_pw"
put maintenance-database-url afterme_maintenance "$maintenance_pw"
put migration-database-url afterme_owner "$owner_pw"

unset PGPASSWORD owner_pw api_pw worker_pw maintenance_pw
echo "Done. Next: run the migration job (infra/README.md section 7)."
