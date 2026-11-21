output "role_arn" {
  description = "Set as the AWS_ROLE_ARN repository variable"
  value       = aws_iam_role.uploader.arn
}

output "s3_bucket_id" {
  description = "Set as the PYPI_BUCKET repository variable"
  value       = module.pypi.s3_bucket_id
}

output "cloudfront_distribution_id" {
  description = "Set as the PYPI_DISTRIBUTION_ID repository variable"
  value       = module.pypi.cloudfront_distribution_id
}

output "index_url" {
  description = "Pass this to pip/uv as --index-url (with credentials)"
  value       = module.pypi.index_url
}
