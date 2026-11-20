output "index_url" {
  description = "Pass this to pip/uv as --index-url"
  value       = module.pypi.index_url
}
