# AWS Serverless PyPI Index (Terraform Module)

A production-ready, fully serverless, and highly cost-effective private PyPI index hosted on AWS. 

Instead of paying hundreds of dollars monthly for heavy managed infrastructure like AWS CodeArtifact or JFrog Artifactory,
this module leverages **AWS S3**, **CloudFront**, and **AWS Lambda** to deliver a secure, fast, and scalable private
Python package registry that costs virtually **$0/month** on low-to-medium usage.


## 🏗️ Architecture Overview

1. **AWS S3**: Stores the actual Python wheel and source packages securely.
2. **AWS Lambda (Python 3.12)**: Dynamically generates the PEP 503 compliant HTML index links and handles lightweight
authentication.
3. **Amazon CloudFront**: Acts as a global CDN edge cache to ensure blazing-fast `pip install` speeds worldwide while
reducing Lambda execution costs.


## 🚀 Key Features

* **True Serverless**: No servers to manage, no idle costs. Scale-to-zero infrastructure.
* **Modern Tech Stack**: Upgraded to **Terraform v1.8+** and **AWS Provider v6.x**.
* **Enhanced Security**: Protected via customizable basic authentication and CloudFront Origin Access Control (OAC) for the S3 bucket. (TODO)
* **High Performance**: CloudFront caching ensures package metadata and index responses are delivered with sub-millisecond latency.
* **ARM64 Native**: Uses AWS Graviton (arm64) for Lambda to achieve 34% better performance and lower costs compared to x86. (TODO)


## 🛠️ Usage & Deployment

TODO

You can deploy this private registry into your AWS infrastructure with a few lines of Terraform code:

```hcl
module "serverless_pypi" {
  source = "./modules/terraform-aws-serverless-pypi-index"

  project_name        = "my-company-pypi"
  environment         = "production"

  # Security configuration
  pypi_admin_username = "admin"
  pypi_admin_password = "SecurePassword123!" # Use AWS Secrets Manager / Variables in production

  tags = {
    Deployment = "Terraform"
    CostCenter = "DevOps"
  }
}

output "pypi_registry_url" {
  value = module.serverless_pypi.cloudfront_domain_name
}
```

## 📦 How to Use with Pip

Once deployed, you can securely upload and install your private Python packages.


### 1. Installing Packages

To install a package from your new serverless registry, simply run:

```bash
pip install --index-url https://admin:SecurePassword123!@your-cloudfront-domain.net/simple/ your-private-package
```

Alternatively, configure your `pip.conf` or `pyproject.toml` (Poetry) to include the extra index URL.


### 2. Uploading Packages

Packages can be securely uploaded directly to the underlying S3 bucket under the `packages/` prefix using the AWS CLI or integrated into your GitHub Actions / GitLab CI pipelines:

```bash
aws s3 cp dist/your_package-0.1.0-py3-none-any.whl s3://your-pypi-s3-bucket/packages/
```

The Lambda function automatically reflects newly uploaded packages in the index instantly.


## 🔧 Requirements & Compatibility

* **Terraform**: `>= 1.8.0`
* **AWS Provider**: `>= 5.0.0`
* **AWS Lambda Runtime**: `Python 3.12` (ARM64 architecture)

## 📄 License

This project is licensed under the MIT License.
