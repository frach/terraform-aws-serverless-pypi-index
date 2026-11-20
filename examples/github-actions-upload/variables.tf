variable "github_repository" {
  description = "Repository allowed to publish packages, as owner/name"
  type        = string
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. Set to false if the account already has one"
  type        = bool
  default     = true
}
