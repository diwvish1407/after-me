output "instance_name" {
  value = google_sql_database_instance.pg.name
}

output "connection_name" {
  description = "project:region:instance (Cloud SQL Auth Proxy, gcloud sql ...)."
  value       = google_sql_database_instance.pg.connection_name
}

output "private_ip" {
  description = "The host for the four database URLs."
  value       = google_sql_database_instance.pg.private_ip_address
}

output "database_id" {
  description = "project:instance, the resource label of the Cloud SQL metrics."
  value       = "${var.project_id}:${google_sql_database_instance.pg.name}"
}

output "max_connections" {
  value = var.max_connections
}
