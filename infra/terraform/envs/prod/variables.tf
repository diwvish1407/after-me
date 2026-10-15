variable "project_id" {
  description = "Google Cloud project id."
  type        = string
}

variable "api_domain" {
  description = "API hostname."
  type        = string
}

variable "public_domain" {
  description = "Public pages hostname."
  type        = string
}

variable "github_repository" {
  description = "owner/name of the GitHub repository (exact case)."
  type        = string
}

variable "oncall_emails" {
  description = "Two people's e-mail addresses (pages and notifications)."
  type        = list(string)
}

variable "oncall_phone_numbers" {
  description = "E.164 numbers for SMS pages."
  type        = list(string)
}

variable "oncall_principals" {
  description = "IAM members who run the on-call jobs, e.g. user:a@x.com."
  type        = list(string)
}

variable "jwt_active_kid" {
  description = "Key id inside the jwt-signing-keys secret."
  type        = string
}

variable "email_from" {
  description = "Sender address on the verified sending domain."
  type        = string
}

variable "support_email" {
  description = "Support address shown to users."
  type        = string
}

variable "abuse_email" {
  description = "Abuse address."
  type        = string
}

variable "region" {
  description = "Region."
  type        = string
  default     = "asia-south1"
}

variable "zone" {
  description = "Zone of the admin VM."
  type        = string
  default     = "asia-south1-b"
}

variable "zone_name" {
  description = "Cloudflare zone."
  type        = string
  default     = "afterme.app"
}

variable "github_repository_id" {
  description = "Numeric repository id (gh api repos/OWNER/NAME --jq .id). Required: the Workload Identity provider binds to it."
  type        = string
}

variable "deploy_services" {
  description = "false = foundations only; true = also Cloud Run, the load balancer and monitoring."
  type        = bool
  default     = false
}

variable "image" {
  description = "Image digest reference for the first Cloud Run creation."
  type        = string
  default     = ""
}

variable "admin_vm_enabled" {
  description = "Create the administration VM (only while provisioning)."
  type        = bool
  default     = false
}

variable "admin_vm_members" {
  description = "Who may SSH to the admin VM through IAP."
  type        = list(string)
  default     = []
}

variable "db_tier" {
  description = "Cloud SQL machine type."
  type        = string
  default     = "db-custom-2-7680"
}

variable "db_high_availability" {
  description = "Regional HA."
  type        = bool
  default     = true
}

variable "db_disk_size_gb" {
  description = "Initial disk size."
  type        = number
  default     = 20
}

variable "db_max_connections" {
  description = "PostgreSQL max_connections."
  type        = number
  default     = 200
}

variable "db_deletion_protection" {
  description = "Cloud SQL deletion protection."
  type        = bool
  default     = true
}

variable "db_backup_location" {
  description = "Backup storage location."
  type        = string
  default     = "asia-south1"
}

variable "api_min_instances" {
  description = "Minimum API instances."
  type        = number
  default     = 1
}

variable "api_max_instances" {
  description = "Maximum API instances (keep x 8 <= 60 database connections)."
  type        = number
  default     = 7
}

variable "api_cpu_always_allocated" {
  description = "CPU always allocated for the API (needed for background mail tasks)."
  type        = bool
  default     = true
}

variable "worker_instances" {
  description = "Worker pool instances."
  type        = number
  default     = 2
}

variable "enable_cloud_armor" {
  description = "Cloud Armor per-IP ceiling."
  type        = bool
  default     = false
}

variable "run_deletion_protection" {
  description = "Cloud Run deletion protection."
  type        = bool
  default     = true
}

variable "trusted_proxy_hops" {
  description = "X-Forwarded-For entries appended by the load balancer path."
  type        = number
  default     = 2
}

variable "jwt_issuer" {
  description = "JWT issuer."
  type        = string
  default     = "afterme-prod"
}

variable "jwt_audience" {
  description = "JWT audience."
  type        = string
  default     = "afterme-app"
}

variable "email_provider" {
  description = "Primary e-mail provider."
  type        = string
  default     = "resend"
}

variable "email_fallback_provider" {
  description = "Fallback e-mail provider."
  type        = string
  default     = "postmark"
}

variable "postmark_message_stream" {
  description = "Postmark message stream."
  type        = string
  default     = "outbound"
}

variable "min_client_version" {
  description = "Oldest app version accepted."
  type        = string
  default     = "0.0.0"
}

variable "log_level" {
  description = "Log level."
  type        = string
  default     = "INFO"
}

variable "audit_retention_days" {
  description = "Audit log retention (days)."
  type        = number
  default     = 365
}

variable "account_deletion_days" {
  description = "Days before a closed account is hard-deleted."
  type        = number
  default     = 30
}

variable "legal_documents_final" {
  description = "Counsel has approved the legal texts."
  type        = bool
  default     = false
}

variable "extra_env" {
  description = "More non-secret AFTERME_* variables (the LEGAL_* set)."
  type        = map(string)
  default     = {}
}

variable "hmac_pepper_previous_enabled" {
  description = "Mount the previous pepper (rotation only)."
  type        = bool
  default     = false
}

variable "reviewer_account_job" {
  description = "Create the afterme-reviewer-account job (docs/RELEASE.md). Add a version to the reviewer-password secret first."
  type        = bool
  default     = false
}
