output "service_account_email" {
  description = "Empty string while the VM is not enabled."
  value       = var.enabled ? google_service_account.vm[0].email : ""
}

output "instance_name" {
  value = var.enabled ? google_compute_instance.vm[0].name : ""
}
