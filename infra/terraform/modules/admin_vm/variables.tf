variable "enabled" {
  description = "Create the VM and its network plumbing. Turn on to provision the roles, turn off afterwards."
  type        = bool
  default     = false
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "zone" {
  type = string
}

variable "name_prefix" {
  type    = string
  default = "afterme"
}

variable "network_id" {
  type = string
}

variable "network_name" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "admin_members" {
  description = "IAM members (user:...) who may SSH to the VM through IAP."
  type        = list(string)
  default     = []
}
