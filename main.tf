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
  # # Allow CloudFront to read objects via Origin Access Controls (OAC)
  # statement {
  #   sid       = "AllowCloudFrontServicePrincipalReadOnly"
  #   actions   = ["s3:GetObject"]
  #   effect    = "Allow"
  #   resources = ["${module.s3_bucket.s3_bucket_arn}/*"]

  #   principals {
  #     type        = "Service"
  #     identifiers = ["cloudfront.amazonaws.com"]
  #   }

  #   condition {
  #     test     = "StringEquals"
  #     variable = "AWS:SourceArn"
  #     values   = [module.cloudfront.cloudfront_distribution_arn]
  #   }
  # }

  # Allow updating objects for admin IAM user
  # statement {
  #   sid     = "AllowAdminUserFullAccess"
  #   effect  = "Allow"
  #   actions = ["s3:PutObject"]
  #   resources = [
  #     "${module.s3_bucket.s3_bucket_arn}/*",
  #     module.s3_bucket.s3_bucket_arn
  #   ]

  #   principals {
  #     type        = "AWS"
  #     identifiers = [var.admin_user_arn]
  #   }
  # }
}

resource "aws_s3_bucket_policy" "s3_bucket_policy" {
  bucket = module.s3_bucket.s3_bucket_id
  policy = data.aws_iam_policy_document.s3_bucket.json
}


#--------------------------#
#        CLOUDFRONT        #
#--------------------------#
# module "cloudfront" {
#   source  = "terraform-aws-modules/cloudfront/aws"
#   version = "5.0.0"

#   count = 0

#   aliases = var.cloudfront_config.aliases

#   comment             = "CloudFront distribution for PyPi index"
#   enabled             = true
#   staging             = false
#   http_version        = var.cloudfront_config.http_version
#   is_ipv6_enabled     = true
#   price_class         = var.cloudfront_config.price_class
#   retain_on_delete    = false
#   wait_for_deployment = false

#   continuous_deployment_policy_id = null
#   create_monitoring_subscription  = false

#   # Access control
#   create_origin_access_identity = false # This one is legacy one, prefer `create_origin_access_control`
#   create_origin_access_control  = true
#   origin_access_control = {
#     s3_website_oac = {
#       description      = "CloudFront access to S3"
#       origin_type      = "s3"
#       signing_behavior = "always"
#       signing_protocol = "sigv4"
#     }
#   }

#   create_vpc_origin = false

#   origin = {
#     s3_main_website = {
#       domain_name           = module.s3_bucket.s3_bucket_bucket_regional_domain_name
#       origin_access_control = "s3_website_oac"
#     }
#   }

#   default_cache_behavior = {
#     path_pattern           = "/*"
#     target_origin_id       = "s3_main_website"
#     viewer_protocol_policy = "redirect-to-https"

#     allowed_methods = ["GET", "HEAD", "OPTIONS"]
#     cached_methods  = ["GET", "HEAD"]

#     # Using Cache/ResponseHeaders/OriginRequest policies is not allowed together with `compress` and `query_string` settings
#     compress     = true
#     query_string = true

#     # Cache TTL
#     min_ttl     = var.cloudfront_config.cache_ttls.min
#     default_ttl = var.cloudfront_config.cache_ttls.default
#     max_ttl     = var.cloudfront_config.cache_ttls.max

#     # Forwarding config
#     use_forwarded_values = true
#     headers              = ["User-Agent"]
#     query_string         = false
#     cookies_forward      = "none"

#     # Lambda@Edge / CloudFront Functions
#     lambda_function_association = []
#     function_association = {
#       "viewer-request" = {
#         function_arn = aws_cloudfront_function.website_index.arn
#       }
#     }
#   }

#   ordered_cache_behavior = []

#   viewer_certificate = {
#     cloudfront_default_certificate = false
#     acm_certificate_arn            = module.website_acm.acm_certificate_arn
#     ssl_support_method             = "sni-only"
#   }

#   # custom_error_response = [{
#   #   error_code         = 404
#   #   response_code      = 404
#   #   response_page_path = "/errors/404.html"
#   #   }, {
#   #   error_code         = 403
#   #   response_code      = 403
#   #   response_page_path = "/errors/403.html"
#   # }]

#   geo_restriction = {
#     restriction_type = "none"
#   }
# }
