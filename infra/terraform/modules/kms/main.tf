# Cloud KMS: the key-encryption key (KEK) that wraps every user's data-encryption key
# (docs/SECURITY.md §6.2). Software protection, AES-256-GCM, rotated every 90 days.
#
# prevent_destroy: destroying the key ring or key is impossible in Terraform. Cloud KMS never
# deletes a key ring, and a key version scheduled for destruction takes every instruction that
# was wrapped with it (losing every KEK makes all instruction content unreadable, by design).

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

resource "google_kms_key_ring" "afterme" {
  project  = var.project_id
  name     = "afterme"
  location = var.region

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key" "instruction_kek" {
  name     = "instruction-kek"
  key_ring = google_kms_key_ring.afterme.id
  purpose  = "ENCRYPT_DECRYPT"

  rotation_period = "7776000s" # 90 days

  # A scheduled version destruction can be cancelled for 30 days.
  destroy_scheduled_duration = "2592000s"

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }

  labels = var.labels

  lifecycle {
    prevent_destroy = true
  }
}

# The API's service account, on this key and nothing else. The worker, the maintenance job, the
# operator jobs and CI get no KMS permission at all (docs/SECURITY_REVIEW.md BD-5): the engine
# decides releases without ever being able to open one.
resource "google_kms_crypto_key_iam_member" "api" {
  crypto_key_id = google_kms_crypto_key.instruction_kek.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${var.api_service_account_email}"
}

# Decrypt and wrap calls are written to the Data Access audit log (SECURITY §16: "decrypt
# operations logged"). Metadata only: Cloud Audit Logs never record plaintext or key material.
resource "google_project_iam_audit_config" "kms" {
  project = var.project_id
  service = "cloudkms.googleapis.com"

  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}
