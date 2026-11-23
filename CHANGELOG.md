# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changes

* Releases are `make release VERSION=x.y.z` and, after the merge, `make release-tag` (`scripts/release.sh`, CONTRIBUTING.md).

## [0.3.0] - 2026-11-23

### Features

* Upstream cooldown: `upstream_cooldown_days` hides pypi.org files uploaded less than N days ago, so a compromised or typo-squatted release can't be installed the moment it's published. `upstream_cooldown_exclude` lists packages that skip it. With the cooldown on, the edge function builds the upstream page itself from PEP 691 JSON and adds `#sha256=` hashes, `data-requires-python`, yanked and metadata attributes.

### Changes

* Straighter arrows in the architecture diagram.
* README examples use the Terraform Registry source `frach/serverless-pypi-index/aws`.
* Shorter, plainer README. Tests, e2e and release steps moved to CONTRIBUTING.md, pre-v0.1.0 upgrade steps to docs/upgrading.md.

## [0.2.0] - 2026-11-21

### Features

* `name` input: prefix of every resource name, so the module can be deployed more than once in the same AWS account (default `serverless-pypi-index`, so existing deployments keep their names).
* `tags` input, applied to every resource that supports tags.
* Custom domains: `cloudfront_aliases`, `cloudfront_acm_certificate_arn`, `cloudfront_minimum_protocol_version` and optional Route 53 alias records (`route53_zone_id`).
* New outputs: `index_url`, `cloudfront_distribution_id`, `cloudfront_distribution_arn`.
* Security headers on every response (HSTS, X-Content-Type-Options, X-Frame-Options, ...) via the managed `SecurityHeadersPolicy`, or your own policy with `cloudfront_response_headers_policy_id`.
* Optional WAF (`cloudfront_web_acl_id`) and CloudFront access logs (`cloudfront_logging_bucket`, `cloudfront_logging_prefix`).
* `log_retention_in_days` for the Lambda@Edge log group (default 30 days; it used to be kept forever).
* `uploader_policy_json` output: least-privilege IAM policy for a CI identity that uploads packages and invalidates the index.

### Documentation

* README: supply-chain safety section, concrete pip, uv and Poetry setup, roadmap with dependency cooldown, fewer buzzwords.

### Bug Fixes

* The S3 origin now actually uses the Origin Access Control. The `origin_access_control` attribute was silently ignored by the CloudFront module, so CloudFront couldn't read package files from the private bucket.
* The Origin Access Control is named after `name` (`<name>-s3`) instead of the fixed `s3_oac`, so a second deployment in the same AWS account no longer fails with `OriginAccessControlAlreadyExists`.
* An existing bucket (`s3_create_bucket = false`) now also gets the deny-insecure-transport statement when `s3_attach_deny_insecure_transport_policy` is true. The other `s3_attach_*` flags still apply only to a bucket created by the module.
* `cloudfront_logging_prefix` defaults to `<name>/`, so deployments sharing a log bucket don't mix their logs.
* GitHub Actions example: the package folder is derived correctly from sdists whose file name keeps dashes (`my-package-1.0.0.tar.gz`).
* `make e2e` tears the deployment down even when `terraform apply` fails half-way.
* No perpetual `minimum_protocol_version` diff with the default `*.cloudfront.net` certificate: the module sends `TLSv1` there, which AWS stores anyway. `cloudfront_minimum_protocol_version` applies only with `cloudfront_acm_certificate_arn`.

### Security

* CI pins `aquasecurity/trivy-action` to a commit SHA instead of a mutable tag.
* Index pages HTML-escape package and file names and URL-encode links, so object keys or crafted request paths can't inject markup.
* S3 errors are logged to CloudWatch instead of being returned to clients.

### Changes

* **BREAKING:** `cloudfront_use_acm_certificate` input removed (it had no effect). Use `cloudfront_acm_certificate_arn` instead.
* **BREAKING:** `s3_attach_deny_insecure_transport_policy` now defaults to `true`, so the bucket rejects non-HTTPS requests.

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

[Unreleased]: https://github.com/frach/terraform-aws-serverless-pypi-index/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/frach/terraform-aws-serverless-pypi-index/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/frach/terraform-aws-serverless-pypi-index/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/frach/terraform-aws-serverless-pypi-index/releases/tag/v0.1.0
