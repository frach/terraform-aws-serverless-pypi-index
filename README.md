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
                    ▼  (HTTPS GET request)
          ┌───────────────────┐
          │ Amazon CloudFront │  ◄─── [Cache Hit]
          └─────────┬─────────┘
                    │
                    ▼  (Cache Miss: Lambda Trigger)
          ┌───────────────────┐
          │    AWS  Lambda    │  ◄─── [Loads config.json sidecar]
          └─────────┬─────────┘
                    │
                    ▼  (S3 API: list_objects_v2)
          ┌───────────────────┐
          │     Amazon S3     │  ─── [Reads flat layout]
          └───────────────────┘
```

### 📡 Request Lifecycle & Data Flow
1. **Edge Request Route**: Package managers request package indexes via CloudFront.
2. **Sub-Millisecond Caching Layer**: CloudFront returns cached metadata instantly.
3. **Decoupled Serverless Processing**: Cache misses trigger the **AWS Lambda** function, reading an isolated `config.json` sidecar and querying S3 via `list_objects_v2`.
4. **PEP 503 On-The-Fly Generation**: Lambda normalizes S3 keys into a lightweight HTML index string.
5. **Direct Asset Passthrough**: Binary wheel requests pass securely and directly from S3 through CloudFront.

### ⚙️ DevOps & Security Optimizations
- **Smart Compilation Triggers**: Tracks precise cryptographic hashes of source and config files to rebuild only when changes occur.
- **Zero-Pollution Packaging System**: Blocks local caching debris via regex isolation.
- **Flat Layout Storage Pattern**: Stores binaries under a clean `package_name/artifact_name.whl` key format.

---

## 🚀 Key Features
- **True Serverless Architecture**: Scale-to-zero model with no idle infrastructure costs.
- **PEP 503 Simple API Compliant**: Works seamlessly with `pip`, `poetry`, `uv`, and `twine`.
- **High Performance at Edge**: Global low latency via CloudFront.

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

## 🧪 Testing & Requirements
Run native tests with pytest:
```bash
pip install pytest==8.0.0
pytest src/
```
* **Terraform**: `>= 1.8.0`
* **AWS Provider**: `>= 5.0.0`
* **Python**: `Python 3.12` / `Python 3.14`

---

## 📌 Roadmap & Upcoming Features (TODO)

Contributions and architectural enhancements are welcome for the following scheduled features:

- [ ] **Edge Authentication Layer**:
  - Implement standard HTTP **Basic Authentication** directly within the CloudFront Request lifecycle.
  - Securely store, rotate, and fetch authorized credentials using **AWS Secrets Manager** with optimized regional caching strategies to minimize lookup latency.
- [ ] **Enterprise Custom Domain Mapping**:
  - Integrate **Amazon Route 53** to configure branded vanity aliases (e.g., `https://mycompany.com`).
  - Implement full SSL/TLS lifecycle termination via **AWS Certificate Manager (ACM)** certificates linked dynamically inside alternate domain names (CNAMEs) profiles within CloudFront.

---

## Terraform module info

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.8.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.15.0 |
| <a name="requirement_local"></a> [local](#requirement\_local) | >= 2.5.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.15.0 |
| <a name="provider_local"></a> [local](#provider\_local) | >= 2.5.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_cloudfront"></a> [cloudfront](#module\_cloudfront) | terraform-aws-modules/cloudfront/aws | 6.4.0 |
| <a name="module_lambda_function"></a> [lambda\_function](#module\_lambda\_function) | terraform-aws-modules/lambda/aws | ~> 8.0 |
| <a name="module_s3_bucket"></a> [s3\_bucket](#module\_s3\_bucket) | terraform-aws-modules/s3-bucket/aws | 5.10.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_s3_bucket_policy.s3_bucket_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [local_file.lambda_config](https://registry.terraform.io/providers/hashicorp/local/latest/docs/resources/file) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_cloudfront_cache_policy.caching_optimized](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_cache_policy) | data source |
| [aws_cloudfront_origin_request_policy.all_viewer_except_host](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_origin_request_policy) | data source |
| [aws_iam_policy_document.s3_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | The primary AWS region where the S3 storage bucket and Secrets Manager will be deployed. | `string` | `"eu-central-1"` | no |
| <a name="input_cloudfront_enabled"></a> [cloudfront\_enabled](#input\_cloudfront\_enabled) | Whether to create CloudFront distribution or not | `bool` | `true` | no |
| <a name="input_cloudfront_http_version"></a> [cloudfront\_http\_version](#input\_cloudfront\_http\_version) | HTTP version for CloudFront distribution | `string` | `"http2"` | no |
| <a name="input_cloudfront_price_class"></a> [cloudfront\_price\_class](#input\_cloudfront\_price\_class) | Price class for CloudFront distribution | `string` | `"PriceClass_100"` | no |
| <a name="input_cloudfront_ttl_default"></a> [cloudfront\_ttl\_default](#input\_cloudfront\_ttl\_default) | Default TTL for CloudFront cache behavior | `number` | `1` | no |
| <a name="input_cloudfront_ttl_max"></a> [cloudfront\_ttl\_max](#input\_cloudfront\_ttl\_max) | Maximum TTL for CloudFront cache behavior | `number` | `1` | no |
| <a name="input_cloudfront_ttl_min"></a> [cloudfront\_ttl\_min](#input\_cloudfront\_ttl\_min) | Minimum TTL for CloudFront cache behavior | `number` | `1` | no |
| <a name="input_cloudfront_use_acm_certificate"></a> [cloudfront\_use\_acm\_certificate](#input\_cloudfront\_use\_acm\_certificate) | Whether to use ACM certificate for CloudFront distribution or not. If false, CloudFront default certificate will be used. Only false is supported for now | `bool` | `false` | no |
| <a name="input_s3_acceleration_status"></a> [s3\_acceleration\_status](#input\_s3\_acceleration\_status) | Acceleration status of the bucket | `string` | `"Suspended"` | no |
| <a name="input_s3_acl"></a> [s3\_acl](#input\_s3\_acl) | Access control list for the bucket | `string` | `"private"` | no |
| <a name="input_s3_attach_deny_incorrect_encryption_headers"></a> [s3\_attach\_deny\_incorrect\_encryption\_headers](#input\_s3\_attach\_deny\_incorrect\_encryption\_headers) | Flag to attach deny incorrect encryption headers policy | `bool` | `false` | no |
| <a name="input_s3_attach_deny_incorrect_kms_key_sse"></a> [s3\_attach\_deny\_incorrect\_kms\_key\_sse](#input\_s3\_attach\_deny\_incorrect\_kms\_key\_sse) | Flag to attach deny incorrect KMS key SSE policy | `bool` | `false` | no |
| <a name="input_s3_attach_deny_insecure_transport_policy"></a> [s3\_attach\_deny\_insecure\_transport\_policy](#input\_s3\_attach\_deny\_insecure\_transport\_policy) | Flag to attach deny insecure transport policy | `bool` | `false` | no |
| <a name="input_s3_attach_deny_ssec_encrypted_object_uploads"></a> [s3\_attach\_deny\_ssec\_encrypted\_object\_uploads](#input\_s3\_attach\_deny\_ssec\_encrypted\_object\_uploads) | Flag to attach deny SSEC encrypted object uploads policy | `bool` | `false` | no |
| <a name="input_s3_attach_deny_unencrypted_object_uploads"></a> [s3\_attach\_deny\_unencrypted\_object\_uploads](#input\_s3\_attach\_deny\_unencrypted\_object\_uploads) | Flag to attach deny unencrypted object uploads policy | `bool` | `false` | no |
| <a name="input_s3_attach_policy"></a> [s3\_attach\_policy](#input\_s3\_attach\_policy) | Flag to attach policy | `bool` | `false` | no |
| <a name="input_s3_attach_require_latest_tls_policy"></a> [s3\_attach\_require\_latest\_tls\_policy](#input\_s3\_attach\_require\_latest\_tls\_policy) | Flag to attach require latest TLS policy | `bool` | `false` | no |
| <a name="input_s3_block_public_acls"></a> [s3\_block\_public\_acls](#input\_s3\_block\_public\_acls) | Flag to block public ACLs | `bool` | `true` | no |
| <a name="input_s3_block_public_policy"></a> [s3\_block\_public\_policy](#input\_s3\_block\_public\_policy) | Flag to block public policy | `bool` | `true` | no |
| <a name="input_s3_bucket_name"></a> [s3\_bucket\_name](#input\_s3\_bucket\_name) | The name of the bucket. If s3\_create\_bucket is false, this variable must be provided with the name of an existing bucket to be used as the origin for CloudFront distribution | `string` | `null` | no |
| <a name="input_s3_control_object_ownership"></a> [s3\_control\_object\_ownership](#input\_s3\_control\_object\_ownership) | Flag to control object ownership | `bool` | `true` | no |
| <a name="input_s3_create_bucket"></a> [s3\_create\_bucket](#input\_s3\_create\_bucket) | Whether to create S3 bucket or not | `bool` | `true` | no |
| <a name="input_s3_force_destroy"></a> [s3\_force\_destroy](#input\_s3\_force\_destroy) | Flag to force destroy the bucket | `bool` | `true` | no |
| <a name="input_s3_ignore_public_acls"></a> [s3\_ignore\_public\_acls](#input\_s3\_ignore\_public\_acls) | Flag to ignore public ACLs | `bool` | `true` | no |
| <a name="input_s3_object_ownership"></a> [s3\_object\_ownership](#input\_s3\_object\_ownership) | Object ownership setting | `string` | `"BucketOwnerPreferred"` | no |
| <a name="input_s3_request_payer"></a> [s3\_request\_payer](#input\_s3\_request\_payer) | Request payer for the bucket | `string` | `"BucketOwner"` | no |
| <a name="input_s3_restrict_public_buckets"></a> [s3\_restrict\_public\_buckets](#input\_s3\_restrict\_public\_buckets) | Flag to restrict public buckets | `bool` | `true` | no |
| <a name="input_s3_versioning"></a> [s3\_versioning](#input\_s3\_versioning) | Versioning configuration for the bucket | <pre>object({<br/>    status     = bool<br/>    mfa_delete = bool<br/>  })</pre> | <pre>{<br/>  "mfa_delete": false,<br/>  "status": true<br/>}</pre> | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_cloudfront_pypi_index_url"></a> [cloudfront\_pypi\_index\_url](#output\_cloudfront\_pypi\_index\_url) | The domain name of the CloudFront distribution |
| <a name="output_s3_bucket_arn"></a> [s3\_bucket\_arn](#output\_s3\_bucket\_arn) | The ARN of the S3 bucket |
| <a name="output_s3_bucket_domain_name"></a> [s3\_bucket\_domain\_name](#output\_s3\_bucket\_domain\_name) | The regional domain name of the S3 bucket |
| <a name="output_s3_bucket_id"></a> [s3\_bucket\_id](#output\_s3\_bucket\_id) | The name of the S3 bucket |
| <a name="output_s3_bucket_policy"></a> [s3\_bucket\_policy](#output\_s3\_bucket\_policy) | The ID of the S3 bucket policy |
<!-- END_TF_DOCS -->

---

## 📄 License
Licensed under the Apache 2.0 License.
