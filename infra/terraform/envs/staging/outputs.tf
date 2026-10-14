output "dns_records" {
  value = module.stack.dns_records
}

output "load_balancer_ip" {
  value = module.stack.load_balancer_ip
}

output "database_private_ip" {
  value = module.stack.database_private_ip
}

output "database_connection_name" {
  value = module.stack.database_connection_name
}

output "database_instance_name" {
  value = module.stack.database_instance_name
}

output "kms_key_name" {
  value = module.stack.kms_key_name
}

output "artifact_registry" {
  value = module.stack.artifact_registry
}

output "workload_identity_provider" {
  value = module.stack.workload_identity_provider
}

output "cicd_service_account" {
  value = module.stack.cicd_service_account
}

output "project_number" {
  value = module.stack.project_number
}

output "secret_names" {
  value = module.stack.secret_names
}

output "uptime_check_id" {
  value = module.stack.uptime_check_id
}

output "admin_vm_name" {
  value = module.stack.admin_vm_name
}

output "service_account_emails" {
  value = module.stack.service_account_emails
}
