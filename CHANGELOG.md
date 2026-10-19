# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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

* Minimum Terraform version lowered to `1.5.7` (the floor of the wrapped terraform-aws-modules; also OpenTofu compatible). Minimum AWS provider raised to `6.28.0` to match those modules.
