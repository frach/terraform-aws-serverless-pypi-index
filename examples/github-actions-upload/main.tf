provider "aws" {
  region = "eu-central-1"
}

module "pypi" {
  source = "../.."

  name             = "pypi-ci"
  auth_enabled     = true
  upstream_enabled = true
}

# GitHub Actions OIDC provider: exists at most once per AWS account, so reuse it if you already have one
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# Role that only workflows from the given repository and branch can assume
resource "aws_iam_role" "uploader" {
  name = "pypi-ci-uploader"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.github_oidc_provider_arn }
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:refs/heads/main" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "uploader" {
  name   = "upload-packages"
  role   = aws_iam_role.uploader.name
  policy = module.pypi.uploader_policy_json
}
