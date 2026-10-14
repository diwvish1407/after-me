variable "project_id" {
  type = string
}

variable "region" {
  description = "Secrets are replicated to this one region only."
  type        = string
}

variable "service_account_emails" {
  description = "Emails of the runtime service accounts, keyed api, worker, maintenance, migrate, admin."
  type        = map(string)

  validation {
    condition     = alltrue([for k in ["api", "worker", "maintenance", "migrate", "admin"] : contains(keys(var.service_account_emails), k)])
    error_message = "service_account_emails needs the keys api, worker, maintenance, migrate and admin."
  }
}

variable "db_bootstrap_enabled" {
  description = "Let the admin VM's service account add versions to the four database URL secrets."
  type        = bool
  default     = false
}

variable "db_bootstrap_service_account_email" {
  description = "Service account of the admin VM (only used when db_bootstrap_enabled)."
  type        = string
  default     = ""
}

variable "labels" {
  type    = map(string)
  default = {}
}
