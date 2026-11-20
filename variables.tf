variable "name" {
  description = "Name (prefix) of the resources created by this module. Must be unique per AWS account, so the module can be deployed more than once"
  type        = string
  default     = "serverless-pypi-index"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{1,52}$", var.name))
    error_message = "name must be 1-52 characters long and contain only letters, digits and hyphens."
  }
}

variable "tags" {
  description = "Tags added to every resource that supports them"
  type        = map(string)
  default     = {}
}


# CloudFront variables
variable "cloudfront_enabled" {
  description = "Whether to create CloudFront distribution or not"
  type        = bool
  default     = true
}

variable "cloudfront_http_version" {
  description = "HTTP version for CloudFront distribution"
  type        = string
  default     = "http2"
}

variable "cloudfront_price_class" {
  description = "Price class for CloudFront distribution"
  type        = string
  default     = "PriceClass_100"
}

variable "cloudfront_ttl_min" {
  description = "Minimum TTL (seconds) for /simple/ index pages in CloudFront. Package files use the managed CachingOptimized policy"
  type        = number
  default     = 0
}

variable "cloudfront_ttl_default" {
  description = "Default TTL (seconds) for /simple/ index pages in CloudFront. Newly uploaded files show up in the index after at most this long"
  type        = number
  default     = 300
}

variable "cloudfront_ttl_max" {
  description = "Maximum TTL (seconds) for /simple/ index pages in CloudFront"
  type        = number
  default     = 3600
}

variable "cloudfront_aliases" {
  description = "Custom domain names (CNAMEs) for the index, e.g. [\"pypi.example.com\"]. Requires cloudfront_acm_certificate_arn"
  type        = list(string)
  default     = []
}

variable "cloudfront_acm_certificate_arn" {
  description = "ARN of an ACM certificate in us-east-1 covering every name in cloudfront_aliases. When null, the default *.cloudfront.net certificate is used"
  type        = string
  default     = null

  validation {
    condition     = var.cloudfront_acm_certificate_arn == null || can(regex("^arn:[^:]+:acm:us-east-1:", var.cloudfront_acm_certificate_arn))
    error_message = "cloudfront_acm_certificate_arn must be an ACM certificate ARN in us-east-1."
  }
}

variable "cloudfront_minimum_protocol_version" {
  description = "Minimum TLS version for viewers. Only enforced with a custom certificate; the default *.cloudfront.net certificate always allows TLSv1"
  type        = string
  default     = "TLSv1.2_2025"
}

variable "cloudfront_response_headers_policy_id" {
  description = "ID of a CloudFront response headers policy for every behavior. When null, the managed SecurityHeadersPolicy (HSTS, X-Content-Type-Options, X-Frame-Options, ...) is used"
  type        = string
  default     = null
}

variable "cloudfront_web_acl_id" {
  description = "ARN of a WAFv2 web ACL (scope CLOUDFRONT, in us-east-1) to associate with the distribution, e.g. for rate limiting or IP allow-lists"
  type        = string
  default     = null
}

variable "cloudfront_logging_bucket" {
  description = "Domain name of an S3 bucket for CloudFront standard access logs (e.g. \"my-logs.s3.amazonaws.com\"). The bucket must have ACLs enabled. When null, access logging is disabled"
  type        = string
  default     = null
}

variable "cloudfront_logging_prefix" {
  description = "Prefix for CloudFront access log objects"
  type        = string
  default     = "serverless-pypi-index/"
}

variable "route53_zone_id" {
  description = "ID of a Route 53 hosted zone in which to create A/AAAA alias records for every name in cloudfront_aliases. When null, no DNS records are created"
  type        = string
  default     = null
}


# Logging variables
variable "log_retention_in_days" {
  description = "Retention of the Lambda@Edge log group in us-east-1. Log groups that Lambda@Edge creates in other regions are not managed by this module"
  type        = number
  default     = 30
}


# Authentication variables
variable "auth_enabled" {
  description = "Whether to protect the whole index (including package downloads) with HTTP Basic Authentication backed by AWS Secrets Manager"
  type        = bool
  default     = false
}

variable "auth_credentials" {
  description = "Map of username => password stored in the Secrets Manager secret. Values end up in Terraform state; leave empty to populate the secret out-of-band as a JSON object of username/password pairs"
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "auth_realm" {
  description = "Realm advertised in the WWW-Authenticate challenge"
  type        = string
  default     = "Private PyPI"

  validation {
    condition     = !can(regex("[\"\\\\]", var.auth_realm))
    error_message = "auth_realm must not contain double quotes or backslashes."
  }
}

variable "auth_cache_ttl" {
  description = "Number of seconds the Lambda@Edge function caches credentials in memory before re-reading the secret. Credential changes take up to this long to propagate"
  type        = number
  default     = 300
}

variable "auth_secret_recovery_window_in_days" {
  description = "Number of days Secrets Manager waits before deleting the credentials secret. 0 forces immediate deletion"
  type        = number
  default     = 7
}


# Upstream proxy variables
variable "upstream_enabled" {
  description = "Whether to proxy /simple/<package>/ requests to the upstream index when the package is not hosted in the S3 bucket. Locally hosted packages always take precedence"
  type        = bool
  default     = false
}

variable "upstream_index_url" {
  description = "HTTPS URL of the upstream PEP 503 simple index (e.g. https://pypi.org/simple)"
  type        = string
  default     = "https://pypi.org/simple"

  validation {
    condition     = can(regex("^https://[^/]+", var.upstream_index_url))
    error_message = "upstream_index_url must be an https:// URL."
  }
}


# S3 variables
variable "s3_create_bucket" {
  description = "Whether to create S3 bucket or not"
  type        = bool
  default     = true
}

variable "s3_bucket_name" {
  description = "The name of the bucket. If s3_create_bucket is false, this must be the name of an existing bucket in the provider's region to be used as the origin for CloudFront distribution. Its bucket policy is replaced by this module"
  type        = string
  default     = null
}

variable "s3_force_destroy" {
  description = "Flag to force destroy the bucket. When true, destroying the module deletes every package stored in it"
  type        = bool
  default     = false
}

variable "s3_acceleration_status" {
  description = "Acceleration status of the bucket"
  type        = string
  default     = "Suspended"
}

variable "s3_request_payer" {
  description = "Request payer for the bucket"
  type        = string
  default     = "BucketOwner"
}

variable "s3_acl" {
  description = "Access control list for the bucket"
  type        = string
  default     = "private"
}

variable "s3_admin_principal_arns" {
  description = "IAM principal ARNs granted full access (s3:*) to the bucket via the bucket policy. Usually unnecessary for same-account identities, whose IAM policies already grant access"
  type        = list(string)
  default     = []
}

variable "s3_attach_deny_insecure_transport_policy" {
  description = "Flag to attach a bucket policy that denies requests not made over HTTPS"
  type        = bool
  default     = true
}

variable "s3_attach_require_latest_tls_policy" {
  description = "Flag to attach require latest TLS policy"
  type        = bool
  default     = false
}

variable "s3_attach_deny_incorrect_encryption_headers" {
  description = "Flag to attach deny incorrect encryption headers policy"
  type        = bool
  default     = false
}

variable "s3_attach_deny_incorrect_kms_key_sse" {
  description = "Flag to attach deny incorrect KMS key SSE policy"
  type        = bool
  default     = false
}

variable "s3_attach_deny_unencrypted_object_uploads" {
  description = "Flag to attach deny unencrypted object uploads policy"
  type        = bool
  default     = false
}

variable "s3_attach_deny_ssec_encrypted_object_uploads" {
  description = "Flag to attach deny SSEC encrypted object uploads policy"
  type        = bool
  default     = false
}

variable "s3_block_public_acls" {
  description = "Flag to block public ACLs"
  type        = bool
  default     = true
}

variable "s3_block_public_policy" {
  description = "Flag to block public policy"
  type        = bool
  default     = true
}

variable "s3_ignore_public_acls" {
  description = "Flag to ignore public ACLs"
  type        = bool
  default     = true
}

variable "s3_restrict_public_buckets" {
  description = "Flag to restrict public buckets"
  type        = bool
  default     = true
}

variable "s3_control_object_ownership" {
  description = "Flag to control object ownership"
  type        = bool
  default     = true
}

variable "s3_object_ownership" {
  description = "Object ownership setting"
  type        = string
  default     = "BucketOwnerPreferred"
}

variable "s3_versioning" {
  description = "Versioning configuration for the bucket"
  type = object({
    status     = bool
    mfa_delete = bool
  })
  default = {
    status     = true
    mfa_delete = false
  }
}
