# Example root module — non-secret inputs are hardcoded in main.tf for clarity.

variable "ci_password" {
  description = "Basic Auth password for the `ci` user"
  type        = string
  sensitive   = true
}

variable "reader_password" {
  description = "Basic Auth password for the `reader` user"
  type        = string
  sensitive   = true
}
