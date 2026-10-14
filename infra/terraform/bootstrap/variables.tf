variable "project_id" {
  description = "Google Cloud project id of this environment (afterme-staging or afterme-prod)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a Google Cloud project id (6-30 characters, lower case)."
  }
}

variable "region" {
  description = "Region of the state bucket and of everything else."
  type        = string
  default     = "asia-south1"
}

variable "state_bucket_name" {
  description = "Name of the state bucket. Default: <project_id>-tfstate."
  type        = string
  default     = null
}
