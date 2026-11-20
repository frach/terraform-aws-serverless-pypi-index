output "cloudfront_pypi_index_url" {
  value       = module.cloudfront.cloudfront_distribution_domain_name
  description = "The domain name of the CloudFront distribution"
}

output "index_url" {
  value       = "https://${length(var.cloudfront_aliases) > 0 ? var.cloudfront_aliases[0] : module.cloudfront.cloudfront_distribution_domain_name}/simple/"
  description = "The URL of the PEP 503 simple index, to pass to pip/uv as --index-url (uses the first custom domain when set)"
}

output "cloudfront_distribution_id" {
  value       = module.cloudfront.cloudfront_distribution_id
  description = "The ID of the CloudFront distribution (e.g. for /simple/* invalidations after uploads)"
}

output "cloudfront_distribution_arn" {
  value       = module.cloudfront.cloudfront_distribution_arn
  description = "The ARN of the CloudFront distribution"
}

output "s3_bucket_id" {
  value       = local.s3_bucket_id
  description = "The name of the S3 bucket"
}

output "s3_bucket_arn" {
  value       = local.s3_bucket_arn
  description = "The ARN of the S3 bucket"
}

output "s3_bucket_domain_name" {
  value       = local.s3_bucket_regional_domain_name
  description = "The regional domain name of the S3 bucket"
}

output "s3_bucket_policy" {
  value       = var.s3_create_bucket ? module.s3_bucket.s3_bucket_policy : aws_s3_bucket_policy.s3_bucket_policy[0].policy
  description = "The bucket policy JSON attached by this module (merged with the optional deny policies for a created bucket)"
}

output "auth_secret_arn" {
  value       = try(aws_secretsmanager_secret.auth[0].arn, null)
  description = "The ARN of the Secrets Manager secret holding Basic Auth credentials (null when auth is disabled)"
}

output "auth_secret_name" {
  value       = try(aws_secretsmanager_secret.auth[0].name, null)
  description = "The name of the Secrets Manager secret holding Basic Auth credentials (null when auth is disabled)"
}
