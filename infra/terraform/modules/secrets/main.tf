# Secret Manager: EMPTY shells plus access bindings. A value is never given to Terraform: not as a
# variable, not as a resource attribute, not through a data source (all of those end up in the
# state file). Values are added out of band with `gcloud secrets versions add` (infra/README.md §4,
# infra/scripts/db_bootstrap.sh). That is also why this module creates no `secret_version`.
#
# Every name below is a variable that docs/DEPLOYMENT.md §4 marks (S), or a database URL. Which
# process reads which secret is decided here and nowhere else: a process cannot start with a
# secret it was not given (Cloud Run fails the revision), and cannot read one it was not bound to.
#
# NOTE ON THE LISTS: `Settings` (backend/app/core/config.py) is one class that every process loads
# and validates. So the worker, the maintenance job and the operator jobs must hold the same
# JWT keys, pepper, probe token and webhook secrets as the API, although they never use some of
# them: the process refuses to start without them. Splitting `Settings` per process would let
# these bindings shrink (listed in docs/INFRASTRUCTURE.md as a recommendation).

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

locals {
  sa = var.service_account_emails

  # secret id -> (description, the service accounts that may read it, by key of
  # service_account_emails). settings_readers = every process that loads Settings.
  settings_readers = ["api", "worker", "maintenance", "admin"]

  inventory = {
    "database-url" = {
      description = "AFTERME_DATABASE_URL: postgresql+psycopg://afterme_api:...@<private ip>:5432/<db>?sslmode=require"
      readers     = ["api"]
    }
    "worker-database-url" = {
      description = "AFTERME_WORKER_DATABASE_URL: role afterme_worker (engine, dispatcher, operator CLI)"
      readers     = ["worker", "admin"]
    }
    "maintenance-database-url" = {
      description = "AFTERME_MAINTENANCE_DATABASE_URL: role afterme_maintenance (retention job)"
      readers     = ["maintenance"]
    }
    "migration-database-url" = {
      description = "AFTERME_MIGRATION_DATABASE_URL: role afterme_owner (the migration job only)"
      readers     = ["migrate"]
    }
    "jwt-signing-keys" = {
      description = "AFTERME_JWT_SIGNING_KEYS: JSON {kid: Ed25519 PEM} (backend/scripts/generate_jwt_key.py)"
      readers     = local.settings_readers
    }
    "hmac-pepper" = {
      description = "AFTERME_HMAC_PEPPER: at least 32 bytes"
      readers     = local.settings_readers
    }
    "hmac-pepper-previous" = {
      description = "AFTERME_HMAC_PEPPER_PREVIOUS: only while a pepper rotation is under way (not mounted otherwise)"
      readers     = local.settings_readers
    }
    "probe-token" = {
      description = "AFTERME_PROBE_TOKEN: 32+ bytes; the uptime check sends it as X-Probe-Token"
      readers     = local.settings_readers
    }
    "email-api-key" = {
      description = "AFTERME_EMAIL_API_KEY: primary provider (Resend) API key"
      readers     = local.settings_readers
    }
    "email-webhook-secret" = {
      description = "AFTERME_EMAIL_WEBHOOK_SECRET: Resend whsec_... signing secret (or the Postmark webhook password)"
      readers     = local.settings_readers
    }
    "email-fallback-api-key" = {
      description = "AFTERME_EMAIL_FALLBACK_API_KEY: fallback provider (Postmark) server token"
      readers     = local.settings_readers
    }
    "email-fallback-webhook-secret" = {
      description = "AFTERME_EMAIL_FALLBACK_WEBHOOK_SECRET: Postmark webhook Basic-auth password (32+ characters)"
      readers     = local.settings_readers
    }
    "reviewer-password" = {
      description = "AFTERME_REVIEWER_PASSWORD: the Google Play reviewer account's password, read ONLY by the afterme-reviewer-account job (--password-env); generate it in the password manager (docs/RELEASE.md)"
      readers     = ["api"]
    }
  }

  readers = merge([
    for id, s in local.inventory : {
      for who in s.readers : "${id}/${who}" => { secret = id, who = who }
    }
  ]...)
}

resource "google_secret_manager_secret" "this" {
  for_each = local.inventory

  project   = var.project_id
  secret_id = each.key
  labels    = var.labels

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_iam_member" "reader" {
  for_each = local.readers

  project   = var.project_id
  secret_id = google_secret_manager_secret.this[each.value.secret].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.sa[each.value.who]}"
}

# Adding a version (rotation, first population) from the admin VM that runs db_bootstrap.sh.
resource "google_secret_manager_secret_iam_member" "db_bootstrap_adder" {
  for_each = var.db_bootstrap_enabled ? toset([
    "database-url", "worker-database-url", "maintenance-database-url", "migration-database-url",
  ]) : toset([])

  project   = var.project_id
  secret_id = google_secret_manager_secret.this[each.value].secret_id
  role      = "roles/secretmanager.secretVersionAdder"
  member    = "serviceAccount:${var.db_bootstrap_service_account_email}"
}
