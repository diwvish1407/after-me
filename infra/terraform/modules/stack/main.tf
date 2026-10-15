# One environment, end to end. envs/staging and envs/prod call this module with different values;
# nothing else differs between them.

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

locals {
  labels = {
    app = "afterme"
    env = var.env
  }
  app_env       = var.env # AFTERME_APP_ENV: staging or prod
  instance_name = "afterme-pg-${var.env}"

  # CONNECTION LIMIT of each role: the same numbers as backend/scripts/provision_roles.sql
  # (change both together). The run module checks its pools against them.
  role_connection_limits = {
    api         = 60
    worker      = 48
    maintenance = 5
    owner       = 5
  }
  # superuser_reserved_connections (3) + Cloud SQL's own cloudsqladmin + the `postgres`
  # administrator's sessions (provisioning, a psql from the admin VM)
  reserved_connections = 10

  # Non-secret environment of every process (Settings: backend/app/core/config.py; DEPLOYMENT §4).
  common_env = merge(
    {
      AFTERME_APP_ENV                 = local.app_env
      AFTERME_LOG_LEVEL               = var.log_level
      AFTERME_PUBLIC_BASE_URL         = "https://${var.public_domain}"
      AFTERME_API_BASE_URL            = "https://${var.api_domain}"
      AFTERME_TRUSTED_PROXY_HOPS      = tostring(var.trusted_proxy_hops)
      AFTERME_JWT_ISSUER              = var.jwt_issuer
      AFTERME_JWT_AUDIENCE            = var.jwt_audience
      AFTERME_JWT_ACTIVE_KID          = var.jwt_active_kid
      AFTERME_EMAIL_PROVIDER          = var.email_provider
      AFTERME_EMAIL_FALLBACK_PROVIDER = var.email_fallback_provider
      AFTERME_EMAIL_FROM              = var.email_from
      AFTERME_POSTMARK_MESSAGE_STREAM = var.postmark_message_stream
      AFTERME_PUSH_PROVIDER           = "fcm"
      AFTERME_FCM_PROJECT_ID          = var.project_id
      AFTERME_KMS_PROVIDER            = "gcp_kms"
      AFTERME_KMS_KEY_NAME            = module.kms.key_name
      AFTERME_MIN_CLIENT_VERSION      = var.min_client_version
      AFTERME_SUPPORT_EMAIL           = var.support_email
      AFTERME_ABUSE_EMAIL             = var.abuse_email
      AFTERME_AUDIT_RETENTION_DAYS    = tostring(var.audit_retention_days)
      AFTERME_ACCOUNT_DELETION_DAYS   = tostring(var.account_deletion_days)
      AFTERME_LEGAL_DOCUMENTS_FINAL   = var.legal_documents_final ? "true" : "false"
    },
    var.extra_env,
  )
}


# What the pools can ask for at peak (the run module's own count, each also capped by its role's
# CONNECTION LIMIT there), plus retention (2), the migration job / owner (5) and what Cloud SQL
# and the administrator use, must stay under the connection alert (80% of max_connections): the
# database then never refuses everyone, and the alert means something unexpected.
locals {
  peak_by_role = var.deploy_services ? module.run[0].connections_peak : { api = 0, worker = 0 }
  peak_total   = local.peak_by_role["api"] + local.peak_by_role["worker"] + 2 + local.role_connection_limits["owner"] + local.reserved_connections
}

resource "terraform_data" "database_connection_budget" {
  input = {
    peak            = local.peak_total
    max_connections = var.db_max_connections
  }

  lifecycle {
    precondition {
      condition     = local.peak_total <= floor(var.db_max_connections * 0.8)
      error_message = "API + worker pools at their maximum instance counts, plus retention, migrations and reserved connections, exceed 80% of db_max_connections: raise db_max_connections or lower the instance counts."
    }
  }
}

module "iam" {
  source = "../iam"

  project_id           = var.project_id
  fcm_project_id       = var.project_id
  github_repository    = var.github_repository
  github_repository_id = var.github_repository_id
  github_environment   = var.github_environment
  allow_release_tags   = var.allow_release_tags
}

module "network" {
  source = "../network"

  project_id = var.project_id
  region     = var.region
}

module "database" {
  source = "../database"

  project_id                  = var.project_id
  region                      = var.region
  instance_name               = local.instance_name
  network_id                  = module.network.network_id
  private_services_connection = module.network.private_services_connection
  tier                        = var.db_tier
  high_availability           = var.db_high_availability
  disk_size_gb                = var.db_disk_size_gb
  max_connections             = var.db_max_connections
  deletion_protection         = var.db_deletion_protection
  backup_location             = var.db_backup_location
  labels                      = local.labels
}

module "kms" {
  source = "../kms"

  project_id                = var.project_id
  region                    = var.region
  api_service_account_email = module.iam.emails["api"]
  labels                    = local.labels
}

module "admin_vm" {
  source = "../admin_vm"

  enabled       = var.admin_vm_enabled
  project_id    = var.project_id
  region        = var.region
  zone          = var.zone
  network_id    = module.network.network_id
  network_name  = module.network.network_name
  subnet_id     = module.network.run_subnet_id
  admin_members = var.admin_vm_members
}

module "secrets" {
  source = "../secrets"

  project_id                         = var.project_id
  region                             = var.region
  service_account_emails             = module.iam.emails
  db_bootstrap_enabled               = var.admin_vm_enabled
  db_bootstrap_service_account_email = module.admin_vm.service_account_email
  labels                             = local.labels
}

module "registry" {
  source = "../registry"

  project_id               = var.project_id
  region                   = var.region
  ci_service_account_email = module.iam.cicd_service_account
  labels                   = local.labels
}

module "run" {
  source = "../run"
  count  = var.deploy_services ? 1 : 0

  project_id                   = var.project_id
  region                       = var.region
  image                        = var.image
  service_account_emails       = module.iam.emails
  network_name                 = module.network.network_name
  subnet_name                  = module.network.run_subnet_name
  common_env                   = local.common_env
  hmac_pepper_previous_enabled = var.hmac_pepper_previous_enabled
  api_min_instances            = var.api_min_instances
  api_max_instances            = var.api_max_instances
  api_cpu_always_allocated     = var.api_cpu_always_allocated
  worker_instances             = var.worker_instances
  role_connection_limits       = local.role_connection_limits
  oncall_principals            = var.oncall_principals
  reviewer_account_job         = var.reviewer_account_job
  deletion_protection          = var.run_deletion_protection
  labels                       = local.labels

  depends_on = [module.secrets, module.kms]
}

module "edge" {
  source = "../edge"
  count  = var.deploy_services ? 1 : 0

  project_id         = var.project_id
  region             = var.region
  api_service_name   = module.run[0].api_service_name
  api_domain         = var.api_domain
  public_domain      = var.public_domain
  enable_cloud_armor = var.enable_cloud_armor
}

module "monitoring" {
  source = "../monitoring"
  count  = var.deploy_services ? 1 : 0

  project_id                         = var.project_id
  region                             = var.region
  env                                = var.env
  api_domain                         = var.api_domain
  api_service_name                   = module.run[0].api_service_name
  status_check_job_name              = "afterme-status-check"
  maintenance_job_name               = module.run[0].maintenance_job_name
  database_id                        = module.database.database_id
  database_instance_name             = module.database.instance_name
  database_max_connections           = module.database.max_connections
  backup_check_service_account_email = module.iam.emails["backupcheck"]
  scheduler_service_account_email    = module.iam.emails["scheduler"]
  network_name                       = module.network.network_name
  subnet_name                        = module.network.run_subnet_name
  oncall_emails                      = var.oncall_emails
  oncall_phone_numbers               = var.oncall_phone_numbers
  labels                             = local.labels
}

module "dns_records" {
  source = "../dns_records"
  count  = var.deploy_services ? 1 : 0

  load_balancer_ip = module.edge[0].ip_address
  domains          = module.edge[0].domains
  caa_apex_domains = [var.zone_name]
}
