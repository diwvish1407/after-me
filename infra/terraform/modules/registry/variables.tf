variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "ci_service_account_email" {
  type = string
}

variable "cleanup_dry_run" {
  description = "When true the policies only log what they would delete. Leave true for the first weeks if in doubt."
  type        = bool
  default     = false
}

variable "labels" {
  type    = map(string)
  default = {}
}
