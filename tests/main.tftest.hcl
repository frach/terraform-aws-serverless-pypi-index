# Plan-only unit tests with mocked providers: no AWS credentials or resources needed.
# Run with `make tf-test` (requires Terraform >= 1.7).

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "eu-central-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  # OpenTofu fills computed attributes with random strings, so ARNs that the provider validates need real-looking values
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/serverless-pypi-index-edge-router" }
  }
  mock_resource "aws_lambda_function" {
    defaults = {
      arn           = "arn:aws:lambda:us-east-1:123456789012:function:serverless-pypi-index-edge-router"
      qualified_arn = "arn:aws:lambda:us-east-1:123456789012:function:serverless-pypi-index-edge-router:1"
    }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:eu-central-1:123456789012:secret:serverless-pypi-index-credentials-abc" }
  }
  mock_resource "aws_lambda_function_url" {
    defaults = { function_url = "https://abc123.lambda-url.eu-central-1.on.aws/" }
  }
  mock_resource "aws_ssm_parameter" {
    defaults = { arn = "arn:aws:ssm:eu-central-1:123456789012:parameter/serverless-pypi-index/cloudfront-distribution-id" }
  }
  mock_data "aws_s3_bucket" {
    defaults = {
      id                          = "existing-bucket"
      arn                         = "arn:aws:s3:::existing-bucket"
      bucket_regional_domain_name = "existing-bucket.s3.eu-central-1.amazonaws.com"
    }
  }
}

run "defaults" {
  command = plan

  assert {
    condition     = aws_lambda_function.edge.function_name == "serverless-pypi-index-edge-router"
    error_message = "Default resource names must stay unchanged for existing deployments."
  }

  assert {
    condition     = aws_lambda_function.edge.region == "us-east-1"
    error_message = "Lambda@Edge must be deployed in us-east-1."
  }

  assert {
    condition     = length(aws_secretsmanager_secret.auth) == 0 && length(aws_route53_record.alias) == 0 && length(aws_s3_bucket_policy.s3_bucket_policy) == 0 && length(aws_lambda_function.upload) == 0 && output.upload_url == null
    error_message = "Optional resources must not be created by default."
  }

  assert {
    condition     = aws_cloudwatch_log_group.lambda_edge.retention_in_days == 30
    error_message = "The Lambda@Edge log group must have a finite retention by default."
  }

  assert {
    condition     = length(data.aws_cloudfront_response_headers_policy.security_headers) == 1
    error_message = "The managed security headers policy must be used by default."
  }
}

run "name_and_tags" {
  command = plan

  variables {
    name = "pypi-prod"
    tags = { env = "prod" }
  }

  assert {
    condition     = aws_lambda_function.edge.function_name == "pypi-prod-edge-router" && aws_iam_role.lambda_edge.name == "pypi-prod-edge-router" && aws_cloudfront_cache_policy.index.name == "pypi-prod-index"
    error_message = "Resource names must use the name input."
  }

  assert {
    condition     = aws_lambda_function.edge.tags["env"] == "prod" && aws_iam_role.lambda_edge.tags["env"] == "prod" && aws_cloudwatch_log_group.lambda_edge.tags["env"] == "prod"
    error_message = "Tags must be applied to every resource."
  }
}

run "auth_enabled" {
  command = plan

  variables {
    auth_enabled     = true
    auth_credentials = { ci = "secret" }
  }

  assert {
    condition     = length(aws_secretsmanager_secret.auth) == 1 && length(aws_secretsmanager_secret_version.auth) == 1
    error_message = "Auth must create the credentials secret and its version."
  }
}

run "auth_without_credentials" {
  command = plan

  variables {
    auth_enabled = true
  }

  assert {
    condition     = length(aws_secretsmanager_secret.auth) == 1 && length(aws_secretsmanager_secret_version.auth) == 0
    error_message = "Without credentials the secret must be left for out-of-band population."
  }
}

run "custom_domain" {
  command = plan

  variables {
    cloudfront_aliases             = ["pypi.example.com"]
    cloudfront_acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/abc"
    route53_zone_id                = "Z123"
  }

  assert {
    condition     = length(aws_route53_record.alias) == 2
    error_message = "A and AAAA records must be created for every alias."
  }

  assert {
    condition     = output.index_url == "https://pypi.example.com/simple/"
    error_message = "index_url must use the first custom domain."
  }
}

run "alias_requires_certificate" {
  command = plan

  variables {
    cloudfront_aliases = ["pypi.example.com"]
  }

  expect_failures = [data.aws_partition.current]
}

run "certificate_must_be_in_us_east_1" {
  command = plan

  variables {
    cloudfront_acm_certificate_arn = "arn:aws:acm:eu-central-1:123456789012:certificate/abc"
  }

  expect_failures = [var.cloudfront_acm_certificate_arn]
}

run "existing_bucket" {
  command = plan

  variables {
    s3_create_bucket = false
    s3_bucket_name   = "existing-bucket"
  }

  assert {
    condition     = length(aws_s3_bucket_policy.s3_bucket_policy) == 1 && output.s3_bucket_id == "existing-bucket"
    error_message = "An existing bucket must get the module's bucket policy."
  }
}

run "existing_bucket_requires_name" {
  command = plan

  variables {
    s3_create_bucket = false
  }

  expect_failures = [data.aws_s3_bucket.existing]
}

run "invalid_name" {
  command = plan

  variables {
    name = "not valid!"
  }

  expect_failures = [var.name]
}

run "upstream_must_be_https" {
  command = plan

  variables {
    upstream_index_url = "http://pypi.org/simple"
  }

  expect_failures = [var.upstream_index_url]
}

run "custom_response_headers_policy" {
  command = plan

  variables {
    cloudfront_response_headers_policy_id = "my-policy-id"
  }

  assert {
    condition     = length(data.aws_cloudfront_response_headers_policy.security_headers) == 0
    error_message = "A custom response headers policy must replace the managed one."
  }
}

run "cooldown_must_be_whole_days" {
  command = plan

  variables {
    upstream_enabled       = true
    upstream_cooldown_days = 1.5
  }

  expect_failures = [var.upstream_cooldown_days]
}

run "upload_enabled" {
  command = plan

  variables {
    upload_enabled                 = true
    upload_credentials             = { ci = "upload-secret" }
    cloudfront_aliases             = ["pypi.example.com"]
    cloudfront_acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/abc"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.upload) == 1 && length(aws_secretsmanager_secret_version.upload) == 1 && length(aws_secretsmanager_secret.auth) == 0
    error_message = "Uploads must get their own credentials secret, independent of read auth."
  }

  assert {
    condition     = aws_lambda_function.upload[0].function_name == "serverless-pypi-index-upload" && aws_lambda_function_url.upload[0].authorization_type == "NONE"
    error_message = "The upload function must be reachable through its function URL."
  }

  assert {
    condition     = aws_lambda_function.upload[0].environment[0].variables["DISTRIBUTION_ID_PARAMETER"] == aws_ssm_parameter.upload_distribution_id[0].name
    error_message = "The upload function must find the distribution ID for invalidations."
  }

  assert {
    condition     = output.upload_url == "https://pypi.example.com/upload/"
    error_message = "upload_url must point at /upload/ on the index host."
  }
}

run "upload_without_credentials" {
  command = plan

  variables {
    upload_enabled = true
  }

  assert {
    condition     = length(aws_secretsmanager_secret.upload) == 1 && length(aws_secretsmanager_secret_version.upload) == 0
    error_message = "Without credentials the upload secret must be left for out-of-band population."
  }
}
