output "api_service_name" {
  value = google_cloud_run_v2_service.api.name
}

output "worker_pool_name" {
  value = google_cloud_run_v2_worker_pool.worker.name
}

output "migrate_job_name" {
  value = google_cloud_run_v2_job.migrate.name
}

output "maintenance_job_name" {
  value = google_cloud_run_v2_job.maintenance.name
}

output "cli_job_names" {
  value = sort(keys(google_cloud_run_v2_job.cli))
}

output "kms_job_name" {
  value = google_cloud_run_v2_job.kms.name
}

output "connections_peak" {
  description = "Database connections each role's processes can open at peak (api, worker)."
  value       = local.connections_peak
}
