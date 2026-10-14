output "records" {
  description = "Cloudflare records to create (proxy off). Mail records come from Resend and Postmark: docs/INFRASTRUCTURE.md §9."
  value       = local.records
}

output "as_text" {
  description = "The same, one per line."
  value       = [for r in local.records : "${r.type}\t${r.name}\t${r.content}\t(proxy: ${r.proxy ? "ON" : "OFF"})"]
}
