# Artifact Registry: one Docker repository per project. Images are deployed by digest, so a tag
# is only a label; cleanup keeps the newest versions (a rollback needs the previous one) and every
# release-tagged version.

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

resource "google_artifact_registry_repository" "backend" {
  project       = var.project_id
  location      = var.region
  repository_id = "afterme"
  format        = "DOCKER"
  description   = "AfterMe backend image (API, worker, maintenance, operator CLI, migrations)."

  docker_config {
    immutable_tags = false # the `main`/`staging` convenience tags move; deploys use the digest
  }

  cleanup_policy_dry_run = var.cleanup_dry_run

  # Untagged layers left by re-tagging.
  cleanup_policies {
    id     = "delete-untagged-after-14-days"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "1209600s"
    }
  }

  # Anything else older than 90 days...
  cleanup_policies {
    id     = "delete-old-after-90-days"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "7776000s"
    }
  }

  # ...except the 20 newest versions (the running one and the rollback target are always among
  # them) and every release (tag v1.2.3).
  cleanup_policies {
    id     = "keep-newest-20"
    action = "KEEP"
    most_recent_versions {
      keep_count = 20
    }
  }
  cleanup_policies {
    id     = "keep-releases"
    action = "KEEP"
    condition {
      tag_state    = "TAGGED"
      tag_prefixes = ["v"]
    }
  }

  labels = var.labels
}

resource "google_artifact_registry_repository_iam_member" "ci_writer" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.backend.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${var.ci_service_account_email}"
}
