# terraform-aws-serverless-pypi-index

[![CI](https://github.com/frach/terraform-aws-serverless-pypi-index/actions/workflows/ci.yml/badge.svg)](https://github.com/frach/terraform-aws-serverless-pypi-index/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/frach/terraform-aws-serverless-pypi-index)](https://github.com/frach/terraform-aws-serverless-pypi-index/releases)
[![License](https://img.shields.io/github/license/frach/terraform-aws-serverless-pypi-index)](LICENSE)

Terraform module for a private Python package index (PEP 503) on AWS. Packages are stored in S3 and served through CloudFront;
a Lambda@Edge function builds the `/simple/` pages from the bucket listing. It works with pip, uv and Poetry and has no
always-on compute.

## Features

- PEP 503 index generated from S3, cached in CloudFront.
- Optional HTTP Basic Auth on every request, credentials in Secrets Manager.
- Optional fallback to pypi.org (or another PEP 503 index) for packages that aren't in the bucket. A package with any file in
  the bucket is always served from the bucket, so a public package can't take over a private name.
- Optional cooldown that hides upstream files published less than N days ago.
- Optional uploads with `twine upload`, `uv publish` and `poetry publish`, with their own credentials. Published files can't
  be overwritten.
- Custom domain with ACM and Route 53, security response headers, optional WAF and access logs.
- Private, HTTPS-only bucket read through Origin Access Control. Works with an existing bucket.

## Usage

```hcl
provider "aws" {
  region = "eu-central-1" # S3 bucket and Secrets Manager
}

module "pypi" {
  source  = "frach/serverless-pypi-index/aws"
  version = "~> 0.3"

  auth_enabled     = true
  upstream_enabled = true
}
```

```bash
pip install --index-url "https://<user>:<password>@$(terraform output -raw cloudfront_pypi_index_url)/simple/" my-package
```

Requires Terraform >= 1.5.7 or OpenTofu, and AWS provider >= 6.28. The module doesn't configure providers. S3, Secrets Manager and IAM use the caller's default `aws` provider; the Lambda@Edge
function and its log group are pinned to `us-east-1` with the provider's per-resource `region` argument, so no alias is needed.

Every resource name starts with `name` (default `serverless-pypi-index`), so set a unique `name` to deploy the module more than
once in an account. `tags` are added to every resource that supports them.

## Architecture

![Architecture: pip calls CloudFront; Lambda@Edge checks Basic Auth against Secrets Manager and builds /simple/ pages from S3 or forwards to pypi.org; package files come from S3 through OAC](https://raw.githubusercontent.com/frach/terraform-aws-serverless-pypi-index/main/docs/architecture.svg)

1. With `auth_enabled = true`, a viewer-request function checks Basic Auth on every request, cache hits included.
   Credentials are read from Secrets Manager and cached in memory for `auth_cache_ttl` seconds.
2. `/simple/` pages are cached by CloudFront according to `cloudfront_ttl_min/default/max` (default 0 / 300 / 3600 s).
3. On a cache miss, an origin-request function lists the package's files in S3 and returns the PEP 503 page.
4. With `upstream_enabled = true`, packages with no files in S3 are forwarded to `upstream_index_url`. File links on upstream
   pages point to `files.pythonhosted.org`.
5. Package files are served from S3 through CloudFront and cached as immutable.

## Comparison with AWS CodeArtifact

| | This module | AWS CodeArtifact |
|---|---|---|
| Client auth | Static Basic Auth (`.netrc`, keyring, `pip.conf`) | IAM token valid for at most 12 h |
| AWS credentials on clients | Not needed | Needed on every laptop and CI job |
| Fallback to pypi.org | Yes, local packages take precedence | Yes, upstream repository |
| Upload | `twine upload`, `uv publish`, `poetry publish` or `aws s3 cp` | `twine upload` |

## Cost

Example: 5 GB of packages, 100k requests and 20 GB of downloads a month, with auth (us-east-1 list prices): S3 about $0.12,
Lambda@Edge about $0.10, Secrets Manager $0.40, CloudFront within the free tier, about **$0.60 a month** in total. Without
auth, Lambda@Edge only runs on index cache misses and no secret is created.

## Custom domain

```hcl
module "pypi" {
  source  = "frach/serverless-pypi-index/aws"
  version = "~> 0.3"

  cloudfront_aliases             = ["pypi.example.com"]
  cloudfront_acm_certificate_arn = aws_acm_certificate.pypi.arn # must be in us-east-1
  route53_zone_id                = data.aws_route53_zone.example.zone_id # optional
}
```

- The certificate must be in `us-east-1` and cover every alias. The module doesn't create it.
- Viewers need at least `cloudfront_minimum_protocol_version` (default `TLSv1.2_2025`).
- With `route53_zone_id`, the module creates `A` and `AAAA` alias records. Otherwise, add a `CNAME` to `cloudfront_pypi_index_url`.
- The `index_url` output uses the first alias.

## Authentication

```hcl
module "pypi" {
  source  = "frach/serverless-pypi-index/aws"
  version = "~> 0.3"

  auth_enabled = true
  auth_credentials = {
    ci     = var.ci_password
    reader = var.reader_password
  }
}
```

- Credentials are a JSON object `{"username": "password"}` in the secret named by the `auth_secret_name` output.
- `auth_credentials` values are stored in the Terraform state. To avoid that, leave it empty and set the secret yourself:
  `aws secretsmanager put-secret-value --secret-id <auth_secret_name> --secret-string '{"ci": "..."}'`.
- Changes take effect within `auth_cache_ttl` seconds (default 300).
- If the secret can't be read and nothing is cached, requests get `503`.

## Upstream fallback and cooldown

```hcl
module "pypi" {
  source  = "frach/serverless-pypi-index/aws"
  version = "~> 0.3"

  upstream_enabled          = true
  upstream_index_url        = "https://pypi.org/simple" # default
  upstream_cooldown_days    = 7
  upstream_cooldown_exclude = ["my-public-lib"]
}
```

- If any file of a package exists in S3, only the S3 files are listed and the upstream is not queried for that name.
- The root `/simple/` page lists only packages in S3.
- pip doesn't send your index credentials to `files.pythonhosted.org`.

With `upstream_cooldown_days` set, upstream files uploaded less than that many days ago are not listed, so clients resolve to
the previous release. Packages in `upstream_cooldown_exclude` and packages in S3 are not affected.

- The function builds the page from the upstream's PEP 691 JSON API, so the upstream must support PEP 691 and PEP 700 upload
  times (pypi.org does). Files without an upload time are hidden.
- Generated pages include `#sha256=` hashes, `data-requires-python` and yanked and metadata attributes.
- Pages are gzip-compressed to stay under the 1 MB Lambda@Edge response limit (`botocore` is about 0.75 MB compressed).
- A changed cooldown applies after `cloudfront_ttl_default` or an invalidation of `/simple/*`.

## Clients

Use the `index_url` output. The examples below replace pypi.org and assume `upstream_enabled = true`; without it, add the index
as an extra one (`extra-index-url`, `default = false`, `supplemental`).

pip (`pip.conf` or `PIP_INDEX_URL`), with credentials in `~/.netrc` or keyring:

```ini
[global]
index-url = https://pypi.example.com/simple/
```

uv (`pyproject.toml`), with `UV_INDEX_PRIVATE_USERNAME` and `UV_INDEX_PRIVATE_PASSWORD`:

```toml
[[tool.uv.index]]
name = "private"
url = "https://pypi.example.com/simple/"
default = true
```

Poetry:

```bash
poetry source add --priority=primary private https://pypi.example.com/simple/
poetry config http-basic.private <user> <password>
```

## Uploading packages

With `upload_enabled = true`, the index accepts uploads at the `upload_url` output (`https://<index host>/upload/`):

```hcl
module "pypi" {
  source  = "frach/serverless-pypi-index/aws"
  version = "~> 0.4"

  upload_enabled = true
  # Or leave it empty and put {"<user>": "<password>"} into the upload_secret_name secret yourself
  upload_credentials = { ci = var.upload_password }
}
```

```bash
twine upload --repository-url https://pypi.example.com/upload/ -u ci -p "$PASSWORD" dist/*
uv publish --publish-url https://pypi.example.com/upload/ -u ci -p "$PASSWORD"
poetry config repositories.private https://pypi.example.com/upload/
poetry publish -r private -u ci -p "$PASSWORD"
```

- Upload credentials are separate from the read credentials (`auth_credentials`), so pip users can't publish.
  `/upload/` doesn't ask for the read credentials.
- An existing file is never overwritten: a different file with the same name gets `409 File already exists`. Uploading the
  identical file again succeeds, so a re-run publish job doesn't fail.
- The file name must belong to the uploaded project, and the `sha256_digest`/`md5_digest` sent by the client must match.
- After an upload the function invalidates `/simple/` and the project's page, so the new file is listed right away.
- A request can't exceed the Lambda payload limit of 6 MB, which leaves about 4 MB per file. Upload bigger files with
  `aws s3 cp` as below.
- A WAF rule that limits request body size (e.g. `SizeRestrictions_BODY` in the AWS common rule set) blocks uploads
  unless `/upload/` is excluded from it.

Without `upload_enabled`, or for bigger files, upload files under the PEP 503 normalized project name (lowercase, runs of `-`, `_` and `.` replaced with `-`):

```bash
aws s3 cp dist/my_package-1.0.0-py3-none-any.whl "s3://$(terraform output -raw s3_bucket_id)/my-package/"
```

Don't overwrite published files, because package files are cached as immutable. New files appear in `/simple/` after
`cloudfront_ttl_default` seconds, or immediately after an invalidation of `/simple/*`. The `uploader_policy_json` output is an
IAM policy for a CI role that uploads and invalidates.

## Examples

- [basic](examples/basic): smallest deployment on the CloudFront domain.
- [private-with-auth](examples/private-with-auth): Basic Auth with credentials kept out of the state, plus the pypi.org fallback.
- [custom-domain](examples/custom-domain): custom domain with ACM and Route 53.
- [github-actions-upload](examples/github-actions-upload): publishing from GitHub Actions through an OIDC role.

Upgrading from a version before v0.1.0 needs a few `terraform state mv` commands: see [docs/upgrading.md](docs/upgrading.md).
Contributing, tests and releases: see [CONTRIBUTING.md](CONTRIBUTING.md).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.7 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | >= 2.4.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.28.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_archive"></a> [archive](#provider\_archive) | >= 2.4.0 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.28.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_cloudfront"></a> [cloudfront](#module\_cloudfront) | terraform-aws-modules/cloudfront/aws | 6.4.0 |
| <a name="module_s3_bucket"></a> [s3\_bucket](#module\_s3\_bucket) | terraform-aws-modules/s3-bucket/aws | 5.10.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudfront_cache_policy.index](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_cache_policy) | resource |
| [aws_cloudwatch_log_group.lambda_edge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.upload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_iam_role.lambda_edge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.upload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.lambda_edge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.lambda_edge_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.upload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_lambda_function.edge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_function.upload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_function_url.upload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function_url) | resource |
| [aws_lambda_permission.upload_invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_permission.upload_url](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_route53_record.alias](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_s3_bucket_policy.s3_bucket_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_secretsmanager_secret.auth](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret.upload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.auth](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_secretsmanager_secret_version.upload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_ssm_parameter.upload_distribution_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [archive_file.lambda](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [archive_file.upload](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_cloudfront_cache_policy.caching_disabled](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_cache_policy) | data source |
| [aws_cloudfront_cache_policy.caching_optimized](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_cache_policy) | data source |
| [aws_cloudfront_origin_request_policy.all_viewer_except_host](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_origin_request_policy) | data source |
| [aws_cloudfront_response_headers_policy.security_headers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_response_headers_policy) | data source |
| [aws_iam_policy_document.lambda_edge_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.s3_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_s3_bucket.existing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/s3_bucket) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_auth_cache_ttl"></a> [auth\_cache\_ttl](#input\_auth\_cache\_ttl) | Number of seconds the Lambda functions cache credentials (read and upload) in memory before re-reading the secret. Credential changes take up to this long to propagate | `number` | `300` | no |
| <a name="input_auth_credentials"></a> [auth\_credentials](#input\_auth\_credentials) | Map of username => password stored in the Secrets Manager secret. Values end up in Terraform state; leave empty to populate the secret out-of-band as a JSON object of username/password pairs | `map(string)` | `{}` | no |
| <a name="input_auth_enabled"></a> [auth\_enabled](#input\_auth\_enabled) | Whether to protect the whole index (including package downloads) with HTTP Basic Authentication backed by AWS Secrets Manager | `bool` | `false` | no |
| <a name="input_auth_realm"></a> [auth\_realm](#input\_auth\_realm) | Realm advertised in the WWW-Authenticate challenge | `string` | `"Private PyPI"` | no |
| <a name="input_auth_secret_recovery_window_in_days"></a> [auth\_secret\_recovery\_window\_in\_days](#input\_auth\_secret\_recovery\_window\_in\_days) | Number of days Secrets Manager waits before deleting a credentials secret (read or upload). 0 forces immediate deletion | `number` | `7` | no |
| <a name="input_cloudfront_acm_certificate_arn"></a> [cloudfront\_acm\_certificate\_arn](#input\_cloudfront\_acm\_certificate\_arn) | ARN of an ACM certificate in us-east-1 covering every name in cloudfront\_aliases. When null, the default *.cloudfront.net certificate is used | `string` | `null` | no |
| <a name="input_cloudfront_aliases"></a> [cloudfront\_aliases](#input\_cloudfront\_aliases) | Custom domain names (CNAMEs) for the index, e.g. ["pypi.example.com"]. Requires cloudfront\_acm\_certificate\_arn | `list(string)` | `[]` | no |
| <a name="input_cloudfront_enabled"></a> [cloudfront\_enabled](#input\_cloudfront\_enabled) | Whether to create CloudFront distribution or not | `bool` | `true` | no |
| <a name="input_cloudfront_http_version"></a> [cloudfront\_http\_version](#input\_cloudfront\_http\_version) | HTTP version for CloudFront distribution | `string` | `"http2"` | no |
| <a name="input_cloudfront_logging_bucket"></a> [cloudfront\_logging\_bucket](#input\_cloudfront\_logging\_bucket) | Domain name of an S3 bucket for CloudFront standard access logs (e.g. "my-logs.s3.amazonaws.com"). The bucket must have ACLs enabled. When null, access logging is disabled | `string` | `null` | no |
| <a name="input_cloudfront_logging_prefix"></a> [cloudfront\_logging\_prefix](#input\_cloudfront\_logging\_prefix) | Prefix for CloudFront access log objects. When null, "<name>/" is used | `string` | `null` | no |
| <a name="input_cloudfront_minimum_protocol_version"></a> [cloudfront\_minimum\_protocol\_version](#input\_cloudfront\_minimum\_protocol\_version) | Minimum TLS version for viewers. Only enforced with a custom certificate; the default *.cloudfront.net certificate always allows TLSv1 | `string` | `"TLSv1.2_2025"` | no |
| <a name="input_cloudfront_price_class"></a> [cloudfront\_price\_class](#input\_cloudfront\_price\_class) | Price class for CloudFront distribution | `string` | `"PriceClass_100"` | no |
| <a name="input_cloudfront_response_headers_policy_id"></a> [cloudfront\_response\_headers\_policy\_id](#input\_cloudfront\_response\_headers\_policy\_id) | ID of a CloudFront response headers policy for every behavior. When null, the managed SecurityHeadersPolicy (HSTS, X-Content-Type-Options, X-Frame-Options, ...) is used | `string` | `null` | no |
| <a name="input_cloudfront_ttl_default"></a> [cloudfront\_ttl\_default](#input\_cloudfront\_ttl\_default) | Default TTL (seconds) for /simple/ index pages in CloudFront. Newly uploaded files show up in the index after at most this long | `number` | `300` | no |
| <a name="input_cloudfront_ttl_max"></a> [cloudfront\_ttl\_max](#input\_cloudfront\_ttl\_max) | Maximum TTL (seconds) for /simple/ index pages in CloudFront | `number` | `3600` | no |
| <a name="input_cloudfront_ttl_min"></a> [cloudfront\_ttl\_min](#input\_cloudfront\_ttl\_min) | Minimum TTL (seconds) for /simple/ index pages in CloudFront. Package files use the managed CachingOptimized policy | `number` | `0` | no |
| <a name="input_cloudfront_web_acl_id"></a> [cloudfront\_web\_acl\_id](#input\_cloudfront\_web\_acl\_id) | ARN of a WAFv2 web ACL (scope CLOUDFRONT, in us-east-1) to associate with the distribution, e.g. for rate limiting or IP allow-lists | `string` | `null` | no |
| <a name="input_log_retention_in_days"></a> [log\_retention\_in\_days](#input\_log\_retention\_in\_days) | Retention of the Lambda@Edge log group in us-east-1. Log groups that Lambda@Edge creates in other regions are not managed by this module | `number` | `30` | no |
| <a name="input_name"></a> [name](#input\_name) | Name (prefix) of the resources created by this module. Must be unique per AWS account, so the module can be deployed more than once | `string` | `"serverless-pypi-index"` | no |
| <a name="input_route53_zone_id"></a> [route53\_zone\_id](#input\_route53\_zone\_id) | ID of a Route 53 hosted zone in which to create A/AAAA alias records for every name in cloudfront\_aliases. When null, no DNS records are created | `string` | `null` | no |
| <a name="input_s3_acceleration_status"></a> [s3\_acceleration\_status](#input\_s3\_acceleration\_status) | Acceleration status of the bucket | `string` | `"Suspended"` | no |
| <a name="input_s3_acl"></a> [s3\_acl](#input\_s3\_acl) | Access control list for the bucket | `string` | `"private"` | no |
| <a name="input_s3_admin_principal_arns"></a> [s3\_admin\_principal\_arns](#input\_s3\_admin\_principal\_arns) | IAM principal ARNs granted full access (s3:*) to the bucket via the bucket policy. Usually unnecessary for same-account identities, whose IAM policies already grant access | `list(string)` | `[]` | no |
| <a name="input_s3_attach_deny_incorrect_encryption_headers"></a> [s3\_attach\_deny\_incorrect\_encryption\_headers](#input\_s3\_attach\_deny\_incorrect\_encryption\_headers) | Flag to attach deny incorrect encryption headers policy | `bool` | `false` | no |
| <a name="input_s3_attach_deny_incorrect_kms_key_sse"></a> [s3\_attach\_deny\_incorrect\_kms\_key\_sse](#input\_s3\_attach\_deny\_incorrect\_kms\_key\_sse) | Flag to attach deny incorrect KMS key SSE policy | `bool` | `false` | no |
| <a name="input_s3_attach_deny_insecure_transport_policy"></a> [s3\_attach\_deny\_insecure\_transport\_policy](#input\_s3\_attach\_deny\_insecure\_transport\_policy) | Flag to attach a bucket policy that denies requests not made over HTTPS | `bool` | `true` | no |
| <a name="input_s3_attach_deny_ssec_encrypted_object_uploads"></a> [s3\_attach\_deny\_ssec\_encrypted\_object\_uploads](#input\_s3\_attach\_deny\_ssec\_encrypted\_object\_uploads) | Flag to attach deny SSEC encrypted object uploads policy | `bool` | `false` | no |
| <a name="input_s3_attach_deny_unencrypted_object_uploads"></a> [s3\_attach\_deny\_unencrypted\_object\_uploads](#input\_s3\_attach\_deny\_unencrypted\_object\_uploads) | Flag to attach deny unencrypted object uploads policy | `bool` | `false` | no |
| <a name="input_s3_attach_require_latest_tls_policy"></a> [s3\_attach\_require\_latest\_tls\_policy](#input\_s3\_attach\_require\_latest\_tls\_policy) | Flag to attach require latest TLS policy | `bool` | `false` | no |
| <a name="input_s3_block_public_acls"></a> [s3\_block\_public\_acls](#input\_s3\_block\_public\_acls) | Flag to block public ACLs | `bool` | `true` | no |
| <a name="input_s3_block_public_policy"></a> [s3\_block\_public\_policy](#input\_s3\_block\_public\_policy) | Flag to block public policy | `bool` | `true` | no |
| <a name="input_s3_bucket_name"></a> [s3\_bucket\_name](#input\_s3\_bucket\_name) | The name of the bucket. If s3\_create\_bucket is false, this must be the name of an existing bucket in the provider's region to be used as the origin for CloudFront distribution. Its bucket policy is replaced by this module | `string` | `null` | no |
| <a name="input_s3_control_object_ownership"></a> [s3\_control\_object\_ownership](#input\_s3\_control\_object\_ownership) | Flag to control object ownership | `bool` | `true` | no |
| <a name="input_s3_create_bucket"></a> [s3\_create\_bucket](#input\_s3\_create\_bucket) | Whether to create S3 bucket or not | `bool` | `true` | no |
| <a name="input_s3_force_destroy"></a> [s3\_force\_destroy](#input\_s3\_force\_destroy) | Flag to force destroy the bucket. When true, destroying the module deletes every package stored in it | `bool` | `false` | no |
| <a name="input_s3_ignore_public_acls"></a> [s3\_ignore\_public\_acls](#input\_s3\_ignore\_public\_acls) | Flag to ignore public ACLs | `bool` | `true` | no |
| <a name="input_s3_object_ownership"></a> [s3\_object\_ownership](#input\_s3\_object\_ownership) | Object ownership setting | `string` | `"BucketOwnerPreferred"` | no |
| <a name="input_s3_request_payer"></a> [s3\_request\_payer](#input\_s3\_request\_payer) | Request payer for the bucket | `string` | `"BucketOwner"` | no |
| <a name="input_s3_restrict_public_buckets"></a> [s3\_restrict\_public\_buckets](#input\_s3\_restrict\_public\_buckets) | Flag to restrict public buckets | `bool` | `true` | no |
| <a name="input_s3_versioning"></a> [s3\_versioning](#input\_s3\_versioning) | Versioning configuration for the bucket | <pre>object({<br/>    status     = bool<br/>    mfa_delete = bool<br/>  })</pre> | <pre>{<br/>  "mfa_delete": false,<br/>  "status": true<br/>}</pre> | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags added to every resource that supports them | `map(string)` | `{}` | no |
| <a name="input_upload_credentials"></a> [upload\_credentials](#input\_upload\_credentials) | Map of username => password allowed to upload, stored in its own Secrets Manager secret (separate from `auth_credentials`). Values end up in Terraform state; leave empty to populate the secret out-of-band as a JSON object of username/password pairs | `map(string)` | `{}` | no |
| <a name="input_upload_enabled"></a> [upload\_enabled](#input\_upload\_enabled) | Whether to accept uploads from twine, uv publish and poetry publish at <index host>/upload/. Uploads need their own credentials (`upload_credentials`), never overwrite an existing file and invalidate the cached index pages. Files are limited to about 4 MB by the Lambda request size | `bool` | `false` | no |
| <a name="input_upstream_cooldown_days"></a> [upstream\_cooldown\_days](#input\_upstream\_cooldown\_days) | Hide upstream files uploaded less than this many days ago, so a freshly published (possibly malicious) release can't be installed until it has been public for a while. 0 disables the cooldown. Requires an upstream that serves PEP 691 JSON with PEP 700 upload times (pypi.org does) | `number` | `0` | no |
| <a name="input_upstream_cooldown_exclude"></a> [upstream\_cooldown\_exclude](#input\_upstream\_cooldown\_exclude) | Upstream package names that skip the cooldown, e.g. your own public packages or ones you need to patch quickly. Names are compared after PEP 503 normalization | `list(string)` | `[]` | no |
| <a name="input_upstream_enabled"></a> [upstream\_enabled](#input\_upstream\_enabled) | Whether to proxy /simple/<package>/ requests to the upstream index when the package is not hosted in the S3 bucket. Locally hosted packages always take precedence | `bool` | `false` | no |
| <a name="input_upstream_index_url"></a> [upstream\_index\_url](#input\_upstream\_index\_url) | HTTPS URL of the upstream PEP 503 simple index (e.g. https://pypi.org/simple) | `string` | `"https://pypi.org/simple"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_auth_secret_arn"></a> [auth\_secret\_arn](#output\_auth\_secret\_arn) | The ARN of the Secrets Manager secret holding Basic Auth credentials (null when auth is disabled) |
| <a name="output_auth_secret_name"></a> [auth\_secret\_name](#output\_auth\_secret\_name) | The name of the Secrets Manager secret holding Basic Auth credentials (null when auth is disabled) |
| <a name="output_cloudfront_distribution_arn"></a> [cloudfront\_distribution\_arn](#output\_cloudfront\_distribution\_arn) | The ARN of the CloudFront distribution |
| <a name="output_cloudfront_distribution_id"></a> [cloudfront\_distribution\_id](#output\_cloudfront\_distribution\_id) | The ID of the CloudFront distribution (e.g. for /simple/* invalidations after uploads) |
| <a name="output_cloudfront_pypi_index_url"></a> [cloudfront\_pypi\_index\_url](#output\_cloudfront\_pypi\_index\_url) | The domain name of the CloudFront distribution |
| <a name="output_index_url"></a> [index\_url](#output\_index\_url) | The URL of the PEP 503 simple index, to pass to pip/uv as --index-url (uses the first custom domain when set) |
| <a name="output_s3_bucket_arn"></a> [s3\_bucket\_arn](#output\_s3\_bucket\_arn) | The ARN of the S3 bucket |
| <a name="output_s3_bucket_domain_name"></a> [s3\_bucket\_domain\_name](#output\_s3\_bucket\_domain\_name) | The regional domain name of the S3 bucket |
| <a name="output_s3_bucket_id"></a> [s3\_bucket\_id](#output\_s3\_bucket\_id) | The name of the S3 bucket |
| <a name="output_s3_bucket_policy"></a> [s3\_bucket\_policy](#output\_s3\_bucket\_policy) | The bucket policy JSON attached by this module (merged with the optional deny policies for a created bucket) |
| <a name="output_upload_secret_arn"></a> [upload\_secret\_arn](#output\_upload\_secret\_arn) | The ARN of the Secrets Manager secret holding upload credentials (null when uploads are disabled) |
| <a name="output_upload_secret_name"></a> [upload\_secret\_name](#output\_upload\_secret\_name) | The name of the Secrets Manager secret holding upload credentials (null when uploads are disabled) |
| <a name="output_upload_url"></a> [upload\_url](#output\_upload\_url) | The upload URL for twine (--repository-url), uv publish (--publish-url) and poetry (repositories.<name>.url); null when uploads are disabled |
| <a name="output_uploader_policy_json"></a> [uploader\_policy\_json](#output\_uploader\_policy\_json) | IAM policy JSON for a CI identity that uploads packages and invalidates /simple/* (attach it to e.g. a GitHub Actions OIDC role) |
<!-- END_TF_DOCS -->

## License

Apache 2.0, see [LICENSE](LICENSE).
