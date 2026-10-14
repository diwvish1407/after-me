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

variable "run_subnet_cidr" {
  description = "Subnet for Cloud Run Direct VPC egress (at least /26)."
  type        = string
  default     = "10.10.0.0/24"
}

variable "private_services_prefix_length" {
  description = "Size of the range reserved for Cloud SQL (private services access)."
  type        = number
  default     = 24
}
