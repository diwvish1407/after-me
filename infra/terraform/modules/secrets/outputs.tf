output "secret_ids" {
  description = "Map of secret name to its full resource id (projects/<p>/secrets/<name>)."
  value       = { for k, s in google_secret_manager_secret.this : k => s.id }
}

output "names" {
  description = "The secret names, for scripts."
  value       = sort(keys(local.inventory))
}
