# Basic

The smallest possible deployment: a public (unauthenticated) PEP 503 index on the default `*.cloudfront.net` domain.

```bash
terraform init && terraform apply
aws s3 cp dist/my_package-1.0.0-py3-none-any.whl "s3://$(terraform output -raw s3_bucket_id)/my-package/"
pip install --index-url "$(terraform output -raw index_url)" my-package
```

Anyone who knows the URL can download your packages. See [private-with-auth](../private-with-auth) for a private index.
