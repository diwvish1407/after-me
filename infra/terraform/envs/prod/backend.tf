# Remote state in the versioned bucket that bootstrap/ created. The bucket name is not written
# here; pass it at init time:  terraform init -backend-config=backend.hcl   (see infra/README.md)
terraform {
  backend "gcs" {}
}
