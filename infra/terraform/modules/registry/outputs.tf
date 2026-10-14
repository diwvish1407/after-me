output "repository" {
  description = "Image path prefix: <region>-docker.pkg.dev/<project>/afterme"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.backend.repository_id}"
}
