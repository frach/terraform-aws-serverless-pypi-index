variable "zone_name" {
  description = "Route 53 hosted zone that owns the domain, e.g. example.com"
  type        = string
}

variable "domain_name" {
  description = "Domain of the index, e.g. pypi.example.com"
  type        = string
}
