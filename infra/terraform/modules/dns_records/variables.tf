variable "load_balancer_ip" {
  description = "Static IPv4 address of the load balancer (module edge)."
  type        = string
}

variable "domains" {
  description = "Hostnames served by the load balancer (api and public)."
  type        = list(string)
}

variable "caa_apex_domains" {
  description = "Zone names that get a CAA iodef record (afterme.app)."
  type        = list(string)
  default     = []
}

variable "security_email" {
  description = "Address that CAA iodef reports go to."
  type        = string
  default     = "security@afterme.app"
}
