# AWS Serverless PyPI Index (Terraform Module)

A production-ready, highly cost-effective, and fully serverless private PyPI index hosted entirely on AWS using **Amazon S3**,
**Amazon CloudFront**, and **AWS Lambda** to deliver a secure, fast, and scalable private Python package registry at virtually
**\$0/month** on low-to-medium usage.

---

## 🏗️ Architecture Overview & Deep Dive

This module provisions an event-driven, edge-optimized private Python package registry compliant with the
**PEP 503 (Simple Repository API)** specification.

```text
          ┌───────────────────┐
          │    pip / poetry   │
          └─────────┬─────────┘
                    │
                    ▼  (HTTPS GET request, optional Basic Auth)
          ┌───────────────────┐       ┌─────────────────────┐
          │ Lambda@Edge       │ ◄───► │ AWS Secrets Manager │
          │ (viewer-request)  │       │ (cached credentials)│
          └─────────┬─────────┘       └─────────────────────┘
                    │  401 if credentials are missing or invalid
                    ▼
          ┌───────────────────┐
          │ Amazon CloudFront │  ◄─── [Cache Hit]
          └─────────┬─────────┘
                    │
                    ▼  (Cache Miss)
          ┌───────────────────┐
          │ Lambda@Edge       │  ◄─── [Loads config.json sidecar]
          │ (origin-request)  │
          └────┬─────────┬────┘
               │         │  package not in S3 (upstream enabled)
               ▼         ▼
     ┌─────────────┐  ┌──────────────────────┐
     │  Amazon S3  │  │ pypi.org/simple (or  │
     │ flat layout │  │ any PEP 503 mirror)  │
     └─────────────┘  └──────────────────────┘
```

### 📡 Request Lifecycle & Data Flow
1. **Edge Authentication** *(optional)*: When `auth_enabled = true`, a **viewer-request** trigger validates HTTP Basic Auth on every request, cache hits included, against credentials in **AWS Secrets Manager**. Credentials are cached in memory for `auth_cache_ttl` seconds.
2. **Sub-Millisecond Caching Layer**: CloudFront returns cached metadata instantly.
3. **Decoupled Serverless Processing**: Cache misses trigger the **origin-request** function, reading an isolated `config.json` sidecar and querying S3 via `list_objects_v2`.
4. **PEP 503 On-The-Fly Generation**: Lambda normalizes S3 keys into a lightweight HTML index string.
5. **Upstream Proxy** *(optional)*: When `upstream_enabled = true` and a package has **no files in S3**, the request is re-routed to `upstream_index_url` (default `https://pypi.org/simple`). CloudFront then fetches and caches the upstream page. File links on that page point straight at `files.pythonhosted.org`.
6. **Direct Asset Passthrough**: Binary wheel requests pass securely and directly from S3 through CloudFront.

### ⚙️ DevOps & Security Optimizations
- **Deterministic Packaging**: The Lambda zip is built in memory from `index.py` plus a generated `config.json`. Nothing is written into the module directory, and the function only redeploys when the zip hash changes.
- **Flat Layout Storage Pattern**: Stores binaries under a clean `package_name/artifact_name.whl` key format.

---

## 🚀 Key Features
- **True Serverless Architecture**: Scale-to-zero model with no idle infrastructure costs.
- **PEP 503 Simple API Compliant**: Works seamlessly with `pip`, `poetry`, `uv`, and `twine`.
- **High Performance at Edge**: Global low latency via CloudFront.
- **Basic Authentication**: Optional, enforced at the edge, credentials in Secrets Manager.
- **Upstream Proxy**: Optional PyPI fallback, so one index URL serves both private and public packages.

---

## 🛠️ Usage

The module doesn't configure providers. It uses the caller's default `aws` provider for S3, Secrets Manager and IAM. The Lambda@Edge function and its log group are pinned to `us-east-1` with the AWS provider's per-resource `region` argument, so no provider alias is needed.

```hcl
provider "aws" {
  region = "eu-central-1" # S3 bucket and Secrets Manager live here
}

module "pypi" {
  source = "git::https://github.com/frach/terraform-aws-serverless-pypi-index.git?ref=v0.1.0"
}
```

**Caching:** `/simple/` index pages use a dedicated cache policy driven by `cloudfront_ttl_min/default/max` (default 0 / 300 / 3600 s). A newly uploaded file shows up in the index after at most `cloudfront_ttl_default` seconds, or sooner with a CloudFront invalidation of `/simple/*`. Package files are immutable and use the managed `CachingOptimized` policy.

---

## 🔐 Authentication

```hcl
module "pypi" {
  source = "git::https://github.com/frach/terraform-aws-serverless-pypi-index.git?ref=v0.1.0"

  auth_enabled = true
  auth_credentials = {
    ci     = var.ci_password
    reader = var.reader_password
  }
}
```

* Credentials are stored as a JSON object `{"username": "password", ...}` in the secret exposed by the `auth_secret_name` output.
* `auth_credentials` values end up in the Terraform state. To keep them out, leave `auth_credentials` empty and populate the secret yourself:
  ```bash
  aws secretsmanager put-secret-value --secret-id <auth_secret_name> \
    --secret-string '{"ci": "s3cr3t"}'
  ```
* Credential changes propagate within `auth_cache_ttl` seconds (default 300).
* If the secret can't be read and nothing is cached, requests get `503` (fail closed).
* Client usage: `pip install --index-url https://<user>:<password>@<cloudfront-domain>/simple/ <package>`. Or use a `~/.netrc` / keyring entry for the CloudFront domain.

---

## 🌐 Upstream Proxy (pypi.org)

```hcl
module "pypi" {
  source = "git::https://github.com/frach/terraform-aws-serverless-pypi-index.git?ref=v0.1.0"

  upstream_enabled   = true
  upstream_index_url = "https://pypi.org/simple" # or any HTTPS PEP 503 mirror
}
```

* **Local first**: if *any* file of a package exists in S3, only the S3 files are listed. Upstream is never consulted for that name, so a public package can't hijack a private name (dependency confusion).
* `/simple/` (the root listing) only shows locally hosted packages.
* Upstream pages are cached in CloudFront like local index pages, according to the `cloudfront_ttl_*` settings.
* Package files of upstream projects are downloaded straight from `files.pythonhosted.org`. pip doesn't send your index credentials there.

---

## 📦 Python Ecosystem Client Integration

### 1. Installing Packages
* **Pip**: `pip install --index-url https://<cloudfront-domain>/simple/ <package>`
* **Poetry**: Set priority to `supplemental` pointing to the `/simple/` endpoint.
* **UV**: `uv pip install --index-url https://<cloudfront-domain>/simple/ <package>`

### 2. Uploading Packages
Upload via AWS CLI using the flat key convention:
```bash
aws s3 cp dist/package.whl s3://my-company-private-pypi-storage/package/package.whl
```

---

## ⬆️ Upgrading from pre-release versions

The Lambda moved from `terraform-aws-modules/lambda` to plain resources, and the bucket policy of a created bucket moved into the S3 module. Terraform can't `moved`-refactor across external module packages, so move the state by hand **before** the first apply. Otherwise the Lambda@Edge function gets recreated, and deleting the old one fails for hours while its replicas are being cleaned up.

```bash
M=module.pypi   # address of this module in your configuration
terraform state mv "$M.module.lambda_function.aws_lambda_function.this[0]"         "$M.aws_lambda_function.edge"
terraform state mv "$M.module.lambda_function.aws_iam_role.lambda[0]"               "$M.aws_iam_role.lambda_edge"
terraform state mv "$M.module.lambda_function.aws_iam_role_policy.additional_json[0]" "$M.aws_iam_role_policy.lambda_edge"
terraform state mv "$M.module.lambda_function.aws_iam_role_policy.logs[0]"          "$M.aws_iam_role_policy.lambda_edge_logs"
terraform state mv "$M.module.lambda_function.aws_cloudwatch_log_group.lambda[0]"   "$M.aws_cloudwatch_log_group.lambda_edge"

# s3_create_bucket = true
terraform state mv "$M.aws_s3_bucket_policy.s3_bucket_policy" "$M.module.s3_bucket.aws_s3_bucket_policy.this[0]"
# s3_create_bucket = false
terraform state mv "$M.aws_s3_bucket_policy.s3_bucket_policy" "$M.aws_s3_bucket_policy.s3_bucket_policy[0]"
```

Also:
* Remove `aws_region` and `s3_attach_policy` from your module call. Set the region on your `aws` provider instead.
* `s3_force_destroy` now defaults to `false`.
* The bucket policy no longer grants `s3:*` to whoever ran `terraform apply`. List admin principals in `s3_admin_principal_arns` if you need it.

---

## 🧪 Testing & Requirements
Run native tests with pytest:
```bash
pip install pytest==8.0.0
pytest src/
```
* **Terraform**: `>= 1.5.7` (or OpenTofu)
* **AWS Provider**: `>= 6.28.0`
* **Python**: `Python 3.12` / `Python 3.14`

---

## 🏷️ Releasing

Versions follow [SemVer](https://semver.org) with `v`-prefixed tags. Before `1.0.0`, breaking changes bump the minor version.

1. On a `release/vX.Y.Z` branch, rename `## [Unreleased]` in `CHANGELOG.md` to `## [X.Y.Z] - YYYY-MM-DD`, add a fresh `## [Unreleased]` above it, and update the compare links at the bottom.
2. Bump `?ref=` in the README snippets, open a PR and merge it once CI is green.
3. Tag the merge commit and push the tag:
   ```bash
   git switch master && git pull
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```
4. The `Release` workflow publishes a GitHub Release with that version's `CHANGELOG.md` section as its notes. It fails if the section is missing.

---

## 📌 Roadmap & Upcoming Features (TODO)

Contributions and architectural enhancements are welcome for the following scheduled features:

- [x] **Edge Authentication Layer**: HTTP **Basic Authentication** at the edge, credentials in **AWS Secrets Manager** with in-memory caching.
- [x] **Upstream Proxy**: Fallback to `pypi.org` (or any PEP 503 mirror) for packages not hosted locally.
- [ ] **Enterprise Custom Domain Mapping**:
  - Integrate **Amazon Route 53** to configure branded vanity aliases (e.g., `https://mycompany.com`).
  - Implement full SSL/TLS lifecycle termination via **AWS Certificate Manager (ACM)** certificates linked dynamically inside alternate domain names (CNAMEs) profiles within CloudFront.

---

## Terraform module info

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
| [aws_iam_role.lambda_edge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.lambda_edge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.lambda_edge_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_lambda_function.edge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_s3_bucket_policy.s3_bucket_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_secretsmanager_secret.auth](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.auth](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [archive_file.lambda](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_cloudfront_cache_policy.caching_optimized](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_cache_policy) | data source |
| [aws_cloudfront_origin_request_policy.all_viewer_except_host](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_origin_request_policy) | data source |
| [aws_iam_policy_document.lambda_edge_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.s3_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_s3_bucket.existing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/s3_bucket) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_auth_cache_ttl"></a> [auth\_cache\_ttl](#input\_auth\_cache\_ttl) | Number of seconds the Lambda@Edge function caches credentials in memory before re-reading the secret. Credential changes take up to this long to propagate | `number` | `300` | no |
| <a name="input_auth_credentials"></a> [auth\_credentials](#input\_auth\_credentials) | Map of username => password stored in the Secrets Manager secret. Values end up in Terraform state; leave empty to populate the secret out-of-band as a JSON object of username/password pairs | `map(string)` | `{}` | no |
| <a name="input_auth_enabled"></a> [auth\_enabled](#input\_auth\_enabled) | Whether to protect the whole index (including package downloads) with HTTP Basic Authentication backed by AWS Secrets Manager | `bool` | `false` | no |
| <a name="input_auth_realm"></a> [auth\_realm](#input\_auth\_realm) | Realm advertised in the WWW-Authenticate challenge | `string` | `"Private PyPI"` | no |
| <a name="input_auth_secret_recovery_window_in_days"></a> [auth\_secret\_recovery\_window\_in\_days](#input\_auth\_secret\_recovery\_window\_in\_days) | Number of days Secrets Manager waits before deleting the credentials secret. 0 forces immediate deletion | `number` | `7` | no |
| <a name="input_cloudfront_enabled"></a> [cloudfront\_enabled](#input\_cloudfront\_enabled) | Whether to create CloudFront distribution or not | `bool` | `true` | no |
| <a name="input_cloudfront_http_version"></a> [cloudfront\_http\_version](#input\_cloudfront\_http\_version) | HTTP version for CloudFront distribution | `string` | `"http2"` | no |
| <a name="input_cloudfront_price_class"></a> [cloudfront\_price\_class](#input\_cloudfront\_price\_class) | Price class for CloudFront distribution | `string` | `"PriceClass_100"` | no |
| <a name="input_cloudfront_ttl_default"></a> [cloudfront\_ttl\_default](#input\_cloudfront\_ttl\_default) | Default TTL (seconds) for /simple/ index pages in CloudFront. Newly uploaded files show up in the index after at most this long | `number` | `300` | no |
| <a name="input_cloudfront_ttl_max"></a> [cloudfront\_ttl\_max](#input\_cloudfront\_ttl\_max) | Maximum TTL (seconds) for /simple/ index pages in CloudFront | `number` | `3600` | no |
| <a name="input_cloudfront_ttl_min"></a> [cloudfront\_ttl\_min](#input\_cloudfront\_ttl\_min) | Minimum TTL (seconds) for /simple/ index pages in CloudFront. Package files use the managed CachingOptimized policy | `number` | `0` | no |
| <a name="input_cloudfront_use_acm_certificate"></a> [cloudfront\_use\_acm\_certificate](#input\_cloudfront\_use\_acm\_certificate) | Whether to use ACM certificate for CloudFront distribution or not. If false, CloudFront default certificate will be used. Only false is supported for now | `bool` | `false` | no |
| <a name="input_s3_acceleration_status"></a> [s3\_acceleration\_status](#input\_s3\_acceleration\_status) | Acceleration status of the bucket | `string` | `"Suspended"` | no |
| <a name="input_s3_acl"></a> [s3\_acl](#input\_s3\_acl) | Access control list for the bucket | `string` | `"private"` | no |
| <a name="input_s3_admin_principal_arns"></a> [s3\_admin\_principal\_arns](#input\_s3\_admin\_principal\_arns) | IAM principal ARNs granted full access (s3:*) to the bucket via the bucket policy. Usually unnecessary for same-account identities, whose IAM policies already grant access | `list(string)` | `[]` | no |
| <a name="input_s3_attach_deny_incorrect_encryption_headers"></a> [s3\_attach\_deny\_incorrect\_encryption\_headers](#input\_s3\_attach\_deny\_incorrect\_encryption\_headers) | Flag to attach deny incorrect encryption headers policy | `bool` | `false` | no |
| <a name="input_s3_attach_deny_incorrect_kms_key_sse"></a> [s3\_attach\_deny\_incorrect\_kms\_key\_sse](#input\_s3\_attach\_deny\_incorrect\_kms\_key\_sse) | Flag to attach deny incorrect KMS key SSE policy | `bool` | `false` | no |
| <a name="input_s3_attach_deny_insecure_transport_policy"></a> [s3\_attach\_deny\_insecure\_transport\_policy](#input\_s3\_attach\_deny\_insecure\_transport\_policy) | Flag to attach deny insecure transport policy | `bool` | `false` | no |
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
| <a name="input_upstream_enabled"></a> [upstream\_enabled](#input\_upstream\_enabled) | Whether to proxy /simple/<package>/ requests to the upstream index when the package is not hosted in the S3 bucket. Locally hosted packages always take precedence | `bool` | `false` | no |
| <a name="input_upstream_index_url"></a> [upstream\_index\_url](#input\_upstream\_index\_url) | HTTPS URL of the upstream PEP 503 simple index (e.g. https://pypi.org/simple) | `string` | `"https://pypi.org/simple"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_auth_secret_arn"></a> [auth\_secret\_arn](#output\_auth\_secret\_arn) | The ARN of the Secrets Manager secret holding Basic Auth credentials (null when auth is disabled) |
| <a name="output_auth_secret_name"></a> [auth\_secret\_name](#output\_auth\_secret\_name) | The name of the Secrets Manager secret holding Basic Auth credentials (null when auth is disabled) |
| <a name="output_cloudfront_pypi_index_url"></a> [cloudfront\_pypi\_index\_url](#output\_cloudfront\_pypi\_index\_url) | The domain name of the CloudFront distribution |
| <a name="output_s3_bucket_arn"></a> [s3\_bucket\_arn](#output\_s3\_bucket\_arn) | The ARN of the S3 bucket |
| <a name="output_s3_bucket_domain_name"></a> [s3\_bucket\_domain\_name](#output\_s3\_bucket\_domain\_name) | The regional domain name of the S3 bucket |
| <a name="output_s3_bucket_id"></a> [s3\_bucket\_id](#output\_s3\_bucket\_id) | The name of the S3 bucket |
| <a name="output_s3_bucket_policy"></a> [s3\_bucket\_policy](#output\_s3\_bucket\_policy) | The bucket policy JSON attached by this module (merged with the optional deny policies for a created bucket) |
<!-- END_TF_DOCS -->

---

## 📄 License
Licensed under the Apache 2.0 License.
