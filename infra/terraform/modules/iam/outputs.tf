output "emails" {
  description = "Service account emails by key."
  value       = { for k, a in google_service_account.this : k => a.email }
}

output "names" {
  description = "Service account resource names by key (projects/.../serviceAccounts/...)."
  value       = { for k, a in google_service_account.this : k => a.name }
}

output "workload_identity_provider" {
  description = "Value for the google-github-actions/auth `workload_identity_provider` input."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "cicd_service_account" {
  value = google_service_account.this["cicd"].email
}

output "project_number" {
  value = data.google_project.this.number
}
