# staging: the whole environment is the `stack` module; this file only wires the variables.

provider "google" {
  project = var.project_id
  region  = var.region
}

module "stack" {
  source = "../../modules/stack"

  env                = "staging"
  github_environment = "staging"
  allow_release_tags = true

  project_id                   = var.project_id
  api_domain                   = var.api_domain
  public_domain                = var.public_domain
  github_repository            = var.github_repository
  oncall_emails                = var.oncall_emails
  oncall_phone_numbers         = var.oncall_phone_numbers
  oncall_principals            = var.oncall_principals
  jwt_active_kid               = var.jwt_active_kid
  email_from                   = var.email_from
  support_email                = var.support_email
  abuse_email                  = var.abuse_email
  region                       = var.region
  zone                         = var.zone
  zone_name                    = var.zone_name
  github_repository_id         = var.github_repository_id
  deploy_services              = var.deploy_services
  image                        = var.image
  admin_vm_enabled             = var.admin_vm_enabled
  admin_vm_members             = var.admin_vm_members
  db_tier                      = var.db_tier
  db_high_availability         = var.db_high_availability
  db_disk_size_gb              = var.db_disk_size_gb
  db_max_connections           = var.db_max_connections
  db_deletion_protection       = var.db_deletion_protection
  db_backup_location           = var.db_backup_location
  api_min_instances            = var.api_min_instances
  api_max_instances            = var.api_max_instances
  api_cpu_always_allocated     = var.api_cpu_always_allocated
  worker_instances             = var.worker_instances
  enable_cloud_armor           = var.enable_cloud_armor
  run_deletion_protection      = var.run_deletion_protection
  trusted_proxy_hops           = var.trusted_proxy_hops
  jwt_issuer                   = var.jwt_issuer
  jwt_audience                 = var.jwt_audience
  email_provider               = var.email_provider
  email_fallback_provider      = var.email_fallback_provider
  postmark_message_stream      = var.postmark_message_stream
  min_client_version           = var.min_client_version
  log_level                    = var.log_level
  audit_retention_days         = var.audit_retention_days
  account_deletion_days        = var.account_deletion_days
  legal_documents_final        = var.legal_documents_final
  extra_env                    = var.extra_env
  hmac_pepper_previous_enabled = var.hmac_pepper_previous_enabled
}
