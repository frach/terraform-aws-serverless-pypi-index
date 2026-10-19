data "aws_caller_identity" "current" {}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# Existing bucket used when `s3_create_bucket` is false. It must live in `aws_region`
data "aws_s3_bucket" "existing" {
  count = var.s3_create_bucket ? 0 : 1

  bucket = var.s3_bucket_name

  lifecycle {
    precondition {
      condition     = var.s3_bucket_name != null
      error_message = "s3_bucket_name must be set to an existing bucket name when s3_create_bucket is false."
    }
  }
}

locals {
  resources_name_prefix = "serverless-pypi-index"

  # Resolve the bucket regardless of whether this module created it
  s3_bucket_id                   = var.s3_create_bucket ? module.s3_bucket.s3_bucket_id : data.aws_s3_bucket.existing[0].id
  s3_bucket_arn                  = var.s3_create_bucket ? module.s3_bucket.s3_bucket_arn : data.aws_s3_bucket.existing[0].arn
  s3_bucket_regional_domain_name = var.s3_create_bucket ? module.s3_bucket.s3_bucket_bucket_regional_domain_name : data.aws_s3_bucket.existing[0].bucket_regional_domain_name

  # Viewer-request runs on every request (auth), origin-request on cache misses (index generation & upstream routing)
  lambda_function_association = {
    for event_type in compact(["origin-request", var.auth_enabled ? "viewer-request" : ""]) :
    event_type => { lambda_arn = module.lambda_function.lambda_function_qualified_arn }
  }
}


#---------------------------#
#         PROVIDERS         #
#---------------------------#
# Default provider for persistent resources (S3, Secrets Manager)
provider "aws" {
  region = var.aws_region
}

# Dedicated provider for Lambda@Edge (CloudFront strictly requires us-east-1)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}


#-----------------------------#
#             S 3             #
#-----------------------------#
module "s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.10.0"

  create_bucket = var.s3_create_bucket

  bucket = var.s3_bucket_name

  force_destroy       = var.s3_force_destroy
  acceleration_status = var.s3_acceleration_status
  request_payer       = var.s3_request_payer

  # Access and permissions control
  acl                                       = var.s3_acl
  attach_policy                             = var.s3_attach_policy
  attach_deny_insecure_transport_policy     = var.s3_attach_deny_insecure_transport_policy
  attach_require_latest_tls_policy          = var.s3_attach_require_latest_tls_policy
  attach_deny_incorrect_encryption_headers  = var.s3_attach_deny_incorrect_encryption_headers
  attach_deny_incorrect_kms_key_sse         = var.s3_attach_deny_incorrect_kms_key_sse
  attach_deny_unencrypted_object_uploads    = var.s3_attach_deny_unencrypted_object_uploads
  attach_deny_ssec_encrypted_object_uploads = var.s3_attach_deny_ssec_encrypted_object_uploads

  # S3 bucket-level Public Access Block configuration (by default now AWS has made this default as true for S3 bucket-level block public access)
  block_public_acls       = var.s3_block_public_acls
  block_public_policy     = var.s3_block_public_policy
  ignore_public_acls      = var.s3_ignore_public_acls
  restrict_public_buckets = var.s3_restrict_public_buckets

  # S3 Bucket Ownership Controls
  # https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls
  control_object_ownership = var.s3_control_object_ownership
  object_ownership         = var.s3_object_ownership

  versioning = var.s3_versioning
}


#---------------------------#
#       BUCKET POLICY       #
#---------------------------#
data "aws_iam_policy_document" "s3_bucket" {
  # Allow CloudFront to read objects via Origin Access Controls (OAC)
  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    actions   = ["s3:GetObject"]
    effect    = "Allow"
    resources = ["${local.s3_bucket_arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [module.cloudfront.cloudfront_distribution_arn]
    }
  }

  # Allow all S3 actions for current IAM user
  statement {
    sid     = "AllowAdminUserFullAccess"
    effect  = "Allow"
    actions = ["s3:*"]
    resources = [
      "${local.s3_bucket_arn}/*",
      local.s3_bucket_arn
    ]

    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "s3_bucket_policy" {
  # Attached to either the created bucket or the existing one. NOTE: this replaces any policy already on an existing bucket
  bucket = local.s3_bucket_id
  policy = data.aws_iam_policy_document.s3_bucket.json
}


#--------------------------#
#        CLOUDFRONT        #
#--------------------------#
module "cloudfront" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "6.4.0"

  create = true

  # aliases = var.cloudfront_config.aliases

  comment             = "CloudFront distribution for PyPi index"
  enabled             = var.cloudfront_enabled
  staging             = false
  http_version        = var.cloudfront_http_version
  is_ipv6_enabled     = true
  price_class         = var.cloudfront_price_class
  retain_on_delete    = false
  wait_for_deployment = false

  continuous_deployment_policy_id = null
  create_monitoring_subscription  = false

  # Access control
  origin_access_control = {
    s3_oac = {
      description      = "CloudFront access to S3"
      origin_type      = "s3"
      signing_behavior = "always"
      signing_protocol = "sigv4"
    }
  }

  # Origins
  origin = {
    s3_origin = {
      domain_name           = local.s3_bucket_regional_domain_name
      origin_access_control = "s3_oac" # Key from `origin_access_control` block
    }
  }
  vpc_origin = {}

  # Cache behaviors
  default_cache_behavior = {
    target_origin_id       = "s3_origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    # Cache key optimizations
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_optimized.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id

    # Cache TTL
    min_ttl     = var.cloudfront_ttl_min
    default_ttl = var.cloudfront_ttl_default
    max_ttl     = var.cloudfront_ttl_max

    # Lambda@Edge functions
    lambda_function_association = local.lambda_function_association
  }

  ordered_cache_behavior = []

  restrictions = {
    geo_restriction = {
      restriction_type = "none"
    }
  }

  viewer_certificate = {
    cloudfront_default_certificate = var.cloudfront_use_acm_certificate ? false : true
    # acm_certificate_arn            = module.website_acm.acm_certificate_arn
    # ssl_support_method             = "sni-only"
  }
}


#---------------------------#
#      AUTHENTICATION       #
#---------------------------#
# Basic Auth credentials as a JSON object of {"username": "password"} pairs
resource "aws_secretsmanager_secret" "auth" {
  count = var.auth_enabled ? 1 : 0

  name_prefix             = "${local.resources_name_prefix}-credentials-"
  description             = "Basic Auth credentials for the serverless PyPI index"
  recovery_window_in_days = var.auth_secret_recovery_window_in_days
}

# Only managed by Terraform when credentials are passed in. Otherwise populate the secret out-of-band
resource "aws_secretsmanager_secret_version" "auth" {
  count = var.auth_enabled && nonsensitive(length(var.auth_credentials)) > 0 ? 1 : 0

  secret_id     = aws_secretsmanager_secret.auth[0].id
  secret_string = jsonencode(var.auth_credentials)
}


#--------------------------#
#          LAMBDA          #
#--------------------------#
resource "local_file" "lambda_config" {
  filename = "${path.module}/src/config.json"
  content = jsonencode({
    aws_region         = var.aws_region
    bucket_name        = local.s3_bucket_id
    auth_enabled       = var.auth_enabled
    auth_secret_id     = var.auth_enabled ? aws_secretsmanager_secret.auth[0].arn : null
    auth_realm         = var.auth_realm
    auth_cache_ttl     = var.auth_cache_ttl
    upstream_enabled   = var.upstream_enabled
    upstream_index_url = var.upstream_index_url
  })
}

module "lambda_function" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 8.0"

  # Enforce deployment in us-east-1 (CloudFront global constraint for Edge computing)
  # Ensure you define this alias in your provider configuration block
  providers = {
    aws = aws.us_east_1
  }

  function_name = "${local.resources_name_prefix}-edge-router"
  description   = "Dynamic PEP 503 compliant HTML generator and optional basic authentication proxy"
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 5 # Maximum allowed for viewer-request triggers

  # Absolute architectural requirements for running lambda at the edge
  publish        = true
  lambda_at_edge = true
  create_package = true

  # Point directly to the directory. This guarantees index.py and config.json
  # sit together at the root of the compiled ZIP.
  source_path = [
    {
      path = "${path.module}/src"

      # Use patterns with native regex exclusion rules:
      patterns = [
        "!test_index\\.py",
        "!__pycache__/.*",
        "!.pytest_cache/.*"
      ]

      # Force a zip rebuilding sequence if config.json contents shift
      triggers = {
        index_sha  = filesha256("${path.module}/src/index.py")
        config_sha = sha256(local_file.lambda_config.content)
      }
    }
  ]

  # Inline IAM Policy granting explicit least-privilege cross-service permissions
  attach_policy_json = true
  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "AllowS3BucketListing"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = local.s3_bucket_arn
        },
        {
          Sid      = "AllowS3ArtifactRetrieval"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = "${local.s3_bucket_arn}/*"
        }
      ],
      var.auth_enabled ? [
        {
          Sid      = "AllowAuthCredentialsRetrieval"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = aws_secretsmanager_secret.auth[0].arn
        }
      ] : []
    )
  })
}
