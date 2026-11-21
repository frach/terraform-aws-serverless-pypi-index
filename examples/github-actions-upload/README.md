# Publishing from GitHub Actions

Creates the index plus an IAM role that GitHub Actions assumes through OIDC (no long-lived AWS keys).
The role gets the module's `uploader_policy_json`: upload to the bucket and invalidate `/simple/*`, nothing else.

```bash
terraform init
terraform apply -var github_repository=my-org/my-package
```

Then in `my-org/my-package`:

1. Add the repository variables `AWS_ROLE_ARN`, `AWS_REGION`, `PYPI_BUCKET` and `PYPI_DISTRIBUTION_ID` from the Terraform outputs.
2. Copy [publish.yml](publish.yml) to `.github/workflows/publish.yml`.

Every push to `main` builds the package, uploads the wheel and sdist under their PEP 503 normalized name and refreshes the index.
The workflow refuses to overwrite an existing file, because package files are cached as immutable.
