output "dns_records" {
  description = "Create these in Cloudflare, proxy OFF."
  value       = var.deploy_services ? module.dns_records[0].as_text : []
}

output "load_balancer_ip" {
  value = var.deploy_services ? module.edge[0].ip_address : null
}

output "database_private_ip" {
  description = "Host of the four database URLs."
  value       = module.database.private_ip
}

output "database_connection_name" {
  value = module.database.connection_name
}

output "database_instance_name" {
  value = module.database.instance_name
}

output "kms_key_name" {
  value = module.kms.key_name
}

output "artifact_registry" {
  description = "Image path prefix."
  value       = module.registry.repository
}

output "workload_identity_provider" {
  description = "Repository variable GCP_WORKLOAD_IDENTITY_PROVIDER (GitHub Environment variable)."
  value       = module.iam.workload_identity_provider
}

output "cicd_service_account" {
  description = "Repository variable GCP_SERVICE_ACCOUNT."
  value       = module.iam.cicd_service_account
}

output "project_number" {
  value = module.iam.project_number
}

output "secret_names" {
  value = module.secrets.names
}

output "uptime_check_id" {
  value = var.deploy_services ? module.monitoring[0].uptime_check_id : null
}

output "admin_vm_name" {
  value = module.admin_vm.instance_name
}

output "service_account_emails" {
  value = module.iam.emails
}
