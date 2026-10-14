# =============================================================================================
# Alert policies. Names start with the environment. user_labels.tier = page | notify.
#
# "Fail-safe, not fail-trigger": every page below is either a state the engine itself calls a page
# (cli.admin status), or a rate with a minimum number of requests behind it, or a condition that
# lasts more than a blip. A silence is covered by an absence alert (the watchdog) so that a broken
# monitor cannot look like a healthy system.
# =============================================================================================

locals {
  base_strategy_close = "1800s"
}

# ---- 1. status watchdog: `cli.admin status` exited 1 (anything the engine says would page) -----
resource "google_monitoring_alert_policy" "status_failing" {
  project      = var.project_id
  display_name = "${local.p} PAGE: engine status check reports a page"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "afterme-status-check execution failed"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${var.status_check_job_name}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result=\"failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.labels.job_name"]
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.page_channels

  alert_strategy {
    auto_close = local.base_strategy_close
    notification_channel_strategy {
      renotify_interval          = "1800s"
      notification_channel_names = local.page_channels
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      `python -m cli.admin status` exited 1. One or more of: worker heartbeat older than 2 minutes, **Hold active**, hold evaluation failing, held actions, messages given up on, consistency violations, a due action or queued message more than 5 minutes late. Or the database is unreachable.

      Run the Cloud Run job **afterme-oncall-status** and read the `pages` list. ${local.doc}
    EOT
  }

  user_labels = merge(var.labels, { tier = "page" })
}

# ---- 2. the watchdog itself has stopped (no execution at all) -------------------------------
resource "google_monitoring_alert_policy" "status_silent" {
  project      = var.project_id
  display_name = "${local.p} PAGE: the status watchdog is not running"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "no execution of afterme-status-check for 10 minutes"
    condition_absent {
      filter   = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${var.status_check_job_name}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\""
      duration = "600s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.labels.job_name"]
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.page_channels

  alert_strategy {
    auto_close = local.base_strategy_close
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      The Cloud Scheduler job that runs the engine status check every 2 minutes has not produced an execution for 10 minutes. Until it runs again, **nothing watches the worker heartbeat or the backlog**. Check Cloud Scheduler (`${var.name_prefix}-status-check`) and the Cloud Run job. Run **afterme-oncall-status** by hand. ${local.doc}
    EOT
  }

  user_labels = merge(var.labels, { tier = "page" })
}

# ---- 3. Hold entered, consistency violation, held action: immediate, from the critical logs -----
resource "google_monitoring_alert_policy" "critical_log" {
  project      = var.project_id
  display_name = "${local.p} PAGE: Hold entered / consistency violation / action held (log)"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "critical engine log event"
    condition_matched_log {
      filter = local.event_filter.critical_now
    }
  }

  notification_channels = local.page_channels

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "3600s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      The engine wrote one of `system.hold_entered`, `system.hold_window_recorded`, `engine.consistency_violation`, `engine.action_held` at CRITICAL.

      * **Hold**: contact-facing messages are frozen; reminders to people continue. Do not exit it until the cause is known (afterme-oncall-hold-status). An ingestion Hold ends by itself after 10 minutes of fresh probes.
      * **Consistency violation / held action**: never force anything. Tell the developer.

      ${local.doc}
    EOT
  }

  user_labels = merge(var.labels, { tier = "page" })
}

# ---- 4. the worker loop failing repeatedly ---------------------------------------------------
resource "google_monitoring_alert_policy" "engine_loop" {
  project      = var.project_id
  display_name = "${local.p} PAGE: worker loop failing (hold evaluation, tick, dispatch)"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "3 or more loop failures in 5 minutes"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.engine_loop_failures.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 2
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.page_channels

  alert_strategy {
    auto_close = local.base_strategy_close
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      The worker logged `worker.tick_failed`, `worker.dispatch_failed` or `engine.hold_failed` three times in five minutes. `engine.hold_failed` means Hold cannot be evaluated: the engine then treats the state as a Hold (no incident opens, nothing reaches a contact) until a good evaluation. Read the worker logs (error class only) and tell the developer. ${local.doc}
    EOT
  }

  user_labels = merge(var.labels, { tier = "page" })
}

# ---- 5. uptime check: at least 2 of the regions fail for 2 minutes --------------------------------
resource "google_monitoring_alert_policy" "uptime" {
  project      = var.project_id
  display_name = "${local.p} PAGE: uptime check POST /internal/probe failing"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "probe failing from 2 or more regions"
    condition_threshold {
      filter          = "resource.type=\"uptime_url\" AND metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.labels.check_id=\"${google_monitoring_uptime_check_config.probe.uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "120s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.*"]
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.page_channels

  alert_strategy {
    auto_close = local.base_strategy_close
    notification_channel_strategy {
      renotify_interval          = "1800s"
      notification_channel_names = local.page_channels
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      The probe that the engine uses to know the public ingress works (`POST https://${var.api_domain}/internal/probe`) is failing from at least two of three regions. **If it stays down for 3 minutes the engine enters Hold by itself** (that is the design). Check the load balancer, the certificate and Cloud Run. If the answer is 401 the token in the check differs from the secret: run infra/scripts/set_probe_header.sh. If 429: see docs/DEPLOYMENT.md §9 "Probe returns 429". ${local.doc}
    EOT
  }

  user_labels = merge(var.labels, { tier = "page" })
}

# ---- 6. the uptime check stopped reporting at all (deleted, paused, header lost) -----------------
resource "google_monitoring_alert_policy" "uptime_silent" {
  project      = var.project_id
  display_name = "${local.p} PAGE: uptime check is not reporting"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "no uptime result for 10 minutes"
    condition_absent {
      filter   = "resource.type=\"uptime_url\" AND metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.labels.check_id=\"${google_monitoring_uptime_check_config.probe.uptime_check_id}\""
      duration = "600s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT"
        group_by_fields      = ["metric.labels.check_id"]
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.page_channels

  alert_strategy {
    auto_close = local.base_strategy_close
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Cloud Monitoring has recorded no result of the probe check for 10 minutes: the check was paused, deleted or Monitoring is impaired. Without probes the engine will enter Hold. ${local.doc}
    EOT
  }

  user_labels = merge(var.labels, { tier = "page" })
}

# ---- 7. API 5xx rate (with a floor of requests) ------------------------------------------------
resource "google_monitoring_alert_policy" "api_5xx" {
  project      = var.project_id
  display_name = "${local.p} PAGE: API 5xx rate above 2% (5 min)"
  combiner     = "AND"
  enabled      = true

  conditions {
    display_name = "5xx share of requests above 2%"
    condition_threshold {
      filter             = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${var.api_service_name}\" AND metric.type=\"run.googleapis.com/request_count\" AND metric.labels.response_code_class=\"5xx\""
      denominator_filter = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${var.api_service_name}\" AND metric.type=\"run.googleapis.com/request_count\""
      comparison         = "COMPARISON_GT"
      threshold_value    = 0.02
      duration           = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.labels.service_name"]
      }
      denominator_aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.labels.service_name"]
      }
      trigger {
        count = 1
      }
    }
  }

  conditions {
    display_name = "at least 20 requests in the window"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${var.api_service_name}\" AND metric.type=\"run.googleapis.com/request_count\""
      comparison      = "COMPARISON_GT"
      threshold_value = 19
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.labels.service_name"]
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.page_channels

  alert_strategy {
    auto_close = local.base_strategy_close
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      More than 2% of API requests failed with a 5xx over 5 minutes (and there were at least 20 requests). People may be unable to check in. If it is a bad release, roll back (docs/DEPLOYMENT.md §5; deploy.yml prints the command). If it lasts, the ingestion Hold will start by itself once probes fail. ${local.doc}
    EOT
  }

  user_labels = merge(var.labels, { tier = "page" })
}

# ---- 8. POST /v1/checkins error rate (from the access log) -------------------------------------
resource "google_monitoring_alert_policy" "checkins_5xx" {
  project      = var.project_id
  display_name = "${local.p} PAGE: POST /v1/checkins error rate above 1% (5 min)"
  combiner     = "AND"
  enabled      = true

  conditions {
    display_name = "check-in 5xx share above 1%"
    condition_threshold {
      filter             = "resource.type=\"cloud_run_revision\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.checkins_5xx.name}\""
      denominator_filter = "resource.type=\"cloud_run_revision\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.checkins_requests.name}\""
      comparison         = "COMPARISON_GT"
      threshold_value    = 0.01
      duration           = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
      denominator_aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  conditions {
    display_name = "at least 20 check-in requests in the window"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.checkins_requests.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 19
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.page_channels

  alert_strategy {
    auto_close = local.base_strategy_close
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      More than 1% of `POST /v1/checkins` (I'M OK) failed with a 5xx over 5 minutes. A person who cannot check in will miss a deadline. Check the API logs and the database, and consider **entering Hold** if it will not clear within minutes. ${local.doc}
    EOT
  }

  user_labels = merge(var.labels, { tier = "page" })
}

# ---- 9. database ---------------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "database" {
  project      = var.project_id
  display_name = "${local.p} PAGE: database CPU, connections, disk above 80% / instance down"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "CPU above 80% for 10 minutes"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.database_id}\" AND metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "600s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
      trigger {
        count = 1
      }
    }
  }

  conditions {
    display_name = "disk above 80%"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.database_id}\" AND metric.type=\"cloudsql.googleapis.com/database/disk/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
      trigger {
        count = 1
      }
    }
  }

  conditions {
    display_name = "connections above 80% of max_connections"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.database_id}\" AND metric.type=\"cloudsql.googleapis.com/database/postgresql/num_backends\""
      comparison      = "COMPARISON_GT"
      threshold_value = floor(var.database_max_connections * 0.8)
      duration        = "300s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MAX"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.labels.database_id"]
      }
      trigger {
        count = 1
      }
    }
  }

  conditions {
    display_name = "instance not up for 2 minutes"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.database_id}\" AND metric.type=\"cloudsql.googleapis.com/database/up\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "120s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.page_channels

  alert_strategy {
    auto_close = local.base_strategy_close
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      The Cloud SQL instance is under pressure or down (CPU, disk or connections above 80%, or `database/up` below 1). A regional failover takes about a minute and shows as a short `up` dip; the alert needs 2 minutes. Check Cloud SQL in the console. If the API and worker cannot reach the database the engine cannot see a Hold either: consider entering Hold once the database is back. ${local.doc}
    EOT
  }

  user_labels = merge(var.labels, { tier = "page" })
}

# ---- 10. KMS ------------------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "kms" {
  project      = var.project_id
  display_name = "${local.p} PAGE: KMS wrap/unwrap errors"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "3 or more KMS call failures in 5 minutes"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.kms_call_failed.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 2
      duration        = "0s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  # A failure that is not an outage but a configuration or integrity fault: a stored key that
  # names another CryptoKey (KMS_KEY_NAME changed), a refused or tampered answer, a missing role.
  # Each one means every affected read fails until a person acts, so ONE pages.
  conditions {
    display_name = "any KMS configuration or integrity failure"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.kms_call_failed.name}\" AND metric.labels.failure=monitoring.regex.full_match(\"(unknown_key|integrity|key_mismatch|bad_response|invalid_argument|permission_denied|not_found|unauthenticated|not_configured|invalid_ciphertext)\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.page_channels

  alert_strategy {
    auto_close = local.base_strategy_close
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      The API could not wrap or unwrap a data key with Cloud KMS (`kms.call_failed`; the `failure` label says why: `unknown_key` = the stored keys name another CryptoKey than KMS_KEY_NAME, `permission_denied` = the API service account lost its role, `integrity`/`bad_response` = an answer failed its checksum). People cannot save or open instructions, and a contact cannot open a release. Check Cloud KMS status, the key's state (it must be enabled) and the API service account's role on the key. ${local.doc}
    EOT
  }

  user_labels = merge(var.labels, { tier = "page" })
}

# ---- 11. backups: the freshness job failed ---------------------------------------------------------
resource "google_monitoring_alert_policy" "backup" {
  project      = var.project_id
  display_name = "${local.p} PAGE: database backup is stale or point-in-time recovery is off"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "afterme-backup-check failed"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${google_cloud_run_v2_job.backup_check.name}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result=\"failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period     = "21600s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.labels.job_name"]
      }
      trigger {
        count = 1
      }
    }
  }

  conditions {
    display_name = "afterme-backup-check not running for 13 hours"
    condition_absent {
      filter   = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${google_cloud_run_v2_job.backup_check.name}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\""
      duration = "46800s"
      aggregations {
        alignment_period     = "3600s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.labels.job_name"]
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.page_channels

  alert_strategy {
    auto_close = "86400s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      The newest successful Cloud SQL backup is older than 26 hours, point-in-time recovery is off, or the check itself has not run for 13 hours. Open Cloud SQL > Backups. Do not wait for the next restore drill. ${local.doc}
    EOT
  }

  user_labels = merge(var.labels, { tier = "page" })
}

# ---- 12. a deliberate test page ("page yourself"): infra/README.md section 11 -------------------------
resource "google_monitoring_alert_policy" "alert_test" {
  project      = var.project_id
  display_name = "${local.p} PAGE (TEST): alert path test"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "test log entry written"
    condition_matched_log {
      filter = "logName=\"projects/${var.project_id}/logs/afterme-alert-test\" AND jsonPayload.event=\"infra.alert_test\""
    }
  }

  notification_channels = local.page_channels

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "This is a **test** of the paging path, started on purpose with `gcloud logging write afterme-alert-test`. Nothing is wrong. Acknowledge it and tell the owner that it arrived on your phone and by e-mail."
  }

  user_labels = merge(var.labels, { tier = "page", purpose = "test" })
}

# =============================================================================================
# NOTIFY (e-mail only): worth reading the same day, not worth waking anyone
# =============================================================================================
resource "google_monitoring_alert_policy" "api_latency" {
  project      = var.project_id
  display_name = "${local.p} notify: API p95 latency above 2 s (10 min)"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "p95 request latency above 2000 ms"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${var.api_service_name}\" AND metric.type=\"run.googleapis.com/request_latencies\""
      comparison      = "COMPARISON_GT"
      threshold_value = 2000
      duration        = "600s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_PERCENTILE_95"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["resource.labels.service_name"]
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.notify_channels

  alert_strategy {
    auto_close = local.base_strategy_close
  }

  documentation {
    mime_type = "text/markdown"
    content   = "p95 latency of the API has been above 2 seconds for 10 minutes. Look at the dashboard (database CPU, instance count). ${local.doc}"
  }

  user_labels = merge(var.labels, { tier = "notify" })
}

resource "google_monitoring_alert_policy" "engine_unit_errors" {
  project      = var.project_id
  display_name = "${local.p} notify: engine or dispatcher units failing"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "5 or more failed units in 10 minutes"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.engine_unit_errors.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 4
      duration        = "0s"
      aggregations {
        alignment_period     = "600s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.notify_channels

  alert_strategy {
    auto_close = local.base_strategy_close
  }

  documentation {
    mime_type = "text/markdown"
    content   = "Units of engine or dispatcher work are failing (the status check pages on the consequences: held actions, a message past its time, given-up messages). Read the worker logs for the event names. ${local.doc}"
  }

  user_labels = merge(var.labels, { tier = "notify" })
}

resource "google_monitoring_alert_policy" "provider_fallback" {
  project      = var.project_id
  display_name = "${local.p} notify: fallback e-mail provider is carrying messages"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "3 or more fallback sends in 15 minutes"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.fallback_used.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 2
      duration        = "0s"
      aggregations {
        alignment_period     = "900s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.notify_channels

  alert_strategy {
    auto_close = local.base_strategy_close
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The primary e-mail provider is failing and the fallback is carrying messages (nothing is lost). Check the primary provider's status page and the secret `email-api-key` (docs/DEPLOYMENT.md §9, OPS-03). If the fallback fails too, a page follows from the backlog check. ${local.doc}"
  }

  user_labels = merge(var.labels, { tier = "notify" })
}

resource "google_monitoring_alert_policy" "bounces_complaints" {
  project      = var.project_id
  display_name = "${local.p} notify: spam complaint or hard-bounce spike"
  combiner     = "OR"
  enabled      = true

  # The kinds are the app's own (backend/app/notifications/webhooks.py, Kind, logged as
  # `webhook.event` with `kind`): delivered, hard_bounce, soft_bounce, failed, complaint, other.

  # A recipient marked an AfterMe e-mail as spam. Rare and serious (the sender reputation that
  # alerts depend on): every one notifies. The 24-hour auto-close keeps one open incident per day.
  conditions {
    display_name = "any spam complaint"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.email_webhook_events.name}\" AND metric.labels.kind=\"complaint\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  # Permanent non-delivery: hard bounces, and `failed` (the provider gave up or suppressed the
  # address). Beta volume is a few hundred messages a day, so 5 in an hour is far above the
  # 1-2% a clean list produces: usually a mistyped batch of contact addresses or a domain
  # problem. Soft bounces are transient and are not counted.
  conditions {
    display_name = "5 or more hard bounces or failed deliveries in an hour"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.email_webhook_events.name}\" AND metric.labels.kind=monitoring.regex.full_match(\"(hard_bounce|failed)\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 4
      duration        = "0s"
      aggregations {
        alignment_period     = "3600s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.notify_channels

  alert_strategy {
    auto_close = "86400s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "A spam complaint, or many hard bounces / failed deliveries in an hour, reported by the e-mail providers. Usually a mass-invited list: see docs/DEPLOYMENT.md §9 'Bounce or complaint spike' and `cli.admin status` (bounces_24h, complaints_24h). ${local.doc}"
  }

  user_labels = merge(var.labels, { tier = "notify" })
}

resource "google_monitoring_alert_policy" "maintenance" {
  project      = var.project_id
  display_name = "${local.p} notify: retention job failing or not running"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "afterme-maintenance failed"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${var.maintenance_job_name}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result=\"failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period     = "900s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.labels.job_name"]
      }
      trigger {
        count = 1
      }
    }
  }

  conditions {
    display_name = "no execution of afterme-maintenance for 60 minutes"
    condition_absent {
      filter   = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${var.maintenance_job_name}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\""
      duration = "3600s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.labels.job_name"]
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.notify_channels

  alert_strategy {
    auto_close = "86400s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The retention job (account deletions, data retention) failed or has not run for an hour. Nothing safety-relevant waits on it, but deletion promises do. Read `maintenance.failed` in the logs (error class only); a permission error means a missing grant (migration 0007+). ${local.doc}"
  }

  user_labels = merge(var.labels, { tier = "notify" })
}

resource "google_monitoring_alert_policy" "certificate" {
  project      = var.project_id
  display_name = "${local.p} notify: TLS certificate expires in under 21 days"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "days until the certificate expires"
    condition_threshold {
      filter          = "resource.type=\"uptime_url\" AND metric.type=\"monitoring.googleapis.com/uptime_check/time_until_ssl_cert_expires\" AND metric.labels.check_id=\"${google_monitoring_uptime_check_config.probe.uptime_check_id}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 21
      duration        = "0s"
      aggregations {
        alignment_period     = "1200s"
        per_series_aligner   = "ALIGN_MIN"
        cross_series_reducer = "REDUCE_MIN"
        group_by_fields      = ["resource.label.*"]
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.notify_channels

  alert_strategy {
    auto_close = "86400s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The managed certificate should renew itself; if it is under 21 days it did not. Check the certificate status in Network services > Load balancing, and that the A records still point at the load balancer with the proxy OFF. ${local.doc}"
  }

  user_labels = merge(var.labels, { tier = "notify" })
}
