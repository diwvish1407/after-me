output "ip_address" {
  description = "The static IPv4 address of the load balancer (the A record target)."
  value       = google_compute_global_address.ip.address
}

output "domains" {
  value = local.domains
}

output "certificate_name" {
  value = google_compute_managed_ssl_certificate.api.name
}

output "backend_service_name" {
  value = google_compute_backend_service.api.name
}

output "url_map_name" {
  value = google_compute_url_map.https.name
}
