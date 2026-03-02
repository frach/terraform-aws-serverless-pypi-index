provider "aws" {
  region = "eu-west-1"

  # Make it faster by skipping something
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_credentials_validation = true
}

module "complete" {
  source = "../.."

  # CloudFront configs
  cloudfront_ttl_min     = 0
  cloudfront_ttl_default = 1
  cloudfront_ttl_max     = 1000

  # S3 configs
  s3_create_bucket = true
  s3_bucket_name   = null # Let Terraform generate a random one

  s3_attach_deny_incorrect_encryption_headers  = false
  s3_attach_deny_incorrect_kms_key_sse         = false
  s3_attach_deny_insecure_transport_policy     = false
  s3_attach_deny_ssec_encrypted_object_uploads = false

  s3_acceleration_status      = "Suspended"
  s3_attach_policy            = false
  s3_block_public_acls        = true
  s3_block_public_policy      = true
  s3_control_object_ownership = true
  s3_force_destroy            = true
  s3_ignore_public_acls       = true
  s3_object_ownership         = "BucketOwnerPreferred"
  s3_restrict_public_buckets  = true
  s3_request_payer            = "BucketOwner"
  s3_versioning = {
    status     = true
    mfa_delete = false
  }
}


# output "test" {
#   value = module.complete
# }
