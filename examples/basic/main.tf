provider "aws" {
  region = "eu-central-1" # S3 bucket lives here; Lambda@Edge is always deployed in us-east-1
}

module "pypi" {
  source = "../.."

  name = "pypi-basic"
}
