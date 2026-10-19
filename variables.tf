variable "aws_region" {
  type        = string
  default     = "eu-central-1"
  description = "The primary AWS region where the S3 storage bucket and Secrets Manager will be deployed."
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
  description = "Minimum TTL for CloudFront cache behavior"
  type        = number
  default     = 1 # Change it later to 3600 (1 hour) or more, but for testing purposes we want it to be low
}

variable "cloudfront_ttl_default" {
  description = "Default TTL for CloudFront cache behavior"
  type        = number
  default     = 1 # Change later to 3600 (1 hour) or more, but for testing purposes we want it to be low
}

variable "cloudfront_ttl_max" {
  description = "Maximum TTL for CloudFront cache behavior"
  type        = number
  default     = 1 # Change it later to 86400 # 24 hours
}

variable "cloudfront_use_acm_certificate" {
  description = "Whether to use ACM certificate for CloudFront distribution or not. If false, CloudFront default certificate will be used. Only false is supported for now"
  type        = bool
  default     = false
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
  description = "The name of the bucket. If s3_create_bucket is false, this must be the name of an existing bucket in aws_region to be used as the origin for CloudFront distribution. Its bucket policy is replaced by this module"
  type        = string
  default     = null
}

variable "s3_force_destroy" {
  description = "Flag to force destroy the bucket"
  type        = bool
  default     = true
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

variable "s3_attach_policy" {
  description = "Flag to attach policy"
  type        = bool
  default     = false
}

variable "s3_attach_deny_insecure_transport_policy" {
  description = "Flag to attach deny insecure transport policy"
  type        = bool
  default     = false
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
