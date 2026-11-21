provider "aws" {
  region = "eu-central-1"
}

data "aws_route53_zone" "this" {
  name = var.zone_name
}

# CloudFront only accepts certificates from us-east-1
resource "aws_acm_certificate" "pypi" {
  region = "us-east-1"

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.pypi.domain_validation_options : dvo.domain_name => dvo
  }

  zone_id = data.aws_route53_zone.this.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "pypi" {
  region = "us-east-1"

  certificate_arn         = aws_acm_certificate.pypi.arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]
}

module "pypi" {
  source = "../.."

  name = "pypi-custom-domain"

  cloudfront_aliases             = [var.domain_name]
  cloudfront_acm_certificate_arn = aws_acm_certificate_validation.pypi.certificate_arn
  route53_zone_id                = data.aws_route53_zone.this.zone_id
}
