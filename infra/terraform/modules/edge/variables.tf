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

variable "api_service_name" {
  description = "Cloud Run service behind the load balancer."
  type        = string
}

variable "api_domain" {
  description = "Hostname of the API (api.afterme.app)."
  type        = string
}

variable "public_domain" {
  description = "Hostname of the public web pages (afterme.app)."
  type        = string
}

variable "enable_cloud_armor" {
  description = "Attach a Cloud Armor policy with a per-IP rate ceiling. Off by default: see docs/INFRASTRUCTURE.md §7."
  type        = bool
  default     = false
}

variable "armor_requests_per_minute" {
  description = "Per-IP ceiling when Cloud Armor is on."
  type        = number
  default     = 3000
}
