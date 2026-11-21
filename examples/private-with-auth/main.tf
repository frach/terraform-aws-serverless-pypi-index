provider "aws" {
  region = "eu-central-1"
}

module "pypi" {
  source = "../.."

  name = "pypi-private"

  # Basic Auth on every request. Credentials are NOT passed here, so they never end up in the Terraform state:
  # populate the secret out-of-band (see README)
  auth_enabled = true

  # Packages that aren't in the bucket are served from pypi.org, so one index URL covers private and public packages.
  # Local packages always win, which prevents dependency confusion
  upstream_enabled = true

  tags = {
    Project = "private-pypi"
  }
}
