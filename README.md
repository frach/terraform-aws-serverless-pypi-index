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

## 📄 License
Licensed under the Apache 2.0 License.
