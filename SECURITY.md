# Security Policy

## Supported versions

Security fixes go into the latest release only. Before `1.0.0`, upgrade to the newest `0.x` version to get them.

| Version | Supported |
|---|---|
| Latest release | Yes |
| Older releases | No |

## Reporting a vulnerability

Please don't open a public issue for security problems. Report them privately through
[GitHub private vulnerability reporting](https://github.com/frach/terraform-aws-serverless-pypi-index/security/advisories/new)
with:

- what an attacker can do and under which configuration (`auth_enabled`, `upstream_enabled`, custom domain, ...),
- steps to reproduce or a proof of concept,
- the module version and the Terraform/OpenTofu and AWS provider versions.

You can expect a first answer within 7 days. Once a fix is released, the advisory is published with credit to the reporter
unless you prefer otherwise.

## Security notes for users

- **Credentials in the Terraform state.** Values passed in `auth_credentials` are stored in the state. To keep them out,
  leave `auth_credentials` empty and set the secret with `aws secretsmanager put-secret-value`
  (see [examples/private-with-auth](examples/private-with-auth)).
- **Basic Auth sends the password with every request.** It is only sent over HTTPS (HTTP is redirected), but treat index
  passwords like any other secret: one per client or CI system, rotated when someone leaves.
- **Credential changes are cached.** The edge function caches credentials for `auth_cache_ttl` seconds (default 300), so a
  removed user keeps access for up to that long.
- **Without `auth_enabled` the index is public.** Anyone who knows the URL can list and download your packages.
- **Dependency confusion.** With `upstream_enabled`, a package name that exists in your bucket is never looked up upstream.
  Keep at least one file of every private package in the bucket, otherwise pip falls back to pypi.org for that name.
- **Package files are immutable.** Don't overwrite a published file. CloudFront caches files for a long time, and pip may
  reject a file whose hash changed.
