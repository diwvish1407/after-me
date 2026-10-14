# Cloud SQL for PostgreSQL 17. Private IP only, TLS required, no database user is created here:
# the roles and the database come from backend/scripts/provision_roles.sql (infra/README.md), and
# the built-in `postgres` administrator gets its password out of band, so no password ever reaches
# Terraform state.

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

resource "google_sql_database_instance" "pg" {
  project          = var.project_id
  name             = var.instance_name
  region           = var.region
  database_version = "POSTGRES_17"

  # Two layers: Terraform refuses to plan a destroy, and the API refuses the delete call.
  deletion_protection = var.deletion_protection

  settings {
    edition           = "ENTERPRISE"
    tier              = var.tier
    availability_type = var.high_availability ? "REGIONAL" : "ZONAL"

    disk_type             = "PD_SSD"
    disk_size             = var.disk_size_gb
    disk_autoresize       = true
    disk_autoresize_limit = var.disk_autoresize_limit_gb

    deletion_protection_enabled = var.deletion_protection

    backup_configuration {
      enabled                        = true
      start_time                     = var.backup_start_time_utc
      location                       = var.backup_location
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = var.pitr_days

      backup_retention_settings {
        retention_unit   = "COUNT"
        retained_backups = var.retained_backups
      }
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
      # TLS for every connection, no client certificate. The application's own check
      # (sslmode=require in the three database URLs) matches.
      ssl_mode = "ENCRYPTED_ONLY"
    }

    maintenance_window {
      day          = 7 # Sunday 21:00 UTC = Monday 02:30 IST
      hour         = 21
      update_track = "stable"
    }

    # --- logging: nothing that could carry a value -------------------------------------
    # provision_roles.sql runs `ALTER ROLE ... PASSWORD '...'`; `log_statement = ddl` would write
    # those passwords to Cloud Logging. Statements are never logged, and neither is a slow
    # query's text. pgaudit stays off (cloudsql.enable_pgaudit is not set).
    database_flags {
      name  = "log_statement"
      value = "none"
    }
    database_flags {
      name  = "log_min_duration_statement"
      value = "-1"
    }
    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }
    database_flags {
      name  = "max_connections"
      value = tostring(var.max_connections)
    }

    insights_config {
      query_insights_enabled = false
    }

    user_labels = var.labels
  }

  lifecycle {
    prevent_destroy = true
  }
}
