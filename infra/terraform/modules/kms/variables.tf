variable "project_id" {
  type = string
}

variable "region" {
  description = "Key location. Keep it equal to the database region."
  type        = string
}

variable "api_service_account_email" {
  description = "The only identity that may wrap and unwrap with this key."
  type        = string
}

variable "labels" {
  type    = map(string)
  default = {}
}
