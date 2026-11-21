output "index_url" {
  description = "Pass this to pip/uv as --index-url"
  value       = module.pypi.index_url
}

output "s3_bucket_id" {
  description = "Upload packages here as <package-name>/<file>"
  value       = module.pypi.s3_bucket_id
}
