# =============================================================================================
# The uptime check: POST /internal/probe through the PUBLIC domain, once a minute, from several
# regions. This is the signal that feeds the ingestion Hold (ESCALATION_ENGINE §7): the engine
# enters Hold when probes stop, so every probe must travel the path real users travel.
#
# The probe token is a secret and Terraform must not know it. The check is created with a
# placeholder header, Terraform ignores the header afterwards, and infra/scripts/set_probe_header.sh
# copies the token from Secret Manager into the check through the Monitoring API (the value is
# stored masked in the check's configuration; that is unavoidable, a check needs the header).
# Until the script has run the probe answers 401, the check fails, the page fires, and the engine
# is in Hold: loud and safe.
# =============================================================================================
resource "google_monitoring_uptime_check_config" "probe" {
  project      = var.project_id
  display_name = "${local.p} POST /internal/probe"
  timeout      = "10s"
  period       = "60s"

  selected_regions = var.uptime_regions

  http_check {
    request_method = "POST"
    path           = "/internal/probe"
    port           = 443
    use_ssl        = true
    validate_ssl   = true
    content_type   = "URL_ENCODED"
    body           = base64encode("") # an empty body
    mask_headers   = true

    headers = {
      "X-Probe-Token"  = var.probe_header_placeholder
      "X-Probe-Source" = "gcp-uptime"
    }

    accepted_response_status_codes {
      status_value = 204
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.api_domain
    }
  }

  user_labels = var.labels

  lifecycle {
    # infra/scripts/set_probe_header.sh owns the token
    ignore_changes = [http_check[0].headers]
  }
}

# =============================================================================================
# Backup freshness. Cloud SQL does not publish "the last backup failed" as a metric, and a log
# filter on its operation messages cannot be tested here. So a small job asks the API directly:
# was there a SUCCESSFUL backup in the last 26 hours, and is point-in-time recovery still on?
# A failed execution pages. It also catches a configuration drift (PITR switched off).
# =============================================================================================
resource "google_cloud_run_v2_job" "backup_check" {
  project  = var.project_id
  location = var.region
  name     = "${var.name_prefix}-backup-check"

  labels              = var.labels
  deletion_protection = false

  template {
    task_count = 1

    template {
      service_account = var.backup_check_service_account_email
      max_retries     = 1
      timeout         = "120s"

      containers {
        name    = "check"
        image   = var.backup_check_image
        command = ["bash", "-ceu"]
        args = [<<-EOT
          pitr="$(gcloud sql instances describe "$INSTANCE" --project "$PROJECT" --format='value(settings.backupConfiguration.pointInTimeRecoveryEnabled)')"
          [ "$pitr" = "True" ] || { echo "backup-check FAIL: point-in-time recovery is not enabled ($pitr)"; exit 1; }
          last="$(gcloud sql backups list --instance "$INSTANCE" --project "$PROJECT" --filter='status=SUCCESSFUL' --sort-by='~endTime' --limit=1 --format='value(endTime)')"
          [ -n "$last" ] || { echo "backup-check FAIL: no successful backup at all"; exit 1; }
          age=$(( $(date +%s) - $(date -d "$last" +%s) ))
          echo "backup-check: newest successful backup ended $last ($age s ago)"
          [ "$age" -le 93600 ] || { echo "backup-check FAIL: newest backup is older than 26 hours"; exit 1; }
        EOT
        ]

        env {
          name  = "INSTANCE"
          value = var.database_instance_name
        }
        env {
          name  = "PROJECT"
          value = var.project_id
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [client, client_version]
  }
}

resource "google_cloud_run_v2_job_iam_member" "backup_check_scheduler" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.backup_check.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.scheduler_service_account_email}"
}

resource "google_cloud_scheduler_job" "backup_check" {
  project          = var.project_id
  region           = var.region
  name             = "${var.name_prefix}-backup-check"
  description      = "Runs the backup freshness job every 6 hours."
  schedule         = "17 */6 * * *"
  time_zone        = "Etc/UTC"
  attempt_deadline = "60s"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.backup_check.name}:run"

    oauth_token {
      service_account_email = var.scheduler_service_account_email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.backup_check_scheduler]
}
