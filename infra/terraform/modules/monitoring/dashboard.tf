# One dashboard: check-ins per hour, incidents, delivery events, Hold history, worker lag, API
# and database health. Built from the log-based metrics above plus the platform metrics.

locals {
  dashboard_tiles = [
    {
      title  = "Check-ins per hour (POST /v1/checkins, 2xx)"
      filter = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.checkins_ok.name}\""
      align  = "ALIGN_SUM"
      period = "3600s"
      reduce = "REDUCE_SUM"
      group  = []
    },
    {
      title  = "Incidents opened per hour"
      filter = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.incident_opened.name}\""
      align  = "ALIGN_SUM"
      period = "3600s"
      reduce = "REDUCE_SUM"
      group  = []
    },
    {
      title  = "Hold history (entered / ended / window recorded)"
      filter = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.hold_events.name}\""
      align  = "ALIGN_SUM"
      period = "3600s"
      reduce = "REDUCE_SUM"
      group  = ["metric.label.event"]
    },
    {
      title  = "E-mail delivery events by kind (delivered, bounced, complained ...)"
      filter = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.email_webhook_events.name}\""
      align  = "ALIGN_SUM"
      period = "3600s"
      reduce = "REDUCE_SUM"
      group  = ["metric.label.kind"]
    },
    {
      title  = "Worker lag: seconds since the last heartbeat (max)"
      filter = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.status_value["worker_heartbeat_age_seconds"].name}\""
      align  = "ALIGN_PERCENTILE_99"
      period = "300s"
      reduce = "REDUCE_MAX"
      group  = []
    },
    {
      title  = "Worker lag: oldest due action / oldest queued message (p99, seconds)"
      filter = "metric.type=monitoring.regex.full_match(\"logging.googleapis.com/user/afterme_status_(oldest_due_action_age_seconds|oldest_queued_message_age_seconds)\")"
      align  = "ALIGN_PERCENTILE_99"
      period = "300s"
      reduce = "REDUCE_MAX"
      group  = ["metric.type"]
    },
    {
      title  = "Open incidents"
      filter = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.status_value["incidents_open"].name}\""
      align  = "ALIGN_PERCENTILE_99"
      period = "300s"
      reduce = "REDUCE_MAX"
      group  = []
    },
    {
      title  = "Status watchdog executions by result"
      filter = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${var.status_check_job_name}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\""
      align  = "ALIGN_DELTA"
      period = "600s"
      reduce = "REDUCE_SUM"
      group  = ["metric.label.result"]
    },
    {
      title  = "API requests by response class"
      filter = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${var.api_service_name}\" AND metric.type=\"run.googleapis.com/request_count\""
      align  = "ALIGN_RATE"
      period = "300s"
      reduce = "REDUCE_SUM"
      group  = ["metric.label.response_code_class"]
    },
    {
      title  = "Database CPU utilisation"
      filter = "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.database_id}\" AND metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\""
      align  = "ALIGN_MEAN"
      period = "300s"
      reduce = "REDUCE_MEAN"
      group  = []
    },
    {
      title  = "Database connections"
      filter = "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.database_id}\" AND metric.type=\"cloudsql.googleapis.com/database/postgresql/num_backends\""
      align  = "ALIGN_MAX"
      period = "300s"
      reduce = "REDUCE_SUM"
      group  = []
    },
  ]

  dashboard = {
    displayName = "${local.p} AfterMe operations"
    gridLayout = {
      columns = 2
      widgets = [for t in local.dashboard_tiles : {
        title = t.title
        xyChart = {
          dataSets = [{
            plotType = "LINE"
            timeSeriesQuery = {
              timeSeriesFilter = {
                filter = t.filter
                aggregation = {
                  alignmentPeriod    = t.period
                  perSeriesAligner   = t.align
                  crossSeriesReducer = t.reduce
                  groupByFields      = t.group
                }
              }
            }
          }]
          yAxis = { scale = "LINEAR" }
        }
      }]
    }
  }
}

resource "google_monitoring_dashboard" "ops" {
  project        = var.project_id
  dashboard_json = jsonencode(local.dashboard)
}
