# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.1.0] - 2026-10-19

First tagged release. **BREAKING** items refer to changes since the untagged pre-release code; see "Upgrading from pre-release versions" in the README.

### Features

* Optional HTTP Basic Authentication enforced in a Lambda@Edge viewer-request trigger, with credentials stored in AWS Secrets Manager (`auth_enabled`, `auth_credentials`, `auth_realm`, `auth_cache_ttl`, `auth_secret_recovery_window_in_days`).
* Optional upstream proxy to pypi.org or any PEP 503 mirror for packages not hosted in S3 (`upstream_enabled`, `upstream_index_url`).
* Index pages are now generated in an origin-request trigger, so CloudFront caches them and the 40 KB viewer-response limit no longer applies.

### Bug Fixes

* S3 listing is paginated, so buckets with more than 1000 objects are fully indexed.
* Unknown packages return `404` instead of an empty page.
* The Lambda rebuild trigger now hashes the contents of `index.py` instead of its path.
* Using an existing bucket (`s3_create_bucket = false`) now works: the CloudFront origin, Lambda config and outputs resolve the bucket via a data source instead of the (empty) module outputs.

### Changes

* **BREAKING:** the module no longer configures `provider "aws"` blocks; it uses the caller's provider, and pins Lambda@Edge resources to `us-east-1` via the resource-level `region` argument. `aws_region` input removed.
* **BREAKING:** `s3_attach_policy` input removed. For a created bucket, the CloudFront access policy is passed into the S3 module, so it merges with the optional `s3_attach_deny_*` policies instead of fighting over the bucket policy.
* **BREAKING:** the bucket policy no longer grants `s3:*` to the identity running Terraform; use the new `s3_admin_principal_arns` input instead.
* **BREAKING:** `s3_force_destroy` now defaults to `false`.
* **BREAKING:** the `s3_bucket_policy` output now returns the attached policy JSON instead of the policy resource ID (which was just the bucket name).
* `cloudfront_ttl_*` now actually apply: `/simple/*` index pages get a dedicated cache policy (default 0/300/3600 s). The behavior TTLs were previously ignored because a cache policy was set, so index pages could be cached for 24 h.
* The origin-request trigger now runs only for `/simple` paths. Package downloads only pass through the auth trigger.
* The Lambda package is built with `archive_file` (index.py + generated config.json in memory) on plain `aws_lambda_function`/IAM resources, instead of `local_file` writing into the module directory. See the README for `terraform state mv` upgrade commands.
* Minimum Terraform version lowered to `1.5.7` (the floor of the wrapped terraform-aws-modules; also OpenTofu compatible). Minimum AWS provider raised to `6.28.0` to match those modules.

[Unreleased]: https://github.com/frach/terraform-aws-serverless-pypi-index/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/frach/terraform-aws-serverless-pypi-index/releases/tag/v0.1.0
