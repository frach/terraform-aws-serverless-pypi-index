# output "test" {
#   value       = module.cloudfront
#   description = "The ID of the CloudFront distribution"
# }

output "cloudfront_pypi_index_url" {
  value       = module.cloudfront.cloudfront_distribution_domain_name
  description = "The domain name of the CloudFront distribution"
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
  value       = aws_s3_bucket_policy.s3_bucket_policy.id
  description = "The ID of the S3 bucket policy"
}

output "auth_secret_arn" {
  value       = try(aws_secretsmanager_secret.auth[0].arn, null)
  description = "The ARN of the Secrets Manager secret holding Basic Auth credentials (null when auth is disabled)"
}

output "auth_secret_name" {
  value       = try(aws_secretsmanager_secret.auth[0].name, null)
  description = "The name of the Secrets Manager secret holding Basic Auth credentials (null when auth is disabled)"
}
