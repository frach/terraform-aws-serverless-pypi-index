output "index_url" {
  description = "Pass this to pip/uv as --index-url (with credentials)"
  value       = module.pypi.index_url
}

output "s3_bucket_id" {
  description = "Upload packages here as <package-name>/<file>"
  value       = module.pypi.s3_bucket_id
}

output "auth_secret_name" {
  description = "Secrets Manager secret to populate with {\"username\": \"password\"} pairs"
  value       = module.pypi.auth_secret_name
}
