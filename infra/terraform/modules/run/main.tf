# Cloud Run: the API (service), the escalation worker (worker pool), the migration job, the
# retention job (job + Scheduler), the status watchdog (job + Scheduler), the operator jobs and
# the key-management job (afterme-kms) and the Play reviewer account job. One image, five commands
# (backend/Dockerfile).
#
# Images are deployed by digest from CI (deploy.yml, `gcloud run ... --image <name>@sha256:...`),
# so Terraform ignores `image` after the first apply: it creates the resources, CI moves them.

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

locals {
  # `Settings` is one class that every process validates; in staging/prod it insists that all
  # three database URLs are set explicitly and use TLS or a loopback host. A process gets the
  # secret URL of ITS role and an unusable loopback placeholder for the other two, so that the
  # worker never holds the API's database password and vice versa (docs/INFRASTRUCTURE.md §6).
  unused_db_url = "postgresql+psycopg://unused:unused@127.0.0.1:1/unused?sslmode=require"

  # secrets every process that loads Settings needs (module secrets: settings_readers)
  settings_secrets = merge(
    {
      AFTERME_JWT_SIGNING_KEYS              = "jwt-signing-keys"
      AFTERME_HMAC_PEPPER                   = "hmac-pepper"
      AFTERME_PROBE_TOKEN                   = "probe-token"
      AFTERME_EMAIL_API_KEY                 = "email-api-key"
      AFTERME_EMAIL_WEBHOOK_SECRET          = "email-webhook-secret"
      AFTERME_EMAIL_FALLBACK_API_KEY        = "email-fallback-api-key"
      AFTERME_EMAIL_FALLBACK_WEBHOOK_SECRET = "email-fallback-webhook-secret"
    },
    var.hmac_pepper_previous_enabled ? { AFTERME_HMAC_PEPPER_PREVIOUS = "hmac-pepper-previous" } : {},
  )

  vpc = {
    network    = var.network_name
    subnetwork = var.subnet_name
  }

  process = {
    api = {
      account = var.service_account_emails["api"]
      secrets = merge(local.settings_secrets, { AFTERME_DATABASE_URL = "database-url" })
      env = {
        AFTERME_WORKER_DATABASE_URL      = local.unused_db_url
        AFTERME_MAINTENANCE_DATABASE_URL = local.unused_db_url
        AFTERME_DB_POOL_SIZE             = tostring(var.api_db_pool_size)
        AFTERME_DB_MAX_OVERFLOW          = tostring(var.api_db_max_overflow)
      }
    }
    worker = {
      account = var.service_account_emails["worker"]
      secrets = merge(local.settings_secrets, { AFTERME_WORKER_DATABASE_URL = "worker-database-url" })
      env = {
        AFTERME_DATABASE_URL             = local.unused_db_url
        AFTERME_MAINTENANCE_DATABASE_URL = local.unused_db_url
        # One connection for every unit of a tick page (UNIT_CONCURRENCY 4) AND every concurrent
        # send of a dispatcher pass (CONCURRENCY 8), plus 2 (the page reader / Hold evaluation /
        # stuck-row recovery session, and a failed unit's attempt count or a replaced stale
        # connection). Ticks and passes run one after the other today, but sized for both at
        # once nothing ever waits for a connection, in particular not a settle (tx B) after the
        # provider accepted, which would otherwise time out and be re-sent after 5 minutes
        # (docs/ESCALATION_ENGINE.md §8.3). workers/engine.py refuses to start with less.
        AFTERME_DB_POOL_SIZE    = tostring(var.worker_db_pool_size)
        AFTERME_DB_MAX_OVERFLOW = "0"
      }
    }
    maintenance = {
      account = var.service_account_emails["maintenance"]
      secrets = merge(local.settings_secrets, { AFTERME_MAINTENANCE_DATABASE_URL = "maintenance-database-url" })
      env = {
        AFTERME_DATABASE_URL        = local.unused_db_url
        AFTERME_WORKER_DATABASE_URL = local.unused_db_url
        # afterme_maintenance may hold 5 connections and Database opens two pools.
        AFTERME_DB_POOL_SIZE    = "1"
        AFTERME_DB_MAX_OVERFLOW = "0"
      }
    }
    admin = {
      account = var.service_account_emails["admin"]
      secrets = merge(local.settings_secrets, { AFTERME_WORKER_DATABASE_URL = "worker-database-url" })
      env = {
        AFTERME_DATABASE_URL             = local.unused_db_url
        AFTERME_MAINTENANCE_DATABASE_URL = local.unused_db_url
        AFTERME_DB_POOL_SIZE             = "1"
        AFTERME_DB_MAX_OVERFLOW          = "0"
      }
    }
  }

  # Same command as backend/Dockerfile's CMD. --no-proxy-headers is mandatory: the application
  # computes the client address itself from AFTERME_TRUSTED_PROXY_HOPS (docs/INFRASTRUCTURE.md §7).
  api_command = ["sh", "-c"]
  api_args    = ["exec uvicorn app.main:app --host 0.0.0.0 --port \"$${PORT:-8080}\" --no-proxy-headers --no-access-log --no-server-header"]

  # Operator and watchdog jobs: `python -m cli.admin <args>`. The on-call jobs have their arguments
  # fixed so that a phone tap is enough; afterme-admin takes arguments at execution time.
  cli_jobs = {
    "afterme-admin" = {
      description = "Operator CLI with arguments given at execution time (incident void, action retry, ...)."
      args        = ["--operator", "oncall", "status"]
      timeout     = "300s"
      overrides   = true
    }
    "afterme-status-check" = {
      description = "Watchdog: `status` exits 1 when anything would page. Run every 2 minutes by Cloud Scheduler; a failed execution pages."
      args        = ["--operator", "watchdog", "status"]
      timeout     = "110s"
      overrides   = false
    }
    "afterme-oncall-status" = {
      description = "On-call: the engine status (exit 1 = something pages)."
      args        = ["--operator", "oncall", "status"]
      timeout     = "110s"
      overrides   = false
    }
    "afterme-oncall-hold-status" = {
      description = "On-call: is the system Hold on?"
      args        = ["--operator", "oncall", "hold", "status"]
      timeout     = "110s"
      overrides   = false
    }
    "afterme-oncall-hold-enter" = {
      description = "On-call: ENTER Hold (freezes every message to contacts). Safe: reminders to people go on."
      args        = ["--operator", "oncall", "hold", "enter", "--reason", "on-call stop-the-line (console job)"]
      timeout     = "110s"
      overrides   = false
    }
    "afterme-oncall-hold-exit" = {
      description = "On-call: EXIT the operator/anomaly Hold (deadlines are shifted). Only after the cause is understood."
      args        = ["--operator", "oncall", "hold", "exit"]
      timeout     = "110s"
      overrides   = false
    }
  }

  # on-call may run these without a developer; the generic one is the only one that takes arguments
  oncall_fixed_jobs = toset([for k, v in local.cli_jobs : k if !v.overrides && k != "afterme-status-check"])

  # Database connections each role can be asked for at peak (docs/INFRASTRUCTURE.md §6). Every
  # process opens two pools (main + bookkeeping) of pool + overflow; the worker never uses its
  # bookkeeping pool (no independent transaction in the engine or the dispatcher), so it counts
  # once. Each CLI job: 1 + 0, two pools.
  connections_peak = {
    api    = var.api_max_instances * 2 * (var.api_db_pool_size + var.api_db_max_overflow) + 2 + (var.reviewer_account_job ? 2 : 0) # + afterme-kms (+ afterme-reviewer-account)
    worker = var.worker_instances * var.worker_db_pool_size + 2 * length(local.cli_jobs)
  }
}

# Refuses a plan whose pools could ask a role for more connections than provision_roles.sql
# allows it (a refused connection is a failed unit, a 503, or a page).
resource "terraform_data" "connection_budget" {
  input = local.connections_peak

  lifecycle {
    precondition {
      condition     = local.connections_peak.api <= var.role_connection_limits["api"]
      error_message = "API pools at api_max_instances (+ the afterme-kms and afterme-reviewer-account jobs) exceed the afterme_api connection limit: lower api_max_instances or raise the limit in provision_roles.sql and role_connection_limits together."
    }
    precondition {
      condition     = local.connections_peak.worker <= var.role_connection_limits["worker"]
      error_message = "Worker pools (+ the operator jobs) exceed the afterme_worker connection limit: raise it in provision_roles.sql and role_connection_limits together."
    }
  }
}

# ---------------------------------------------------------------------------------------------
# The API
# ---------------------------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "api" {
  project  = var.project_id
  location = var.region
  name     = "${var.name_prefix}-api"

  description = "AfterMe API and web pages. Only the global load balancer may reach it."
  labels      = var.labels

  # The front door is the load balancer (module edge): a request straight to *.run.app is refused,
  # and the run.app URL is switched off. IAM invoker checks are off because the service is public
  # behind the load balancer (no `allUsers` binding is needed, which an organisation policy may forbid).
  ingress              = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  default_uri_disabled = true
  invoker_iam_disabled = true
  deletion_protection  = var.deletion_protection

  template {
    service_account                  = local.process.api.account
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"
    timeout                          = "60s"
    max_instance_request_concurrency = var.api_concurrency

    scaling {
      min_instance_count = var.api_min_instances
      max_instance_count = var.api_max_instances
    }

    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network    = local.vpc.network
        subnetwork = local.vpc.subnetwork
      }
    }

    containers {
      name    = "api"
      image   = var.image
      command = local.api_command
      args    = local.api_args

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
        # false = CPU always allocated. The API sends mail from FastAPI background tasks AFTER
        # the response (password reset, invitations): with request-based billing the CPU is
        # throttled once the response is out and that mail may wait for the next request.
        cpu_idle          = !var.api_cpu_always_allocated
        startup_cpu_boost = true
      }

      # A revision that cannot reach the database, or whose code is ahead of the schema (the
      # migration has not run), never gets traffic, so migrations run before the deploy. A
      # schema AHEAD of the revision (a rollback after a migrating release) is ready: migrations
      # are expand-only (backend/app/api/health.py, docs/DEPLOYMENT.md §5).
      startup_probe {
        http_get {
          path = "/health/ready"
        }
        initial_delay_seconds = 2
        period_seconds        = 5
        timeout_seconds       = 4
        failure_threshold     = 24
      }

      # Liveness never looks at the database: a database outage must not restart the API.
      liveness_probe {
        http_get {
          path = "/health/live"
        }
        period_seconds    = 30
        timeout_seconds   = 3
        failure_threshold = 3
      }

      dynamic "env" {
        for_each = merge(var.common_env, local.process.api.env)
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.process.api.secrets
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      template[0].revision,
      client,
      client_version,
    ]
  }
}

# ---------------------------------------------------------------------------------------------
# The escalation worker: always on, no HTTP, so a worker pool (a Cloud Run service must listen on
# a port). Two instances in production are safe because every unit of work takes the user's lock
# with SKIP LOCKED and every effect has a dedupe key.
# ---------------------------------------------------------------------------------------------
resource "google_cloud_run_v2_worker_pool" "worker" {
  project  = var.project_id
  location = var.region
  name     = "${var.name_prefix}-worker"

  description         = "Escalation engine and outbox dispatcher (python -m workers.engine)."
  labels              = var.labels
  deletion_protection = var.deletion_protection

  scaling {
    scaling_mode          = "MANUAL"
    manual_instance_count = var.worker_instances
  }

  template {
    service_account = local.process.worker.account

    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network    = local.vpc.network
        subnetwork = local.vpc.subnetwork
      }
    }

    containers {
      name    = "worker"
      image   = var.image
      command = ["python", "-m", "workers.engine"]

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      dynamic "env" {
        for_each = merge(var.common_env, local.process.worker.env)
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.process.worker.secrets
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      template[0].revision,
      client,
      client_version,
    ]
  }
}

# ---------------------------------------------------------------------------------------------
# Migrations: `alembic upgrade head` as afterme_owner, started by CI before any new code.
# ---------------------------------------------------------------------------------------------
resource "google_cloud_run_v2_job" "migrate" {
  project  = var.project_id
  location = var.region
  name     = "${var.name_prefix}-migrate"

  labels              = var.labels
  deletion_protection = var.deletion_protection

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = var.service_account_emails["migrate"]
      max_retries     = 0 # a failed migration is looked at by a person, not retried in a loop
      timeout         = "900s"

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"
        network_interfaces {
          network    = local.vpc.network
          subnetwork = local.vpc.subnetwork
        }
      }

      containers {
        name    = "migrate"
        image   = var.image
        command = ["alembic"]
        args    = ["upgrade", "head"]

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        # Alembic reads only these two (MigrationSettings); nothing else is mounted.
        env {
          name  = "AFTERME_APP_ENV"
          value = var.common_env["AFTERME_APP_ENV"]
        }
        env {
          name = "AFTERME_MIGRATION_DATABASE_URL"
          value_source {
            secret_key_ref {
              secret  = "migration-database-url"
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }
}

# ---------------------------------------------------------------------------------------------
# Retention (account deletions, data retention): a job started every 15 minutes by Cloud
# Scheduler rather than a third always-on instance. See docs/INFRASTRUCTURE.md §4 for why.
# ---------------------------------------------------------------------------------------------
resource "google_cloud_run_v2_job" "maintenance" {
  project  = var.project_id
  location = var.region
  name     = "${var.name_prefix}-maintenance"

  labels              = var.labels
  deletion_protection = var.deletion_protection

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = local.process.maintenance.account
      max_retries     = 0      # the next run is 15 minutes away; a failure is alerted, not retried
      timeout         = "600s" # shorter than the period, so two runs never overlap

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"
        network_interfaces {
          network    = local.vpc.network
          subnetwork = local.vpc.subnetwork
        }
      }

      containers {
        name    = "maintenance"
        image   = var.image
        command = ["python", "-m", "workers.maintenance"] # no --every: one pass, then exit

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        dynamic "env" {
          for_each = merge(var.common_env, local.process.maintenance.env)
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = local.process.maintenance.secrets
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = env.value
                version = "latest"
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }
}

# ---------------------------------------------------------------------------------------------
# Operator CLI jobs (python -m cli.admin ...): the watchdog and what the on-call person runs.
# ---------------------------------------------------------------------------------------------
resource "google_cloud_run_v2_job" "cli" {
  for_each = local.cli_jobs

  project  = var.project_id
  location = var.region
  name     = each.key

  labels              = var.labels
  deletion_protection = var.deletion_protection

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = local.process.admin.account
      max_retries     = 0
      timeout         = each.value.timeout

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"
        network_interfaces {
          network    = local.vpc.network
          subnetwork = local.vpc.subnetwork
        }
      }

      containers {
        name    = "cli"
        image   = var.image
        command = ["python", "-m", "cli.admin"]
        args    = each.value.args

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        dynamic "env" {
          for_each = merge(var.common_env, local.process.admin.env)
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = local.process.admin.secrets
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = env.value
                version = "latest"
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }
}

# ---------------------------------------------------------------------------------------------
# Key management (docs/DEPLOYMENT.md §9): `python -m cli.admin kms check | rewrap | rotate-user`.
# These need the API database role (the only one that may read user_keys) AND the KMS
# EncrypterDecrypter role, which only the API service account holds, so the job runs as the API
# service account with the API's database URL. The command is fixed up to `kms`: an execution
# may only choose the kms subcommand and its arguments (`--args`), so these credentials cannot
# be used for anything else. Not scheduled; executed by the on-call principals only.
# ---------------------------------------------------------------------------------------------
resource "google_cloud_run_v2_job" "kms" {
  project  = var.project_id
  location = var.region
  name     = "${var.name_prefix}-kms"

  labels              = var.labels
  deletion_protection = var.deletion_protection

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = local.process.api.account
      max_retries     = 0       # rewrap and rotate-user are re-run by a person, never in a loop
      timeout         = "3600s" # rewrap of every key is one KMS call per key, 3 s ceiling each

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"
        network_interfaces {
          network    = local.vpc.network
          subnetwork = local.vpc.subnetwork
        }
      }

      containers {
        name    = "kms"
        image   = var.image
        command = ["python", "-m", "cli.admin", "kms"]
        args    = ["check"]

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        dynamic "env" {
          # the API's environment, with a 1 + 0 pool (one user at a time): 2 connections
          for_each = merge(var.common_env, local.process.api.env, {
            AFTERME_DB_POOL_SIZE    = "1"
            AFTERME_DB_MAX_OVERFLOW = "0"
          })
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = local.process.api.secrets
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = env.value
                version = "latest"
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }
}

resource "google_cloud_run_v2_job_iam_member" "kms_operator" {
  for_each = toset(var.oncall_principals)

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.kms.name
  role     = "roles/run.jobsExecutorWithOverrides"
  member   = each.value
}

# ---------------------------------------------------------------------------------------------
# The Google Play reviewer (demo) account (docs/RELEASE.md, docs/PLAY_STORE.md §6):
# `python -m cli.admin reviewer-account create | reset`. Like afterme-kms it needs the API database
# role and the KMS (it seals two sample instructions), so it runs as the API service account with
# the API's database URL, and its command is fixed up to `reviewer-account`. Cloud Run captures
# stdout into Cloud Logging, so the command never prints a password here: the password is read
# from AFTERME_REVIEWER_PASSWORD (`--password-env AFTERME_REVIEWER_PASSWORD`), bound to the
# reviewer-password secret, which the owner fills from the password manager before executing.
# Off by default (reviewer_account_job): a job bound to a secret that has no version cannot run.
# Never scheduled; executed by the on-call principals (in practice the owner).
# ---------------------------------------------------------------------------------------------
resource "google_cloud_run_v2_job" "reviewer" {
  count = var.reviewer_account_job ? 1 : 0

  project  = var.project_id
  location = var.region
  name     = "${var.name_prefix}-reviewer-account"

  labels              = var.labels
  deletion_protection = var.deletion_protection

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = local.process.api.account
      max_retries     = 0 # a refusal is read by a person, never retried in a loop
      timeout         = "300s"

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"
        network_interfaces {
          network    = local.vpc.network
          subnetwork = local.vpc.subnetwork
        }
      }

      containers {
        name    = "reviewer-account"
        image   = var.image
        command = ["python", "-m", "cli.admin", "reviewer-account"]
        args    = ["--help"]

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        dynamic "env" {
          # the API's environment, with a 1 + 0 pool: 2 connections
          for_each = merge(var.common_env, local.process.api.env, {
            AFTERME_DB_POOL_SIZE    = "1"
            AFTERME_DB_MAX_OVERFLOW = "0"
          })
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = merge(local.process.api.secrets, { AFTERME_REVIEWER_PASSWORD = "reviewer-password" })
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = env.value
                version = "latest"
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }
}

resource "google_cloud_run_v2_job_iam_member" "reviewer_operator" {
  for_each = var.reviewer_account_job ? toset(var.oncall_principals) : toset([])

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.reviewer[0].name
  role     = "roles/run.jobsExecutorWithOverrides"
  member   = each.value
}

# ---------------------------------------------------------------------------------------------
# Scheduling
# ---------------------------------------------------------------------------------------------
locals {
  scheduled = {
    maintenance = {
      job      = google_cloud_run_v2_job.maintenance.name
      schedule = "*/15 * * * *"
    }
    status-check = {
      job      = google_cloud_run_v2_job.cli["afterme-status-check"].name
      schedule = "*/2 * * * *"
    }
  }
}

resource "google_cloud_run_v2_job_iam_member" "scheduler" {
  for_each = local.scheduled

  project  = var.project_id
  location = var.region
  name     = each.value.job
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.service_account_emails["scheduler"]}"
}

resource "google_cloud_scheduler_job" "run_job" {
  for_each = local.scheduled

  project          = var.project_id
  region           = var.region
  name             = "${var.name_prefix}-${each.key}"
  description      = "Runs the Cloud Run job ${each.value.job}."
  schedule         = each.value.schedule
  time_zone        = "Etc/UTC"
  attempt_deadline = "60s"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${each.value.job}:run"

    oauth_token {
      service_account_email = var.service_account_emails["scheduler"]
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.scheduler]
}

# ---------------------------------------------------------------------------------------------
# On-call access: fixed-argument jobs for a tap on a phone, one job with arguments for the rest.
# ---------------------------------------------------------------------------------------------
locals {
  oncall_fixed = {
    for pair in setproduct(local.oncall_fixed_jobs, var.oncall_principals) :
    "${pair[0]}|${pair[1]}" => { job = pair[0], member = pair[1] }
  }
  oncall_generic = { for p in var.oncall_principals : p => p }
}

resource "google_cloud_run_v2_job_iam_member" "oncall_fixed" {
  for_each = local.oncall_fixed

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.cli[each.value.job].name
  role     = "roles/run.invoker"
  member   = each.value.member
}

resource "google_cloud_run_v2_job_iam_member" "oncall_generic" {
  for_each = local.oncall_generic

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.cli["afterme-admin"].name
  role     = "roles/run.jobsExecutorWithOverrides"
  member   = each.value
}

# See the result of an execution: its status and its log lines.
resource "google_project_iam_member" "oncall_viewer" {
  for_each = {
    for pair in setproduct(var.oncall_principals, ["roles/run.viewer", "roles/logging.viewer", "roles/monitoring.viewer"]) :
    "${pair[0]}|${pair[1]}" => { member = pair[0], role = pair[1] }
  }

  project = var.project_id
  role    = each.value.role
  member  = each.value.member
}
