# Bootstrap: run ONCE per Google Cloud project (staging and prod separately), with local state, by a
# human who is Owner of the project. It enables the APIs everything else needs and creates the
# versioned Cloud Storage bucket that holds the remote state of envs/<env>.
#
# Nothing here is a secret. The local state of this directory (terraform.tfstate) only knows the
# bucket and the API list; keep it, but losing it is harmless (`terraform import` the bucket).

terraform {
  required_version = "~> 1.16"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.46"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  apis = toset([
    "artifactregistry.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudscheduler.googleapis.com",
    "compute.googleapis.com",
    "fcm.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "oslogin.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "serviceusage.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])
  bucket_name = coalesce(var.state_bucket_name, "${var.project_id}-tfstate")
}

resource "google_project_service" "apis" {
  for_each = local.apis

  project = var.project_id
  service = each.value

  # Turning an API off would delete the resources that depend on it.
  disable_on_destroy = false
}

resource "google_storage_bucket" "state" {
  project  = var.project_id
  name     = local.bucket_name
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  # Every apply writes a new object version: an overwritten or corrupted state can be restored.
  versioning {
    enabled = true
  }

  # Keep the ten newest older versions, and nothing older than 180 days besides them.
  lifecycle_rule {
    condition {
      num_newer_versions         = 10
      days_since_noncurrent_time = 180
      with_state                 = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}
