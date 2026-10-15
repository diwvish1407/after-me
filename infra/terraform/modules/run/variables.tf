variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "name_prefix" {
  type    = string
  default = "afterme"
}

variable "image" {
  description = "Image to create the resources with: <registry>/<name>@sha256:... After the first apply CI moves them and Terraform ignores the image."
  type        = string
}

variable "service_account_emails" {
  description = "Keys api, worker, maintenance, migrate, admin, scheduler."
  type        = map(string)
}

variable "network_name" {
  type = string
}

variable "subnet_name" {
  type = string
}

variable "common_env" {
  description = "Non-secret AFTERME_* environment shared by every process (built in the stack module). Must contain AFTERME_APP_ENV."
  type        = map(string)

  validation {
    condition     = contains(keys(var.common_env), "AFTERME_APP_ENV")
    error_message = "common_env needs AFTERME_APP_ENV."
  }
}

variable "hmac_pepper_previous_enabled" {
  description = "Mount AFTERME_HMAC_PEPPER_PREVIOUS (a version of hmac-pepper-previous must exist). Only during a pepper rotation."
  type        = bool
  default     = false
}

variable "api_min_instances" {
  type = number
}

variable "api_max_instances" {
  description = "api_max_instances * 2 * (pool + overflow) + 2 (afterme-kms) + 2 (afterme-reviewer-account, when enabled) must stay at or below the afterme_api connection limit (60); checked at plan time (terraform_data.connection_budget)."
  type        = number
}

variable "api_concurrency" {
  type    = number
  default = 20
}

variable "api_db_pool_size" {
  type    = number
  default = 3
}

variable "api_db_max_overflow" {
  type    = number
  default = 1
}

variable "api_cpu_always_allocated" {
  type    = bool
  default = true
}

variable "worker_instances" {
  type = number
}

variable "worker_db_pool_size" {
  description = "Worker DB pool: at least UNIT_CONCURRENCY (4) + dispatcher CONCURRENCY (8) + 2 = 14. workers/engine.py refuses to start with less."
  type        = number
  default     = 14

  validation {
    condition     = var.worker_db_pool_size >= 14
    error_message = "worker_db_pool_size must be at least 14 (UNIT_CONCURRENCY 4 + dispatcher CONCURRENCY 8 + 2); the worker refuses to start with less."
  }
}

variable "role_connection_limits" {
  description = "CONNECTION LIMIT of each database role, as backend/scripts/provision_roles.sql sets them (keys api, worker)."
  type        = map(number)
}

variable "oncall_principals" {
  description = "IAM members (user:..., group:...) that run the on-call jobs."
  type        = list(string)
  default     = []
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "reviewer_account_job" {
  description = "Create the afterme-reviewer-account job (the Play reviewer's demo account; docs/RELEASE.md). Turn on only after a version was added to the reviewer-password secret."
  type        = bool
  default     = false
}
