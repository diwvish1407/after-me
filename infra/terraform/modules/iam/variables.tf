variable "project_id" {
  type = string
}

variable "fcm_project_id" {
  description = "Firebase project whose Cloud Messaging the worker may send through (the same project as project_id when the Firebase project is this one)."
  type        = string
}

variable "name_prefix" {
  type    = string
  default = "afterme"
}

variable "github_repository" {
  description = "owner/name of the GitHub repository that may deploy (exact case)."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like owner/name."
  }
}

variable "github_repository_id" {
  description = "Numeric repository id (gh api repos/OWNER/NAME --jq .id). Required: a deleted-and-recreated repository of the same name must not inherit access."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be the numeric repository id (gh api repos/OWNER/NAME --jq .id)."
  }
}

variable "github_environment" {
  description = "GitHub Environment the deploy job must run in: staging or production. Its deployment branch/tag rules and reviewers are part of the gate (infra/README.md)."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.github_environment)
    error_message = "github_environment must be staging or production."
  }
}

variable "allow_release_tags" {
  description = "Also accept workflow runs triggered by tags v* (staging). prod: false."
  type        = bool
  default     = false
}
