output "uptime_check_id" {
  description = "Id of the uptime check, for infra/scripts/set_probe_header.sh."
  value       = google_monitoring_uptime_check_config.probe.uptime_check_id
}

output "page_channel_ids" {
  value = local.page_channels
}

output "backup_check_job_name" {
  value = google_cloud_run_v2_job.backup_check.name
}
