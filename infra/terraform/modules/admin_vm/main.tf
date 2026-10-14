# A small administration VM for the few things that must happen INSIDE the VPC because the
# database has no public address: creating the roles (backend/scripts/provision_roles.sql),
# setting the database passwords (infra/scripts/db_bootstrap.sh) and looking at a restored
# scratch instance (GAMEDAYS OPS-05).
#
# Created only while `enabled`; destroy it (enabled = false) when the work is done. It has no
# external IP (Cloud NAT gives it outbound access for apt and the Cloud SQL Auth Proxy download),
# accepts SSH only through Identity-Aware Proxy from the people with IAP access, uses OS Login,
# and its service account may only add versions to the four database URL secrets.

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

resource "google_service_account" "vm" {
  count = var.enabled ? 1 : 0

  project      = var.project_id
  account_id   = "${var.name_prefix}-admin-vm"
  display_name = "AfterMe admin VM"
  description  = "Writes the database URL secrets from db_bootstrap.sh. Nothing else."
}

resource "google_compute_router" "nat" {
  count = var.enabled ? 1 : 0

  project = var.project_id
  name    = "${var.name_prefix}-admin-router"
  region  = var.region
  network = var.network_id
}

resource "google_compute_router_nat" "nat" {
  count = var.enabled ? 1 : 0

  project                            = var.project_id
  name                               = "${var.name_prefix}-admin-nat"
  router                             = google_compute_router.nat[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = var.subnet_id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# SSH only from Google's IAP range.
resource "google_compute_firewall" "iap_ssh" {
  count = var.enabled ? 1 : 0

  project   = var.project_id
  name      = "${var.name_prefix}-admin-iap-ssh"
  network   = var.network_name
  direction = "INGRESS"
  priority  = 1000

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["${var.name_prefix}-admin-vm"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_instance" "vm" {
  count = var.enabled ? 1 : 0

  project      = var.project_id
  name         = "${var.name_prefix}-admin-vm"
  zone         = var.zone
  machine_type = "e2-small"
  tags         = ["${var.name_prefix}-admin-vm"]

  boot_disk {
    initialize_params {
      image = "projects/debian-cloud/global/images/family/debian-12"
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = var.subnet_id
    # no access_config block: no external address
  }

  service_account {
    email  = google_service_account.vm[0].email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
  }

  # psql 15 talks to the PostgreSQL 17 server; the \if, \gexec and \connect that provision_roles.sql
  # uses exist since 10/11. python3 is there for the URL-safe password check in db_bootstrap.sh.
  metadata_startup_script = <<-EOT
    #!/bin/bash
    set -eu
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq postgresql-client openssl python3
  EOT

  allow_stopping_for_update = true

  depends_on = [google_compute_router_nat.nat]
}

# The people who may SSH in (through IAP, with OS Login).
resource "google_project_iam_member" "os_login" {
  for_each = var.enabled ? toset(var.admin_members) : toset([])

  project = var.project_id
  role    = "roles/compute.osAdminLogin"
  member  = each.value
}

resource "google_project_iam_member" "iap_tunnel" {
  for_each = var.enabled ? toset(var.admin_members) : toset([])

  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = each.value
}

resource "google_service_account_iam_member" "vm_user" {
  for_each = var.enabled ? toset(var.admin_members) : toset([])

  service_account_id = google_service_account.vm[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}
