# Root module used by scripts/e2e.sh to deploy the module from this checkout into a real AWS account.
# State is local (tests/e2e/terraform.tfstate) and ignored by git.

terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
  }
}

provider "aws" {
  default_tags {
    tags = {
      Purpose = "serverless-pypi-index-e2e"
    }
  }
}

variable "name" {
  description = "Name prefix of the test deployment"
  type        = string
  default     = "pypi-e2e"
}

locals {
  cooldown_days = 7
}

module "pypi" {
  source = "../.."

  name = var.name

  auth_enabled                        = true
  auth_secret_recovery_window_in_days = 0
  upstream_enabled                    = true
  upstream_index_url                  = "${trimsuffix(aws_lambda_function_url.fake_upstream.function_url, "/")}/simple"
  upstream_cooldown_days              = local.cooldown_days
  upstream_cooldown_exclude           = ["six", "cw-fake-excluded"]
  upload_enabled                      = true

  # Short index TTL so a re-run sees fresh uploads
  cloudfront_ttl_default = 5

  s3_force_destroy = true
}

output "index_url" {
  value = module.pypi.index_url
}

output "s3_bucket_id" {
  value = module.pypi.s3_bucket_id
}

output "cloudfront_distribution_id" {
  value = module.pypi.cloudfront_distribution_id
}

output "auth_secret_name" {
  value = module.pypi.auth_secret_name
}

output "upload_url" {
  value = module.pypi.upload_url
}

output "upload_secret_name" {
  value = module.pypi.upload_secret_name
}

output "fake_upstream_url" {
  value = aws_lambda_function_url.fake_upstream.function_url
}

output "cooldown_days" {
  value = local.cooldown_days
}

# ------------------------------------------------------------------------------
# Fake upstream (fake_upstream/fake_upstream.py): pypi.org plus made-up projects
# with known upload times, so the cooldown is tested deterministically
# ------------------------------------------------------------------------------

data "archive_file" "fake_upstream" {
  type        = "zip"
  source_file = "${path.module}/fake_upstream/fake_upstream.py"
  output_path = "${path.module}/builds/fake-upstream.zip"
}

resource "aws_iam_role" "fake_upstream" {
  name = "${var.name}-fake-upstream"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "fake_upstream" {
  role       = aws_iam_role.fake_upstream.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "fake_upstream" {
  name              = "/aws/lambda/${var.name}-fake-upstream"
  retention_in_days = 1
}

resource "aws_lambda_function" "fake_upstream" {
  function_name    = "${var.name}-fake-upstream"
  role             = aws_iam_role.fake_upstream.arn
  runtime          = "python3.13"
  handler          = "fake_upstream.handler"
  filename         = data.archive_file.fake_upstream.output_path
  source_code_hash = data.archive_file.fake_upstream.output_base64sha256
  memory_size      = 512
  timeout          = 15

  environment {
    variables = {
      COOLDOWN_DAYS = tostring(local.cooldown_days)
    }
  }

  depends_on = [aws_iam_role_policy_attachment.fake_upstream, aws_cloudwatch_log_group.fake_upstream]
}

resource "aws_lambda_function_url" "fake_upstream" {
  function_name      = aws_lambda_function.fake_upstream.function_name
  authorization_type = "NONE"
}
