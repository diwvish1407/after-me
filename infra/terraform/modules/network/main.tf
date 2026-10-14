# Network: one VPC, one subnet for Cloud Run's Direct VPC egress, and private services access
# (the VPC peering that gives Cloud SQL its private IP). There is no NAT and no external IP:
# Cloud Run reaches the internet (mail providers, FCM, Google APIs) through its own egress path
# because the egress setting is PRIVATE_RANGES_ONLY, and only private ranges go through this VPC.

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# Direct VPC egress: every Cloud Run instance takes an address from this range. Cloud Run
# needs at least a /26; a /24 leaves room for a rollout that doubles the instances.
resource "google_compute_subnetwork" "run" {
  project                  = var.project_id
  name                     = "${var.name_prefix}-run"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.run_subnet_cidr
  private_ip_google_access = true
}

# The range that Google carves Cloud SQL's private addresses from.
resource "google_compute_global_address" "private_services" {
  project       = var.project_id
  name          = "${var.name_prefix}-private-services"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.private_services_prefix_length
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_services" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]

  # Deleting the peering while an instance uses it fails; `ABANDON` lets a destroy of the
  # whole stack finish after the instance is gone.
  deletion_policy = "ABANDON"
}
