# Custom domain

Serves the index at `https://pypi.example.com/simple/` with an ACM certificate validated through Route 53.

```bash
terraform init
terraform apply -var zone_name=example.com -var domain_name=pypi.example.com
```

The certificate is created in `us-east-1` (a CloudFront requirement) with the AWS provider's per-resource `region` argument, so no provider alias is needed.
If your DNS isn't in Route 53, create and validate the certificate yourself, pass its ARN as `cloudfront_acm_certificate_arn`, leave `route53_zone_id` unset and point a `CNAME` at the `cloudfront_pypi_index_url` output.
