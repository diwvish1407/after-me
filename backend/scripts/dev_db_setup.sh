#!/usr/bin/env bash
# Create (or update) the AfterMe database roles and the local databases.
#
# Idempotent: safe to run any number of times. Run it as a PostgreSQL superuser, for example the
# Homebrew install's default OS user, or in CI with PGHOST/PGUSER/PGPASSWORD pointing at the
# service container's superuser.
#
# Role passwords come from the environment. The defaults are for LOCAL DEVELOPMENT ONLY and are
# not secrets; staging and production roles are provisioned by infrastructure code with
# generated passwords from the secret manager.
#
#   AFTERME_OWNER_DB_PASSWORD   (default: afterme_owner_dev)
#   AFTERME_API_DB_PASSWORD     (default: afterme_api_dev)
#   AFTERME_WORKER_DB_PASSWORD  (default: afterme_worker_dev)
#   AFTERME_DEV_DB_NAME         (default: afterme_dev)
#   AFTERME_TEST_DB_NAME        (default: afterme_test)
#   PG* variables               (standard libpq connection settings for the superuser)
#
# Nothing is written to disk.

set -euo pipefail

OWNER_PW="${AFTERME_OWNER_DB_PASSWORD:-afterme_owner_dev}"
API_PW="${AFTERME_API_DB_PASSWORD:-afterme_api_dev}"
WORKER_PW="${AFTERME_WORKER_DB_PASSWORD:-afterme_worker_dev}"
DEV_DB="${AFTERME_DEV_DB_NAME:-afterme_dev}"
TEST_DB="${AFTERME_TEST_DB_NAME:-afterme_test}"
ADMIN_DB="${PGDATABASE:-postgres}"

for name in "$DEV_DB" "$TEST_DB"; do
  if [[ ! "$name" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
    echo "error: invalid database name '$name' (lowercase letters, digits and _ only)" >&2
    exit 2
  fi
done

# This script creates roles with development passwords and drops nothing but creates databases:
# never run it against a shared server. An exported PGHOST of a staging or production server
# (provisioning uses provision_roles.sql) is refused unless the caller says it really is a
# throwaway one (CI service containers use localhost).
case "${PGHOST:-}" in
  ""|localhost|127.0.0.1|::1|/*) ;;
  *)
    if [[ "${AFTERME_ALLOW_REMOTE_DEV_DB_SETUP:-}" != "yes" ]]; then
      echo "error: PGHOST=$PGHOST is not this machine. This script sets development role" >&2
      echo "       passwords; for a shared server use scripts/provision_roles.sql. To really" >&2
      echo "       run it against a throwaway server set AFTERME_ALLOW_REMOTE_DEV_DB_SETUP=yes." >&2
      exit 2
    fi
    ;;
esac

psql_admin() {
  psql -X -q -v ON_ERROR_STOP=1 -d "$1" "${@:2}"
}

echo "==> Roles"
psql_admin "$ADMIN_DB" \
  -v owner_pw="$OWNER_PW" -v api_pw="$API_PW" -v worker_pw="$WORKER_PW" <<'SQL'
SELECT 'CREATE ROLE afterme_owner' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_owner')
\gexec
SELECT 'CREATE ROLE afterme_api' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_api')
\gexec
SELECT 'CREATE ROLE afterme_worker' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_worker')
\gexec
SELECT 'CREATE ROLE afterme_maintenance' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_maintenance')
\gexec
SELECT 'CREATE ROLE afterme_readonly' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'afterme_readonly')
\gexec

-- Migration role: owns the schema objects; may create the test databases.
ALTER ROLE afterme_owner WITH LOGIN CREATEDB NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD :'owner_pw';
-- Runtime roles: no DDL, privileges come only from the GRANTs in the migrations.
ALTER ROLE afterme_api WITH LOGIN NOCREATEDB NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD :'api_pw';
ALTER ROLE afterme_worker WITH LOGIN NOCREATEDB NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD :'worker_pw';
-- Group roles (granted to people or jobs later); they cannot log in themselves.
ALTER ROLE afterme_maintenance WITH NOLOGIN NOCREATEDB NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE afterme_readonly WITH NOLOGIN NOCREATEDB NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS;
-- Tests run the retention job's SQL as the real afterme_maintenance role (SET ROLE) so that its
-- column grants are exercised, not only inspected. Development and CI only: the owner role is
-- the migration job in staging and production, and is never made a member there.
GRANT afterme_maintenance TO afterme_owner;
SQL

for db in "$DEV_DB" "$TEST_DB"; do
  echo "==> Database $db"
  psql_admin "$ADMIN_DB" -v db="$db" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER afterme_owner ENCODING ''UTF8''', :'db')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db')
\gexec
SELECT format('ALTER DATABASE %I OWNER TO afterme_owner', :'db')
\gexec
-- No temporary tables for anyone by default (PostgreSQL grants TEMP to PUBLIC).
SELECT format('REVOKE TEMPORARY ON DATABASE %I FROM PUBLIC', :'db')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO afterme_api, afterme_worker', :'db')
\gexec
SQL

  # PostgreSQL 14 gives PUBLIC the CREATE privilege on schema "public" and makes the bootstrap
  # superuser its owner. PostgreSQL 15+ already removed that privilege. Make both behave the same:
  # the schema belongs to the migration role and nobody else can create objects in it.
  psql_admin "$db" <<'SQL'
ALTER SCHEMA public OWNER TO afterme_owner;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO afterme_api, afterme_worker, afterme_maintenance, afterme_readonly;
SQL
done

echo "==> Done. Roles: afterme_owner, afterme_api, afterme_worker (login);"
echo "    afterme_maintenance, afterme_readonly (no login). Databases: $DEV_DB, $TEST_DB."
