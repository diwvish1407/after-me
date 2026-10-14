# Identities. One service account per process, each with the least it needs; the grants that
# belong to a resource (a secret, the KMS key, a Cloud Run job) are made next to that resource, so
# this module holds only what is project-wide: the accounts, the CI custom role, and Workload
# Identity Federation for GitHub Actions. No service-account key is created anywhere.

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  accounts = {
    api         = "The API (Cloud Run service). Secrets, and the one KMS key. Nothing else."
    worker      = "The escalation worker (Cloud Run worker pool). Secrets and FCM sending. No KMS."
    maintenance = "The retention job (Cloud Run job). Secrets only."
    migrate     = "The migration job (afterme_owner). Its one secret only."
    admin       = "Operator CLI jobs (status, Hold, void). Worker-role secrets and FCM sending."
    scheduler   = "Cloud Scheduler: starts the scheduled Cloud Run jobs. Nothing else."
    backupcheck = "Backup freshness job: reads Cloud SQL backup metadata. Nothing else."
    cicd        = "GitHub Actions through Workload Identity Federation: build, migrate, deploy."
  }
}

resource "google_service_account" "this" {
  for_each = local.accounts

  project      = var.project_id
  account_id   = "${var.name_prefix}-${each.key}"
  display_name = "AfterMe ${each.key}"
  description  = each.value
}

# --- the worker (and the operator CLI) send push through FCM with their own identity ----------
# (PUSH_PROVIDER=fcm without FCM_CREDENTIALS_JSON uses the metadata server; DEPLOYMENT §4.)
resource "google_project_iam_member" "fcm_sender" {
  for_each = toset(["worker", "admin"])

  project = var.fcm_project_id
  role    = "roles/firebasecloudmessaging.admin"
  member  = "serviceAccount:${google_service_account.this[each.key].email}"
}

# --- CI --------------------------------------------------------------------------------------
# Deploys services, jobs and worker pools, and runs jobs. It cannot read a secret, cannot touch
# the key and cannot edit IAM DIRECTLY, and can only act as the runtime accounts listed below.
# Transitively it is as powerful as those accounts (it can deploy a revision or a job that runs
# as the api account: KMS decrypt and every secret), which is why the GitHub Environment rules
# in front of it matter (Workload Identity below, infra/README.md).
resource "google_project_iam_member" "cicd_run_developer" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.this["cicd"].email}"
}

resource "google_project_iam_member" "cicd_service_usage" {
  project = var.project_id
  role    = "roles/serviceusage.serviceUsageConsumer"
  member  = "serviceAccount:${google_service_account.this["cicd"].email}"
}

resource "google_service_account_iam_member" "cicd_acts_as" {
  for_each = toset(["api", "worker", "maintenance", "migrate", "admin"])

  service_account_id = google_service_account.this[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.this["cicd"].email}"
}

# A backup right before a production migration (DEPLOYMENT §5), and nothing else on Cloud SQL.
resource "google_project_iam_custom_role" "backup_operator" {
  project     = var.project_id
  role_id     = "aftermeBackupOperator"
  title       = "AfterMe backup operator"
  description = "Create and list on-demand Cloud SQL backups. Cannot restore, edit or delete instances."
  permissions = [
    "cloudsql.backupRuns.create",
    "cloudsql.backupRuns.get",
    "cloudsql.backupRuns.list",
    "cloudsql.instances.get",
    "cloudsql.instances.list",
    "cloudsql.operations.get",
    "cloudsql.operations.list",
  ]
}

resource "google_project_iam_custom_role" "backup_reader" {
  project     = var.project_id
  role_id     = "aftermeBackupReader"
  title       = "AfterMe backup reader"
  description = "Read backup and instance metadata of Cloud SQL (backup freshness check)."
  permissions = [
    "cloudsql.backupRuns.get",
    "cloudsql.backupRuns.list",
    "cloudsql.instances.get",
    "cloudsql.instances.list",
  ]
}

resource "google_project_iam_member" "backupcheck" {
  project = var.project_id
  role    = google_project_iam_custom_role.backup_reader.id
  member  = "serviceAccount:${google_service_account.this["backupcheck"].email}"
}

resource "google_project_iam_member" "cicd_backup" {
  project = var.project_id
  role    = google_project_iam_custom_role.backup_operator.id
  member  = "serviceAccount:${google_service_account.this["cicd"].email}"
}

# --- Workload Identity Federation for GitHub Actions ----------------------------------------
# The provider accepts a token only if it was issued to THIS repository (by name, and by numeric
# id when given: a deleted-and-recreated name does not inherit access) and to the deploy workflow
# running from an allowed ref. The same condition is the only way into the CI service account.
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  description               = "Keyless access for ${var.github_repository} (deploy workflow only)."
}

locals {
  workflow_file = "${var.github_repository}/.github/workflows/deploy.yml"

  # The environment's allowed refs. prod: the main branch only. staging: main, and release tags v*.
  #
  # The ref alone is NOT a gate for tags: GitHub's OIDC token cannot prove that a tag points at a
  # commit on main, and the workflow's own "reachable from main" check runs from the tagged
  # commit's copy of deploy.yml, which whoever pushed the tag controls (review INF-2). The gate is
  # the GitHub Environment: a token is accepted only from a job that runs in THIS project's
  # environment (`staging` / `production`), and GitHub starts such a job only if the environment's
  # deployment branch and tag rules allow the ref (staging: `main` and `v*` tags; production: `main`
  # plus required reviewers), with `v*` tag creation restricted by a ruleset. Those repository
  # settings are part of this boundary; infra/README.md lists them. Treat the CI service account as
  # equivalent to the api service account (it can deploy a revision that runs as it).
  ref_condition = var.allow_release_tags ? "(assertion.ref == 'refs/heads/main' || assertion.ref.startsWith('refs/tags/v'))" : "assertion.ref == 'refs/heads/main'"

  environment_condition = "assertion.environment == '${var.github_environment}'"

  repository_id_condition = "assertion.repository_id == '${var.github_repository_id}'"

  attribute_condition = join(" && ", [
    "assertion.repository == '${var.github_repository}'",
    local.repository_id_condition,
    local.ref_condition,
    local.environment_condition,
    "assertion.job_workflow_ref.startsWith('${local.workflow_file}@')",
  ])
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-actions"
  display_name                       = "GitHub Actions OIDC"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_id"    = "assertion.repository_id"
    "attribute.ref"              = "assertion.ref"
    "attribute.environment"      = "assertion.environment"
    "attribute.job_workflow_ref" = "assertion.job_workflow_ref"
  }

  attribute_condition = local.attribute_condition

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "cicd_wif" {
  service_account_id = google_service_account.this["cicd"].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
