variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "env" {
  description = "staging or prod; prefixes every display name."
  type        = string
}

variable "name_prefix" {
  type    = string
  default = "afterme"
}

variable "api_domain" {
  description = "Host the uptime check calls (through the load balancer)."
  type        = string
}

variable "api_service_name" {
  type = string
}

variable "status_check_job_name" {
  description = "The Cloud Run job that runs `cli.admin status` every 2 minutes."
  type        = string
}

variable "maintenance_job_name" {
  type = string
}

variable "database_id" {
  description = "project:instance (resource label of the Cloud SQL metrics)."
  type        = string
}

variable "database_instance_name" {
  type = string
}

variable "database_max_connections" {
  type = number
}

variable "backup_check_image" {
  description = "Image of the backup-freshness job (the Google Cloud CLI)."
  type        = string
  default     = "gcr.io/google.com/cloudsdktool/google-cloud-cli:slim"
}

variable "backup_check_service_account_email" {
  description = "Service account of the backup-freshness job (needs cloudsql.backupRuns.list and cloudsql.instances.get)."
  type        = string
}

variable "scheduler_service_account_email" {
  type = string
}

variable "network_name" {
  type = string
}

variable "subnet_name" {
  type = string
}

variable "oncall_emails" {
  description = "Everyone who is emailed (pages and non-paging alerts). Two people."
  type        = list(string)

  validation {
    condition     = length(var.oncall_emails) >= 1
    error_message = "At least one e-mail address is needed; two are expected (docs/BETA_PLAN.md §4)."
  }
}

variable "oncall_phone_numbers" {
  description = "E.164 numbers that receive SMS for PAGES only (+91...). Each must be verified once in the console."
  type        = list(string)

  validation {
    condition     = alltrue([for n in var.oncall_phone_numbers : can(regex("^\\+[1-9][0-9]{7,14}$", n))])
    error_message = "Phone numbers must be E.164 (+919876543210)."
  }
}

variable "probe_header_placeholder" {
  description = "Placeholder header value; the real token is set by infra/scripts/set_probe_header.sh and ignored by Terraform."
  type        = string
  default     = "REPLACE-VIA-set_probe_header.sh"
}

variable "uptime_regions" {
  type    = list(string)
  default = ["ASIA_PACIFIC", "EUROPE", "USA_VIRGINIA"]
}

variable "labels" {
  type    = map(string)
  default = {}
}
