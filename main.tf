data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

locals {
  resources_name_prefix = "serverless-pypi-index"
  s3_bucket_arn = var.s3_create_bucket ? module.s3_bucket.s3_bucket_arn : "arn:${data.aws_partition.current.partition}:s3:::${var.s3_bucket_name}"
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
  # Attach newly created bucket policy to the S3 bucket, if `s3_attach_policy` is true. Otherwise, attach to the existing bucket specified by `s3_bucket_name`
  bucket = var.s3_create_bucket ? module.s3_bucket.s3_bucket_id : var.s3_bucket_name
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
      domain_name           = module.s3_bucket.s3_bucket_bucket_regional_domain_name
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
    lambda_function_association = {
      # Valid keys: viewer-request, origin-request, viewer-response, origin-response
      viewer-request = {
        lambda_arn   = module.lambda_function.lambda_function_qualified_arn
        include_body = true
      }
    }
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


#--------------------------#
#          LAMBDA          #
#--------------------------#
module "lambda_function" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 8.0"

  # Enforce deployment in us-east-1 (CloudFront global constraint for Edge computing)
  # Ensure you define this alias in your provider configuration block
  providers = {
    aws = aws.us_east_1
  }

  function_name = "${local.resources_name_prefix}-edge-router-v2"     # TODO change it back
  description   = "Dynamic PEP 503 compliant HTML generator and optional basic authentication proxy"
  handler       = "index.handler"
  runtime       = "python3.12"
  
  # Absolute architectural requirements for running lambda at the edge
  publish        = true
  lambda_at_edge = true
  create_package = true
  
  # ENHANCED TEMPLATING WORKFLOW: Injecting IaC outputs directly into Python source code
  source_path = [
    {
      path = "${path.module}/src"
      commands = [":zip"]

      # Variables seamlessly rendered on-the-fly before packaging into ZIP format
      template_dir = {
        vars = {
          secret_name = aws_secretsmanager_secret.pypi_creds.name
          bucket_name = var.s3_bucket_name   # Resolves to your exact deployed bucket string
          aws_region  = var.aws_region       # Forces connection back to your main region (e.g., eu-west-1)
        }
      }
    }
  ]

  # Inline IAM Policy granting explicit least-privilege cross-service permissions
  attach_policy_json = true
  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowSecretsManagerRead"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        # Pins runtime decryption permissions strictly to your deployed secret instance
        Resource = aws_secretsmanager_secret.pypi_creds.arn
      },
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
    ]
  })
}


#--------------------------#
#         SECRETS          #
#--------------------------#
resource "aws_secretsmanager_secret" "pypi_creds" {
  name        = "${local.resources_name_prefix}-credentials"
  description = "Basic authentication credentials for the private serverless PyPi index proxy"
  
  # During terraform destroy works immediately
  recovery_window_in_days = 0 
}
