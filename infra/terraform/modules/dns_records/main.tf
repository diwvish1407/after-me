# The DNS records to create by hand in Cloudflare. Terraform does not manage Cloudflare. Nothing
# here creates a resource: the module only turns the load balancer's address into the exact
# records, printed by `terraform output dns_records`.
#
# PROXY OFF (grey cloud) on every record below: the load balancer terminates TLS with a Google
# certificate that is issued only when the name resolves straight to the load balancer, and a
# Cloudflare proxy in front would add a hop to X-Forwarded-For (TRUSTED_PROXY_HOPS would be wrong).

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

locals {
  records = concat(
    [for d in var.domains : {
      type    = "A"
      name    = d
      content = var.load_balancer_ip
      proxy   = false
      note    = "Points the hostname at the load balancer. TTL: Auto."
    }],
    [for d in var.domains : {
      type    = "CAA"
      name    = d
      content = "0 issue \"pki.goog\""
      proxy   = false
      note    = "Allows Google Trust Services (the managed certificate). Add it only if the zone has CAA records at all; keep existing ones."
    }],
    [for d in var.caa_apex_domains : {
      type    = "CAA"
      name    = d
      content = "0 iodef \"mailto:${var.security_email}\""
      proxy   = false
      note    = "Where a certificate authority reports a refused or suspicious issuance."
    }],
  )
}
