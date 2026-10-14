-- Provision the AfterMe database roles and one database in a STAGING or PRODUCTION PostgreSQL
-- server (DATABASE §6, DEPLOYMENT §4). The local-development equivalent is dev_db_setup.sh,
-- which also creates the test databases and makes the owner a member of the maintenance role:
-- neither of those belongs anywhere but a laptop.
--
-- Run it ONCE per environment, as an administrator that may create roles and databases (on a
-- managed service: the built-in admin user), then run the migrations as afterme_owner:
--
--   psql -X -v ON_ERROR_STOP=1 -d postgres \
--        -v db=afterme_staging \
--        -v owner_pw="$OWNER_PW" -v api_pw="$API_PW" -v worker_pw="$WORKER_PW" \
--        -v maintenance_pw="$MAINTENANCE_PW" \
--        -f backend/scripts/provision_roles.sql
--
-- The four passwords come from the secret manager; generate them with a CSPRNG (32+ random
-- characters). Note that `-v name=value` is visible in the process list of the machine that runs
-- psql and that PostgreSQL logs DDL statements (`log_statement = ddl`) including the password of
-- ALTER ROLE: run this from an administration host nobody else uses, and rotate the passwords
-- afterwards if your server logs statements. Nothing is written to disk and the script is idempotent: running it again
-- re-applies the passwords and the lock-downs, which is also how you rotate a password.
--
-- What each role is for (and what the migrations grant it):
--   afterme_owner        owns the schema; used by the migration job only (never by a service)
--   afterme_api          the API process: no way to create incidents, actions or releases (INV-1)
--   afterme_worker       the escalation engine and dispatcher: cannot read instruction content
--   afterme_maintenance  the retention job (python -m workers.maintenance)
--   afterme_readonly     for an operator's investigation; NOLOGIN: grant it to a person's own role
--
-- Nothing here grants table privileges: migrations do that, and they only grant to roles that
-- exist, so run this script BEFORE `alembic upgrade head`.

\set ON_ERROR_STOP on

-- (psql's \quit cannot carry an exit code, so every refusal is an error: ON_ERROR_STOP then
-- ends the run with exit status 3 and nothing after it executes.)
\if :{?db}
\else
  DO $$ BEGIN RAISE EXCEPTION 'pass -v db=<database name>'; END $$;
\endif
\if :{?owner_pw}
\else
  DO $$ BEGIN RAISE EXCEPTION 'pass -v owner_pw=... -v api_pw=... -v worker_pw=... -v maintenance_pw=...'; END $$;
\endif
\if :{?api_pw}
\else
  DO $$ BEGIN RAISE EXCEPTION 'pass -v api_pw=...'; END $$;
\endif
\if :{?worker_pw}
\else
  DO $$ BEGIN RAISE EXCEPTION 'pass -v worker_pw=...'; END $$;
\endif
\if :{?maintenance_pw}
\else
  DO $$ BEGIN RAISE EXCEPTION 'pass -v maintenance_pw=...'; END $$;
\endif

-- Refuse the development passwords: this script must never put them on a shared server.
SELECT (:'owner_pw' ~ '_dev$' OR :'api_pw' ~ '_dev$' OR :'worker_pw' ~ '_dev$'
        OR :'maintenance_pw' ~ '_dev$') AS dev_password,
       (length(:'owner_pw') < 24 OR length(:'api_pw') < 24 OR length(:'worker_pw') < 24
        OR length(:'maintenance_pw') < 24) AS short_password \gset
\if :dev_password
  DO $$ BEGIN RAISE EXCEPTION 'a development password was given'; END $$;
\endif
\if :short_password
  DO $$ BEGIN RAISE EXCEPTION 'every password must be at least 24 characters'; END $$;
\endif

-- ---- roles ------------------------------------------------------------------------------------
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

-- A new role has no superuser, createdb, createrole, replication or bypassrls attribute, and a
-- non-superuser administrator (a managed service's) may not even restate them: they are checked
-- below instead of being set.
ALTER ROLE afterme_owner WITH LOGIN PASSWORD :'owner_pw';
ALTER ROLE afterme_api WITH LOGIN PASSWORD :'api_pw';
ALTER ROLE afterme_worker WITH LOGIN PASSWORD :'worker_pw';
ALTER ROLE afterme_maintenance WITH LOGIN PASSWORD :'maintenance_pw';
ALTER ROLE afterme_readonly WITH NOLOGIN;

DO $$
DECLARE
  bad text;
BEGIN
  SELECT string_agg(rolname, ', ') INTO bad FROM pg_roles
  WHERE rolname LIKE 'afterme\_%'
    AND (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls);
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'these roles hold powers they must not have: %', bad;
  END IF;
END
$$;

-- Connection ceilings, so that one runaway service cannot starve the others. Terraform checks
-- its pool sizes against these (infra/terraform/modules/stack: role_connection_limits, the same
-- numbers) and that they fit under Cloud SQL max_connections with margin.
-- afterme_worker: 2 worker instances x a pool of 14 (UNIT_CONCURRENCY 4 + dispatcher
-- CONCURRENCY 8 + 2; workers/engine.py refuses a smaller pool) = 28, plus the operator and
-- watchdog jobs (6 x 2) = 40, under 48. Re-run this file after changing a limit.
ALTER ROLE afterme_api CONNECTION LIMIT 60;
ALTER ROLE afterme_worker CONNECTION LIMIT 48;
ALTER ROLE afterme_maintenance CONNECTION LIMIT 5;
ALTER ROLE afterme_owner CONNECTION LIMIT 5;

-- A managed service's admin user is not a superuser and must be a member of a role in order to
-- hand it objects. Idempotent: an existing membership is fine.
DO $$
BEGIN
  IF NOT pg_has_role(current_user, 'afterme_owner', 'MEMBER') THEN
    EXECUTE format('GRANT afterme_owner TO %I', current_user);
  END IF;
END
$$;

-- ---- the database -----------------------------------------------------------------------------
SELECT format('CREATE DATABASE %I OWNER afterme_owner ENCODING ''UTF8''', :'db')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db')
\gexec

SELECT format('ALTER DATABASE %I OWNER TO afterme_owner', :'db') \gexec
-- PostgreSQL grants TEMP and CONNECT to PUBLIC by default: take both away, then give CONNECT to
-- exactly the roles that log in.
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO afterme_owner, afterme_api, afterme_worker, '
              'afterme_maintenance', :'db') \gexec

\connect :"db"

-- PostgreSQL 14 gives PUBLIC CREATE on schema public and makes the bootstrap user its owner;
-- 15+ already removed that. Make every version behave the same: the schema belongs to the
-- migration role and nobody else can create objects in it.
DO $$
DECLARE
  schema_owner name;
BEGIN
  SELECT pg_get_userbyid(nspowner) INTO schema_owner FROM pg_namespace WHERE nspname = 'public';
  IF schema_owner = 'pg_database_owner' THEN
    NULL;  -- PostgreSQL 15+: the schema already belongs to the database owner (afterme_owner)
  ELSIF pg_has_role(current_user, schema_owner, 'MEMBER') THEN
    EXECUTE 'ALTER SCHEMA public OWNER TO afterme_owner';
  ELSE
    RAISE EXCEPTION
      'schema public is owned by %: run this script as that role (PostgreSQL 14), or use PostgreSQL 15 or later',
      schema_owner;
  END IF;
END
$$;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO afterme_api, afterme_worker, afterme_maintenance,
  afterme_readonly;

-- Objects created later by the owner are not readable by anyone until a migration says so.
ALTER DEFAULT PRIVILEGES FOR ROLE afterme_owner IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE afterme_owner IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE afterme_owner IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM PUBLIC;

\echo 'Roles and database ready. Next: AFTERME_MIGRATION_DATABASE_URL (afterme_owner) ->'
\echo '  uv run alembic upgrade head, then start the api, worker and maintenance processes.'
