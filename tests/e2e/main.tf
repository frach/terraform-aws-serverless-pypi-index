# Root module used by scripts/e2e.sh to deploy the module from this checkout into a real AWS account.
# State is local (tests/e2e/terraform.tfstate) and ignored by git.

terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28.0"
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

module "pypi" {
  source = "../.."

  name = var.name

  auth_enabled                        = true
  auth_secret_recovery_window_in_days = 0
  upstream_enabled                    = true
  upstream_cooldown_days              = 7
  upstream_cooldown_exclude           = ["six"]
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
