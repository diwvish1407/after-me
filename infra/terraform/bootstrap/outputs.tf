output "state_bucket" {
  description = "Put this into envs/<env>/backend.hcl (bucket = ...)."
  value       = google_storage_bucket.state.name
}

output "backend_hcl" {
  description = "The content of envs/<env>/backend.hcl."
  value       = "bucket = \"${google_storage_bucket.state.name}\"\nprefix = \"afterme/state\"\n"
}
