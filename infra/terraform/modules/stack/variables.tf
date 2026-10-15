variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "zone" {
  description = "Zone of the admin VM."
  type        = string
  default     = "asia-south1-b"
}

variable "env" {
  description = "staging or prod."
  type        = string

  validation {
    condition     = contains(["staging", "prod"], var.env)
    error_message = "env must be staging or prod."
  }
}

# ---- domains ----------------------------------------------------------------------------------
variable "api_domain" {
  type = string
}

variable "public_domain" {
  type = string
}

variable "zone_name" {
  description = "The Cloudflare zone (afterme.app); gets the CAA iodef record."
  type        = string
  default     = "afterme.app"
}

# ---- GitHub / CI --------------------------------------------------------------------------------
variable "github_repository" {
  type = string
}

variable "github_repository_id" {
  type = string
}

variable "github_environment" {
  type = string
}

variable "allow_release_tags" {
  type = bool
}

# ---- people -------------------------------------------------------------------------------------
variable "oncall_emails" {
  type = list(string)
}

variable "oncall_phone_numbers" {
  type = list(string)
}

variable "oncall_principals" {
  description = "IAM members who run the on-call jobs: [\"user:a@x.com\", \"group:oncall@x.com\"]."
  type        = list(string)
}

variable "admin_vm_enabled" {
  type    = bool
  default = false
}

variable "admin_vm_members" {
  type    = list(string)
  default = []
}

# ---- staged apply ---------------------------------------------------------------------------------
variable "deploy_services" {
  description = "false: foundations only (network, database, KMS, secret shells, IAM, registry). true: also Cloud Run, the load balancer and monitoring; needs every secret populated and an image."
  type        = bool
  default     = false
}

variable "image" {
  description = "Image digest reference to create Cloud Run with: <region>-docker.pkg.dev/<project>/afterme/backend@sha256:..."
  type        = string
  default     = ""
}

# ---- sizing ---------------------------------------------------------------------------------------
variable "db_tier" {
  type = string
}

variable "db_high_availability" {
  type = bool
}

variable "db_disk_size_gb" {
  type    = number
  default = 20
}

variable "db_max_connections" {
  type = number
}

variable "db_deletion_protection" {
  type    = bool
  default = true
}

variable "db_backup_location" {
  type    = string
  default = "asia-south1"
}

variable "api_min_instances" {
  type = number
}

variable "api_max_instances" {
  type = number
}

variable "api_cpu_always_allocated" {
  type    = bool
  default = true
}

variable "worker_instances" {
  type = number
}

variable "enable_cloud_armor" {
  type    = bool
  default = false
}

variable "run_deletion_protection" {
  type    = bool
  default = true
}

# ---- application settings (AFTERME_*, non-secret) -----------------------------------------------------
variable "trusted_proxy_hops" {
  description = "Entries the load balancer path appends to X-Forwarded-For (docs/INFRASTRUCTURE.md section 7). Behind this stack's global external load balancer: 2."
  type        = number
  default     = 2
}

variable "jwt_issuer" {
  type = string
}

variable "jwt_audience" {
  type    = string
  default = "afterme-app"
}

variable "jwt_active_kid" {
  description = "Must be one of the kids inside the jwt-signing-keys secret."
  type        = string
}

variable "email_provider" {
  type    = string
  default = "resend"
}

variable "email_fallback_provider" {
  type    = string
  default = "postmark"
}

variable "email_from" {
  type = string
}

variable "postmark_message_stream" {
  type    = string
  default = "outbound"
}

variable "min_client_version" {
  type    = string
  default = "0.0.0"
}

variable "log_level" {
  type    = string
  default = "INFO"
}

variable "support_email" {
  type = string
}

variable "abuse_email" {
  type = string
}

variable "audit_retention_days" {
  type    = number
  default = 365
}

variable "account_deletion_days" {
  type    = number
  default = 30
}

variable "legal_documents_final" {
  description = "AFTERME_LEGAL_DOCUMENTS_FINAL: true only once counsel has approved the texts."
  type        = bool
  default     = false
}

variable "extra_env" {
  description = "More non-secret AFTERME_* variables (the LEGAL_* set, engine tuning). Keys are full names, e.g. AFTERME_LEGAL_ENTITY_NAME."
  type        = map(string)
  default     = {}
}

variable "hmac_pepper_previous_enabled" {
  type    = bool
  default = false
}

variable "reviewer_account_job" {
  description = "Create the afterme-reviewer-account job (Play reviewer demo account). Fill the reviewer-password secret first."
  type        = bool
  default     = false
}
