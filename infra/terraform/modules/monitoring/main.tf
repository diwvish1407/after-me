# Monitoring, alerting and logging. See docs/DEPLOYMENT.md §7 and §9 for what each alert means and
# docs/ONCALL.md for what a person does about it.
#
# Where the paging signals come from:
#
#  * Everything that lives in the database (worker heartbeat, Hold evaluation, held actions,
#    messages given up, consistency violations, due action or queued message more than 5 minutes
#    late) is judged by ONE piece of code: `python -m cli.admin status`, which exits 1 exactly when
#    something would page. The Cloud Run job `afterme-status-check` runs it every 2 minutes and
#    a FAILED execution pages. Nothing here re-implements those thresholds, so they cannot drift.
#  * A watchdog on the watchdog: no execution at all for 10 minutes pages too.
#  * Hold entered, consistency violations and held actions are also paged immediately from the
#    critical log lines the engine writes (no waiting for the next status run).
#  * Platform signals (uptime check, 5xx, latency, database, KMS, backups) come from Cloud Monitoring.
#
# Two notification tiers: PAGE = every e-mail address and every SMS number; NOTIFY = e-mail only.

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

locals {
  p   = "[${var.env}]"
  doc = "Runbook: docs/ONCALL.md (one page) and docs/DEPLOYMENT.md section 9. First step for most pages: run the Cloud Run job afterme-oncall-status."
  events = {
    loop_failures = ["worker.tick_failed", "worker.dispatch_failed", "engine.hold_failed"]
    unit_errors = [
      "engine.open_failed", "engine.unit_failed", "engine.reminder_failed", "engine.attempt_count_failed",
      "hold.exit_failed", "dispatch.unit_failed", "dispatch.back_off_failed", "dispatch.unexpected_row",
      "dispatch.rejected", "dispatch.failed", "dispatch.side_effect_failed",
    ]
    critical_now = ["system.hold_entered", "system.hold_window_recorded", "engine.consistency_violation", "engine.action_held"]
    hold         = ["system.hold_entered", "system.hold_ended", "system.hold_window_recorded"]
    maintenance  = ["maintenance.failed", "maintenance.account_purge_failed"]
  }

  # jsonPayload.event=("a" OR "b")
  event_filter = { for k, v in local.events : k => "jsonPayload.event=(${join(" OR ", [for e in v : "\"${e}\""])})" }

  job_filter = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"%s\""
}

# =============================================================================================
# Notification channels
# =============================================================================================
resource "google_monitoring_notification_channel" "email" {
  for_each = toset(var.oncall_emails)

  project      = var.project_id
  display_name = "${local.p} e-mail ${each.value}"
  type         = "email"
  labels       = { email_address = each.value }
  user_labels  = var.labels
}

# An SMS channel is created UNVERIFIED: the person must enter the code Google texts them
# (Console > Monitoring > Alerting > Edit notification channels > SMS > Verify). An unverified
# channel sends nothing, silently: infra/README.md has the check and the `page yourself` test.
resource "google_monitoring_notification_channel" "sms" {
  for_each = toset(var.oncall_phone_numbers)

  project      = var.project_id
  display_name = "${local.p} SMS ${each.value}"
  type         = "sms"
  labels       = { number = each.value }
  user_labels  = var.labels
}

locals {
  notify_channels = [for c in google_monitoring_notification_channel.email : c.id]
  page_channels   = concat(local.notify_channels, [for c in google_monitoring_notification_channel.sms : c.id])
}

# =============================================================================================
# Log retention and what is never kept
# =============================================================================================
# The application writes JSON lines to stdout (structlog, redacted); Cloud Run, the load balancer
# and Cloud SQL write their own. Thirty days, in the default bucket.
resource "google_logging_project_bucket_config" "default" {
  project        = var.project_id
  location       = "global"
  bucket_id      = "_Default"
  retention_days = 30
}

# Nothing here can carry a request body (the load balancer and Cloud Run log method, URL, status
# and sizes only), and the application redacts its own events. These exclusions are a second
# fence for the day somebody adds a field called body: an entry that has one is dropped before
# it is stored. Log-based metrics and log alerts still see the entry (exclusion happens at the
# storage sink), they just never keep the body.
resource "google_logging_project_exclusion" "payload_fields" {
  project     = var.project_id
  name        = "no-request-or-response-bodies"
  description = "Drop any entry that carries a body-like field."
  filter      = "jsonPayload.request_body:* OR jsonPayload.response_body:* OR jsonPayload.body:* OR jsonPayload.payload:* OR httpRequest.requestBody:*"
}

# Health and probe traffic is 99% of the load balancer's request log and says nothing a probe row
# in the database does not.
resource "google_logging_project_exclusion" "probe_noise" {
  project     = var.project_id
  name        = "lb-health-and-probe-requests"
  description = "Load balancer request lines for /health/* and /internal/probe."
  filter      = "resource.type=\"http_load_balancer\" AND httpRequest.status<400 AND (httpRequest.requestUrl:\"/health/\" OR httpRequest.requestUrl:\"/internal/probe\")"
}

# =============================================================================================
# Log-based metrics (names are what the dashboard and the alert policies refer to)
# =============================================================================================
resource "google_logging_metric" "checkins_requests" {
  project     = var.project_id
  name        = "afterme_checkins_requests"
  description = "POST /v1/checkins requests, any status (access log event http.request)."
  filter      = "resource.type=\"cloud_run_revision\" AND jsonPayload.event=\"http.request\" AND jsonPayload.route=\"/v1/checkins\" AND jsonPayload.method=\"POST\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "checkins_5xx" {
  project     = var.project_id
  name        = "afterme_checkins_5xx"
  description = "POST /v1/checkins answered with a 5xx."
  filter      = "resource.type=\"cloud_run_revision\" AND jsonPayload.event=\"http.request\" AND jsonPayload.route=\"/v1/checkins\" AND jsonPayload.method=\"POST\" AND jsonPayload.status>=500"
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "checkins_ok" {
  project     = var.project_id
  name        = "afterme_checkins_ok"
  description = "Successful check-ins (2xx), for the dashboard."
  filter      = "resource.type=\"cloud_run_revision\" AND jsonPayload.event=\"http.request\" AND jsonPayload.route=\"/v1/checkins\" AND jsonPayload.method=\"POST\" AND jsonPayload.status>=200 AND jsonPayload.status<300"
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "incident_opened" {
  project     = var.project_id
  name        = "afterme_incident_opened"
  description = "Incidents opened by the worker (event incident.opened)."
  filter      = "jsonPayload.event=\"incident.opened\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "hold_events" {
  project     = var.project_id
  name        = "afterme_hold_events"
  description = "Hold history: system.hold_entered, system.hold_ended, system.hold_window_recorded."
  filter      = local.event_filter.hold
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "event"
      value_type  = "STRING"
      description = "the event name"
    }
  }
  label_extractors = {
    "event" = "EXTRACT(jsonPayload.event)"
  }
}

resource "google_logging_metric" "engine_loop_failures" {
  project     = var.project_id
  name        = "afterme_engine_loop_failures"
  description = "The worker loop itself failing: worker.tick_failed, worker.dispatch_failed, engine.hold_failed."
  filter      = local.event_filter.loop_failures
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "engine_unit_errors" {
  project     = var.project_id
  name        = "afterme_engine_unit_errors"
  description = "One unit of engine or dispatcher work failing (error class only is logged)."
  filter      = local.event_filter.unit_errors
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "kms_call_failed" {
  project     = var.project_id
  name        = "afterme_kms_call_failed"
  description = "A key could not be wrapped or unwrapped (event kms.call_failed, one line per failure: the Cloud KMS adapter and the vault), by failure code."
  filter      = "jsonPayload.event=\"kms.call_failed\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "failure"
      value_type  = "STRING"
      description = "short failure code (timeout, unavailable, unknown_key, integrity, ...)"
    }
  }
  label_extractors = {
    "failure" = "EXTRACT(jsonPayload.failure)"
  }
}

resource "google_logging_metric" "fallback_used" {
  project     = var.project_id
  name        = "afterme_email_fallback_used"
  description = "A message went through the fallback e-mail provider."
  filter      = "jsonPayload.event=\"email.fallback_used\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "email_webhook_events" {
  project     = var.project_id
  name        = "afterme_email_webhook_events"
  description = "Delivery events from the e-mail providers, by kind (delivered, hard_bounce, soft_bounce, failed, complaint, other: backend/app/notifications/webhooks.py)."
  filter      = "jsonPayload.event=\"webhook.event\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "kind"
      value_type  = "STRING"
      description = "delivery event kind"
    }
  }
  label_extractors = {
    "kind" = "EXTRACT(jsonPayload.kind)"
  }
}

resource "google_logging_metric" "maintenance_failed" {
  project     = var.project_id
  name        = "afterme_maintenance_failed"
  description = "The retention job logged a failure."
  filter      = local.event_filter.maintenance
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# The numbers inside `cli.admin status` (the watchdog prints its JSON to stdout, one field per
# line, so a regular expression reads them). They feed the dashboard's "worker lag" tiles only;
# nothing pages from them (the exit code does).
resource "google_logging_metric" "status_value" {
  for_each = {
    worker_heartbeat_age_seconds      = "Seconds since the worker's last heartbeat"
    oldest_due_action_age_seconds     = "Age of the oldest due, unexecuted action"
    oldest_queued_message_age_seconds = "Age of the oldest queued message past send_after"
    hold_evaluation_age_seconds       = "Seconds since the Hold monitor's last evaluation"
    incidents_open                    = "Open incidents"
  }

  project     = var.project_id
  name        = "afterme_status_${each.key}"
  description = each.value
  filter      = "${format(local.job_filter, var.status_check_job_name)} AND textPayload=~\"${each.key}.: [0-9]\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = each.key == "incidents_open" ? "1" : "s"
  }
  value_extractor = "REGEXP_EXTRACT(textPayload, \"${each.key}.: ([0-9.]+)\")"
  bucket_options {
    exponential_buckets {
      num_finite_buckets = 24
      growth_factor      = 2
      scale              = 1
    }
  }
}
