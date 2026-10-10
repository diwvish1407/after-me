#!/usr/bin/env bash
# Migration round trip (upgrade, downgrade to base, upgrade) on a THROWAWAY database.
#
# `alembic downgrade base` drops every table, so this never touches afterme_dev. The scratch
# database is created with dev_db_setup.sh (same roles and hardening as the real ones), and
# dropped again on exit. Run it as the same PostgreSQL superuser as dev_db_setup.sh.
#
#   AFTERME_OWNER_DB_PASSWORD   (default: afterme_owner_dev)
#   AFTERME_MIGRATE_CHECK_DB    (default: afterme_migrate_check)

set -euo pipefail
cd "$(dirname "$0")/.."

SCRATCH="${AFTERME_MIGRATE_CHECK_DB:-afterme_migrate_check}"
OWNER_PW="${AFTERME_OWNER_DB_PASSWORD:-afterme_owner_dev}"
HOST="${PGHOST:-localhost}"
PORT="${PGPORT:-5432}"

cleanup() {
  dropdb --if-exists --force "$SCRATCH" >/dev/null 2>&1 || true
}
trap cleanup EXIT

AFTERME_DEV_DB_NAME="$SCRATCH" ./scripts/dev_db_setup.sh >/dev/null

export AFTERME_MIGRATION_DATABASE_URL="postgresql+psycopg://afterme_owner:${OWNER_PW}@${HOST}:${PORT}/${SCRATCH}"
uv run alembic upgrade head
uv run alembic downgrade base
uv run alembic upgrade head
echo "migration round trip OK on ${SCRATCH} (dropped on exit)"
