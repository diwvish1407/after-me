output "network_id" {
  value = google_compute_network.vpc.id
}

output "network_name" {
  value = google_compute_network.vpc.name
}

output "run_subnet_name" {
  value = google_compute_subnetwork.run.name
}

output "run_subnet_id" {
  value = google_compute_subnetwork.run.id
}

output "private_services_connection" {
  description = "Depend on this before creating a private-IP Cloud SQL instance."
  value       = google_service_networking_connection.private_services.id
}
