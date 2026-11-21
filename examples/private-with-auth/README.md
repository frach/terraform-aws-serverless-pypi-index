# Private index with Basic Auth and pypi.org fallback

```bash
terraform init && terraform apply

# Add users without putting passwords in the Terraform state
aws secretsmanager put-secret-value \
  --secret-id "$(terraform output -raw auth_secret_name)" \
  --secret-string '{"ci": "change-me", "alice": "change-me-too"}'

# One index for everything: private packages from S3, the rest from pypi.org
INDEX="$(terraform output -raw index_url)"
pip install --index-url "https://alice:change-me-too@${INDEX#https://}" my-private-package requests
```

Credentials are cached by the edge function for `auth_cache_ttl` seconds (default 300), so new users can take up to 5 minutes to work.
For `uv`, Poetry and `~/.netrc` setups see the main README.
