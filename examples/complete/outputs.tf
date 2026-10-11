output "cloudfront_pypi_index_url" {
  description = "CloudFront domain serving the private PyPI index"
  value       = module.complete.cloudfront_pypi_index_url
}

output "s3_bucket_id" {
  description = "Name of the S3 bucket used as the package store"
  value       = module.complete.s3_bucket_id
}
