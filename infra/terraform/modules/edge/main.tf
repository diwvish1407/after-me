# The edge: one global external Application Load Balancer in front of the Cloud Run API.
#
#   client --TLS--> forwarding rule (static IPv4) --> HTTPS proxy (Google-managed certificate,
#   TLS >= 1.2) --> URL map --> backend service --> serverless NEG --> Cloud Run `afterme-api`
#
# Why not a Cloud Run domain mapping: mappings are a Preview feature with a short list of regions
# (asia-south1 was not on it when this was written; verify), they cannot restrict ingress to a
# load balancer and they cannot carry Cloud Armor. With the load balancer the Cloud Run service
# accepts traffic only from it (ingress INTERNAL_LOAD_BALANCER), so the client address that
# reaches the application always comes through the same two Google hops (docs/INFRASTRUCTURE.md §7).
#
# Cloudflare: the records that point at the static IP must NOT be proxied (orange cloud off). The
# certificate is issued by Google for the two hostnames once they resolve to the IP.

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

locals {
  domains    = sort(distinct([var.api_domain, var.public_domain]))
  cert_label = substr(sha1(join(",", local.domains)), 0, 8)
}

resource "google_compute_global_address" "ip" {
  project      = var.project_id
  name         = "${var.name_prefix}-edge-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

resource "google_compute_region_network_endpoint_group" "api" {
  project               = var.project_id
  name                  = "${var.name_prefix}-api-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = var.api_service_name
  }
}

resource "google_compute_security_policy" "api" {
  count = var.enable_cloud_armor ? 1 : 0

  project     = var.project_id
  name        = "${var.name_prefix}-api-armor"
  description = "Default allow. A generous per-IP ceiling only: a carrier-grade NAT shares one address between many phones, and a wrongly refused check-in is worse than a flood."

  rule {
    action      = "throttle"
    priority    = 1000
    description = "Per-IP ceiling"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = var.armor_requests_per_minute
        interval_sec = 60
      }
    }
  }

  rule {
    action      = "allow"
    priority    = 2147483647
    description = "Default rule"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

resource "google_compute_backend_service" "api" {
  project               = var.project_id
  name                  = "${var.name_prefix}-api-backend"
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 60
  security_policy       = var.enable_cloud_armor ? google_compute_security_policy.api[0].id : null

  backend {
    group = google_compute_region_network_endpoint_group.api.id
  }

  # Request logs carry the method, the URL and the status. No headers, no bodies.
  log_config {
    enable        = true
    sample_rate   = 1.0
    optional_mode = "EXCLUDE_ALL_OPTIONAL"
  }
}

resource "google_compute_url_map" "https" {
  project         = var.project_id
  name            = "${var.name_prefix}-https"
  default_service = google_compute_backend_service.api.id
}

# Port 80 only redirects (the application sends HSTS, but the first request of a browser may be http).
resource "google_compute_url_map" "redirect" {
  project = var.project_id
  name    = "${var.name_prefix}-http-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_managed_ssl_certificate" "api" {
  project = var.project_id
  name    = "${var.name_prefix}-cert-${local.cert_label}"

  managed {
    domains = local.domains
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_ssl_policy" "modern" {
  project         = var.project_id
  name            = "${var.name_prefix}-tls12-modern"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_target_https_proxy" "api" {
  project          = var.project_id
  name             = "${var.name_prefix}-https-proxy"
  url_map          = google_compute_url_map.https.id
  ssl_certificates = [google_compute_managed_ssl_certificate.api.id]
  ssl_policy       = google_compute_ssl_policy.modern.id
}

resource "google_compute_target_http_proxy" "redirect" {
  project = var.project_id
  name    = "${var.name_prefix}-http-proxy"
  url_map = google_compute_url_map.redirect.id
}

resource "google_compute_global_forwarding_rule" "https" {
  project               = var.project_id
  name                  = "${var.name_prefix}-https"
  ip_address            = google_compute_global_address.ip.id
  ip_protocol           = "TCP"
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_https_proxy.api.id
}

resource "google_compute_global_forwarding_rule" "http" {
  project               = var.project_id
  name                  = "${var.name_prefix}-http"
  ip_address            = google_compute_global_address.ip.id
  ip_protocol           = "TCP"
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_http_proxy.redirect.id
}
