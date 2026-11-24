data "aws_caller_identity" "current" {}

data "aws_partition" "current" {
  lifecycle {
    precondition {
      condition     = length(var.cloudfront_aliases) == 0 || var.cloudfront_acm_certificate_arn != null
      error_message = "cloudfront_acm_certificate_arn must be set when cloudfront_aliases is not empty."
    }
  }
}

# Region of the caller's default provider: S3 bucket and Secrets Manager live here
data "aws_region" "current" {}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  count = var.upload_enabled ? 1 : 0

  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_response_headers_policy" "security_headers" {
  count = var.cloudfront_response_headers_policy_id == null ? 1 : 0

  name = "Managed-SecurityHeadersPolicy"
}

# Existing bucket used when `s3_create_bucket` is false. It must live in the provider's region
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
  resources_name_prefix = var.name
  lambda_function_name  = "${local.resources_name_prefix}-edge-router"
  upload_function_name  = "${local.resources_name_prefix}-upload"
  # A plain string, so the upload function doesn't depend on the distribution (which depends on the function URL)
  upload_distribution_id_parameter = "/${local.resources_name_prefix}/cloudfront-distribution-id"

  # Resolve the bucket regardless of whether this module created it
  s3_bucket_id                   = var.s3_create_bucket ? module.s3_bucket.s3_bucket_id : data.aws_s3_bucket.existing[0].id
  s3_bucket_arn                  = var.s3_create_bucket ? module.s3_bucket.s3_bucket_arn : data.aws_s3_bucket.existing[0].arn
  s3_bucket_regional_domain_name = var.s3_create_bucket ? module.s3_bucket.s3_bucket_bucket_regional_domain_name : data.aws_s3_bucket.existing[0].bucket_regional_domain_name

  response_headers_policy_id = coalesce(var.cloudfront_response_headers_policy_id, try(data.aws_cloudfront_response_headers_policy.security_headers[0].id, null))

  # Viewer-request runs on every request (auth), origin-request on index cache misses (index generation & upstream routing)
  lambda_files_association = {
    for event_type in(var.auth_enabled ? ["viewer-request"] : []) :
    event_type => { lambda_arn = aws_lambda_function.edge.qualified_arn }
  }
  lambda_index_association = {
    for event_type in compact(["origin-request", var.auth_enabled ? "viewer-request" : ""]) :
    event_type => { lambda_arn = aws_lambda_function.edge.qualified_arn }
  }
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

  # Access and permissions control. The module merges our policy with the optional deny policies, so there is a single policy writer
  acl                                       = var.s3_acl
  attach_policy                             = true
  policy                                    = data.aws_iam_policy_document.s3_bucket.json
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

  tags = var.tags
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

  # Optional explicit admin principals (same-account IAM identities usually don't need this)
  dynamic "statement" {
    for_each = length(var.s3_admin_principal_arns) > 0 ? [1] : []

    content {
      sid     = "AllowAdminPrincipalsFullAccess"
      effect  = "Allow"
      actions = ["s3:*"]
      resources = [
        "${local.s3_bucket_arn}/*",
        local.s3_bucket_arn
      ]

      principals {
        type        = "AWS"
        identifiers = var.s3_admin_principal_arns
      }
    }
  }

  # A created bucket gets this statement from the S3 module; an existing bucket only gets this policy
  dynamic "statement" {
    for_each = !var.s3_create_bucket && var.s3_attach_deny_insecure_transport_policy ? [1] : []

    content {
      sid     = "denyInsecureTransport"
      effect  = "Deny"
      actions = ["s3:*"]
      resources = [
        "${local.s3_bucket_arn}/*",
        local.s3_bucket_arn
      ]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "Bool"
        variable = "aws:SecureTransport"
        values   = ["false"]
      }
    }
  }
}

# Only for an existing bucket; a created bucket gets the policy through the S3 module.
# NOTE: this replaces any policy already attached to the existing bucket
resource "aws_s3_bucket_policy" "s3_bucket_policy" {
  count = var.s3_create_bucket ? 0 : 1

  bucket = local.s3_bucket_id
  policy = data.aws_iam_policy_document.s3_bucket.json
}


#--------------------------#
#        CLOUDFRONT        #
#--------------------------#
# Index pages change on upload, so they get their own (short) TTLs. Package files are immutable and use CachingOptimized
resource "aws_cloudfront_cache_policy" "index" {
  name        = "${local.resources_name_prefix}-index"
  comment     = "Cache policy for PEP 503 /simple/ index pages"
  min_ttl     = var.cloudfront_ttl_min
  default_ttl = var.cloudfront_ttl_default
  max_ttl     = var.cloudfront_ttl_max

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true

    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

module "cloudfront" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "6.4.0"

  create = true

  aliases = var.cloudfront_aliases

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

  web_acl_id = var.cloudfront_web_acl_id

  logging_config = var.cloudfront_logging_bucket != null ? {
    bucket          = var.cloudfront_logging_bucket
    prefix          = coalesce(var.cloudfront_logging_prefix, "${var.name}/")
    include_cookies = false
  } : null

  # Access control
  origin_access_control = {
    s3_oac = {
      name             = "${local.resources_name_prefix}-s3" # Must be unique per AWS account
      description      = "CloudFront access to S3"
      origin_type      = "s3"
      signing_behavior = "always"
      signing_protocol = "sigv4"
    }
  }

  # Origins
  origin = merge(
    {
      s3_origin = {
        domain_name               = local.s3_bucket_regional_domain_name
        origin_access_control_key = "s3_oac" # Key from `origin_access_control` block
      }
    },
    # The upload function checks its own credentials, so its URL needs no OAC (which would force clients to sign POST bodies)
    var.upload_enabled ? {
      upload_origin = {
        domain_name = trimsuffix(trimprefix(aws_lambda_function_url.upload[0].function_url, "https://"), "/")
        custom_origin_config = {
          http_port              = 80
          https_port             = 443
          origin_protocol_policy = "https-only"
          origin_read_timeout    = 30
        }
      }
    } : {}
  )
  vpc_origin = {}

  # Default behavior: package files served straight from S3
  default_cache_behavior = {
    target_origin_id       = "s3_origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    response_headers_policy_id = local.response_headers_policy_id

    # Lambda@Edge functions
    lambda_function_association = local.lambda_files_association
  }

  # Index pages (/simple and /simple/*): generated by Lambda@Edge, or proxied from upstream.
  # Uploads (/upload and /upload/*) skip the read auth and go to the upload function, which checks upload credentials
  ordered_cache_behavior = concat([
    for path_pattern in ["/simple", "/simple/*"] : {
      path_pattern           = path_pattern
      target_origin_id       = "s3_origin"
      viewer_protocol_policy = "redirect-to-https"

      allowed_methods = ["GET", "HEAD", "OPTIONS"]
      cached_methods  = ["GET", "HEAD"]

      cache_policy_id            = aws_cloudfront_cache_policy.index.id
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
      response_headers_policy_id = local.response_headers_policy_id

      lambda_function_association = local.lambda_index_association
    }
    ], [
    for path_pattern in(var.upload_enabled ? ["/upload", "/upload/*"] : []) : {
      path_pattern           = path_pattern
      target_origin_id       = "upload_origin"
      viewer_protocol_policy = "https-only"

      allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods  = ["GET", "HEAD"]

      cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled[0].id
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
      response_headers_policy_id = local.response_headers_policy_id
    }
  ])

  restrictions = {
    geo_restriction = {
      restriction_type = "none"
    }
  }

  # A custom domain needs an ACM certificate (in us-east-1) covering every alias.
  # AWS always stores TLSv1 for the default certificate, so sending anything else causes a perpetual diff
  viewer_certificate = {
    cloudfront_default_certificate = var.cloudfront_acm_certificate_arn == null
    acm_certificate_arn            = var.cloudfront_acm_certificate_arn
    ssl_support_method             = var.cloudfront_acm_certificate_arn != null ? "sni-only" : null
    minimum_protocol_version       = var.cloudfront_acm_certificate_arn != null ? var.cloudfront_minimum_protocol_version : "TLSv1"
  }

  tags = var.tags
}

# Optional DNS alias records (A and AAAA) for every custom domain
resource "aws_route53_record" "alias" {
  for_each = var.route53_zone_id != null ? {
    for pair in setproduct(var.cloudfront_aliases, ["A", "AAAA"]) : "${pair[0]}-${pair[1]}" => { name = pair[0], type = pair[1] }
  } : {}

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type

  alias {
    name                   = module.cloudfront.cloudfront_distribution_domain_name
    zone_id                = module.cloudfront.cloudfront_distribution_hosted_zone_id
    evaluate_target_health = false
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

  tags = var.tags
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
# Lambda@Edge has no environment variables, so the config ships as a sidecar file inside the package.
# Built in memory from sources, nothing is written into the module directory
data "archive_file" "lambda" {
  type        = "zip"
  output_path = "${path.root}/builds/${local.lambda_function_name}.zip"

  source {
    filename = "index.py"
    content  = file("${path.module}/src/index.py")
  }

  source {
    filename = "config.json"
    content = jsonencode({
      aws_region         = data.aws_region.current.region
      bucket_name        = local.s3_bucket_id
      auth_enabled       = var.auth_enabled
      auth_secret_id     = var.auth_enabled ? aws_secretsmanager_secret.auth[0].arn : null
      auth_realm         = var.auth_realm
      auth_cache_ttl     = var.auth_cache_ttl
      upstream_enabled   = var.upstream_enabled
      upstream_index_url = var.upstream_index_url

      upstream_cooldown_days    = var.upstream_cooldown_days
      upstream_cooldown_exclude = [for name in var.upstream_cooldown_exclude : replace(lower(name), "/[-_.]+/", "-")]
    })
  }
}

data "aws_iam_policy_document" "lambda_edge_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_edge" {
  name               = local.lambda_function_name
  assume_role_policy = data.aws_iam_policy_document.lambda_edge_assume_role.json

  tags = var.tags
}

# Lambda@Edge writes logs to /aws/lambda/us-east-1.<name> in whichever region served the request
resource "aws_iam_role_policy" "lambda_edge_logs" {
  name = "${local.lambda_function_name}-logs"
  role = aws_iam_role.lambda_edge.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/us-east-1.${local.lambda_function_name}:*",
          "arn:${data.aws_partition.current.partition}:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/us-east-1.${local.lambda_function_name}:*:*"
        ]
      }
    ]
  })
}

# Inline IAM Policy granting explicit least-privilege cross-service permissions
resource "aws_iam_role_policy" "lambda_edge" {
  name = local.lambda_function_name
  role = aws_iam_role.lambda_edge.name
  policy = jsonencode({
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

resource "aws_cloudwatch_log_group" "lambda_edge" {
  region = "us-east-1"

  name              = "/aws/lambda/us-east-1.${local.lambda_function_name}"
  retention_in_days = var.log_retention_in_days

  tags = var.tags
}

resource "aws_lambda_function" "edge" {
  # Lambda@Edge must be deployed in us-east-1 (CloudFront global constraint for Edge computing)
  region = "us-east-1"

  function_name = local.lambda_function_name
  description   = "Dynamic PEP 503 compliant HTML generator and optional basic authentication proxy"
  role          = aws_iam_role.lambda_edge.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 5 # Maximum allowed for viewer-request triggers

  # CloudFront associations require a published, numbered version
  publish = true

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  tags = var.tags

  depends_on = [aws_iam_role_policy.lambda_edge_logs, aws_cloudwatch_log_group.lambda_edge]
}


#--------------------------#
#          UPLOAD          #
#--------------------------#
# Upload credentials as a JSON object of {"username": "password"} pairs, separate from the read credentials
resource "aws_secretsmanager_secret" "upload" {
  count = var.upload_enabled ? 1 : 0

  name_prefix             = "${local.resources_name_prefix}-upload-credentials-"
  description             = "Upload credentials for the serverless PyPI index"
  recovery_window_in_days = var.auth_secret_recovery_window_in_days

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "upload" {
  count = var.upload_enabled && nonsensitive(length(var.upload_credentials)) > 0 ? 1 : 0

  secret_id     = aws_secretsmanager_secret.upload[0].id
  secret_string = jsonencode(var.upload_credentials)
}

# The upload function needs the distribution ID for invalidations, but the distribution needs the function URL.
# The parameter breaks that cycle: the function reads it at runtime
resource "aws_ssm_parameter" "upload_distribution_id" {
  count = var.upload_enabled ? 1 : 0

  name  = local.upload_distribution_id_parameter
  type  = "String"
  value = module.cloudfront.cloudfront_distribution_id

  tags = var.tags
}

data "archive_file" "upload" {
  count = var.upload_enabled ? 1 : 0

  type        = "zip"
  output_path = "${path.root}/builds/${local.upload_function_name}.zip"

  source {
    filename = "upload.py"
    content  = file("${path.module}/src/upload.py")
  }
}

resource "aws_iam_role" "upload" {
  count = var.upload_enabled ? 1 : 0

  name = local.upload_function_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "lambda.amazonaws.com" }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "upload" {
  count = var.upload_enabled ? 1 : 0

  name = local.upload_function_name
  role = aws_iam_role.upload[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.upload[0].arn}:*"
      },
      {
        Sid      = "ListPackages"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = local.s3_bucket_arn
      },
      {
        Sid      = "StorePackages"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${local.s3_bucket_arn}/*"
      },
      {
        Sid      = "ReadUploadCredentials"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.upload[0].arn
      },
      {
        Sid      = "ReadDistributionId"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.upload_distribution_id[0].arn
      },
      {
        Sid      = "InvalidateIndex"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = module.cloudfront.cloudfront_distribution_arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "upload" {
  count = var.upload_enabled ? 1 : 0

  name              = "/aws/lambda/${local.upload_function_name}"
  retention_in_days = var.log_retention_in_days

  tags = var.tags
}

resource "aws_lambda_function" "upload" {
  count = var.upload_enabled ? 1 : 0

  function_name = local.upload_function_name
  description   = "Accepts package uploads from twine, uv publish and poetry publish"
  role          = aws_iam_role.upload[0].arn
  handler       = "upload.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 512 # Holds the request body several times (base64, decoded, parsed)

  filename         = data.archive_file.upload[0].output_path
  source_code_hash = data.archive_file.upload[0].output_base64sha256

  environment {
    variables = {
      BUCKET_NAME               = local.s3_bucket_id
      CREDENTIALS_SECRET_ID     = aws_secretsmanager_secret.upload[0].arn
      CREDENTIALS_CACHE_TTL     = tostring(var.auth_cache_ttl)
      DISTRIBUTION_ID_PARAMETER = local.upload_distribution_id_parameter
      AUTH_REALM                = var.auth_realm
    }
  }

  tags = var.tags

  depends_on = [aws_cloudwatch_log_group.upload]
}

# Public URL; every request is checked against the upload credentials by the function itself
resource "aws_lambda_function_url" "upload" {
  count = var.upload_enabled ? 1 : 0

  function_name      = aws_lambda_function.upload[0].function_name
  authorization_type = "NONE"
}

# A function URL without IAM auth needs both permissions for anonymous callers
resource "aws_lambda_permission" "upload_url" {
  count = var.upload_enabled ? 1 : 0

  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.upload[0].function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "upload_invoke" {
  count = var.upload_enabled ? 1 : 0

  statement_id             = "AllowInvokeViaFunctionUrl"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.upload[0].function_name
  principal                = "*"
  invoked_via_function_url = true
}
