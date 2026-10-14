output "key_name" {
  description = "AFTERME_KMS_KEY_NAME: the key's resource name (no version)."
  value       = google_kms_crypto_key.instruction_kek.id
}

output "key_ring_id" {
  value = google_kms_key_ring.afterme.id
}
