variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "instance_name" {
  description = "Cloud SQL instance name. A deleted name cannot be reused for about a week."
  type        = string
}

variable "network_id" {
  description = "VPC with private services access (module network)."
  type        = string
}

variable "private_services_connection" {
  description = "Output of the network module; makes the instance wait for the peering."
  type        = string
}

variable "tier" {
  description = "Machine type. Enterprise edition: db-custom-<vCPU>-<MiB>."
  type        = string
}

variable "high_availability" {
  description = "REGIONAL (a standby in a second zone, automatic failover) when true; ZONAL when false."
  type        = bool
}

variable "disk_size_gb" {
  type    = number
  default = 20
}

variable "disk_autoresize_limit_gb" {
  description = "Upper bound of automatic disk growth (0 = unlimited). A bound keeps a runaway write from becoming a bill."
  type        = number
  default     = 200
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "backup_start_time_utc" {
  description = "HH:MM (UTC) at which the daily automated backup window starts."
  type        = string
  default     = "21:00"
}

variable "backup_location" {
  description = "Where backups are stored: a region or a multi-region. A single region keeps the data in India; it also means a region-wide loss takes the backups with it (docs/INFRASTRUCTURE.md, DR)."
  type        = string
  default     = "asia-south1"
}

variable "pitr_days" {
  description = "Days of write-ahead logs kept for point-in-time recovery (1-7 on Enterprise)."
  type        = number
  default     = 7
}

variable "retained_backups" {
  description = "Automated backups kept (one a day)."
  type        = number
  default     = 30
}

variable "max_connections" {
  description = "PostgreSQL max_connections. The alert fires at 80% of it. Role limits (provision_roles.sql) sum to 90."
  type        = number
  default     = 200
}

variable "labels" {
  type    = map(string)
  default = {}
}
