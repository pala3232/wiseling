terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  required_version = ">= 1.3.0"
  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/05-global/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

# Global provider — Route 53 is global, us-east-1 is conventional
provider "aws" {
  alias  = "global"
  region = "us-east-1"
}

# Primary region provider — for reading ALB DNS name
provider "aws" {
  alias  = "primary"
  region = "ap-southeast-2"
}

# DR region provider — for reading DR ALB DNS name
provider "aws" {
  alias  = "dr"
  region = "ap-southeast-1"
}

# ── Hosted zone ───────────────────────────────────────────────────────────────

resource "aws_route53_zone" "main" {
  provider = aws.global
  name     = var.domain_name
  tags     = { Project = var.app_name }
}

# ── Health checks ─────────────────────────────────────────────────────────────

resource "aws_route53_health_check" "primary" {
  provider          = aws.global
  fqdn              = var.primary_alb_dns
  # port              = 80
  # type              = "HTTP"
  port = 443        # SWITCH TO THIS PORT AFTER YOU DEPLOYED THE ACM CERT AND APPLIED PORT 80.
  type = "HTTPS"    # SWITCH TO THIS PORT AFTER YOU DEPLOYED THE ACM CERT AND APPLIED PORT 80.
  resource_path     = "/api/v1/auth/health"
  failure_threshold = 3
  request_interval  = 30
  tags = {
    Name    = "${var.app_name}-primary-hc"
    Project = var.app_name
  }
}

resource "aws_route53_health_check" "dr" {
  provider          = aws.global
  fqdn              = var.dr_alb_dns
  # port              = 80     SWITCH TO THIS PORT AFTER YOU DEPLOYED THE ACM CERT AND APPLIED PORT 80.
  # type              = "HTTP" SWITCH TO THIS PORT AFTER YOU DEPLOYED THE ACM CERT AND APPLIED PORT 80.
  port = 443        #
  type = "HTTPS"    #
  resource_path     = "/api/v1/auth/health"
  failure_threshold = 3
  request_interval  = 30
  tags = {
    Name    = "${var.app_name}-dr-hc"
    Project = var.app_name
  }
}

# ── Failover DNS records ───────────────────────────────────────────────────────

# Primary record — serves traffic normally
resource "aws_route53_record" "primary" {
  provider        = aws.global
  zone_id         = aws_route53_zone.main.zone_id
  name            = var.domain_name
  type            = "A"
  set_identifier  = "primary"

  failover_routing_policy {
    type = "PRIMARY"
  }

  health_check_id = aws_route53_health_check.primary.id

  alias {
    name                   = var.primary_alb_dns
    zone_id                = var.primary_alb_zone_id
    evaluate_target_health = true
  }
}

# DR record — only receives traffic when primary health check fails
resource "aws_route53_record" "dr" {
  provider        = aws.global
  zone_id         = aws_route53_zone.main.zone_id
  name            = var.domain_name
  type            = "A"
  set_identifier  = "dr"

  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = var.dr_alb_dns
    zone_id                = var.dr_alb_zone_id
    evaluate_target_health = true
  }
}

# ── ACM Certificates ──────────────────────────────────────────────────────────

resource "aws_acm_certificate" "primary" {
  provider          = aws.primary
  domain_name       = var.domain_name
  validation_method = "DNS"
  tags = { Project = var.app_name }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "dr" {
  provider          = aws.dr
  domain_name       = var.domain_name
  validation_method = "DNS"
  tags = { Project = var.app_name }

  lifecycle {
    create_before_destroy = true
  }
}

# ── ACM DNS Validation Records ────────────────────────────────────────────────

resource "aws_route53_record" "cert_validation" {
  provider = aws.global
  for_each = {
    for dvo in aws_acm_certificate.primary.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
  zone_id         = aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
}

resource "aws_acm_certificate_validation" "primary" {
  provider                = aws.primary
  certificate_arn         = aws_acm_certificate.primary.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_acm_certificate_validation" "dr" {
  provider                = aws.dr
  certificate_arn         = aws_acm_certificate.dr.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}