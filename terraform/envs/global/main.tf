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

# Route 53 is global
provider "aws" {
  alias  = "global"
  region = "us-east-1"
}

# For ACM cert in primary region
provider "aws" {
  alias  = "primary"
  region = "ap-southeast-2"
}

# For ACM cert in DR region
provider "aws" {
  alias  = "dr"
  region = "ap-southeast-1"
}

locals {
  hc_port = var.health_check_protocol == "HTTPS" ? 443 : 80
}

# Hosted zone

resource "aws_route53_zone" "main" {
  provider = aws.global
  name     = var.domain_name
  tags     = { Project = var.app_name }
}

# Health checks

resource "aws_route53_health_check" "primary" {
  provider          = aws.global
  fqdn              = var.primary_alb_dns
  port              = local.hc_port
  type              = var.health_check_protocol
  resource_path     = "/api/v1/auth/health"
  failure_threshold = 2
  request_interval  = 10
  tags = {
    Name    = "${var.app_name}-primary-hc"
    Project = var.app_name
    Force   = "1"
  }
}

resource "aws_route53_health_check" "dr" {
  provider          = aws.global
  fqdn              = var.dr_alb_dns
  port              = local.hc_port
  type              = var.health_check_protocol
  resource_path     = "/api/v1/auth/health"
  failure_threshold = 3
  request_interval  = 30
  tags = {
    Name    = "${var.app_name}-dr-hc"
    Project = var.app_name
    Force   = "1"
  }
}

# Failover DNS records

resource "aws_route53_record" "primary" {
  provider       = aws.global
  zone_id        = aws_route53_zone.main.zone_id
  name           = var.domain_name
  type           = "A"
  set_identifier = "primary"

  failover_routing_policy { type = "PRIMARY" }
  health_check_id = aws_route53_health_check.primary.id

  alias {
    name                   = var.primary_alb_dns
    zone_id                = var.primary_alb_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "dr" {
  provider       = aws.global
  zone_id        = aws_route53_zone.main.zone_id
  name           = var.domain_name
  type           = "A"
  set_identifier = "dr"

  failover_routing_policy { type = "SECONDARY" }
  health_check_id = aws_route53_health_check.dr.id

  alias {
    name                   = var.dr_alb_dns
    zone_id                = var.dr_alb_zone_id
    evaluate_target_health = false
  }
}

# ACM certificates

resource "aws_acm_certificate" "primary" {
  provider          = aws.primary
  domain_name       = var.domain_name
  validation_method = "DNS"
  tags              = { Project = var.app_name }
  lifecycle { create_before_destroy = true }
}

resource "aws_acm_certificate" "dr" {
  provider          = aws.dr
  domain_name       = var.domain_name
  validation_method = "DNS"
  tags              = { Project = var.app_name }
  lifecycle { create_before_destroy = true }
}

# DNS validation CNAME (same record validates both certs)
resource "aws_route53_record" "cert_validation" {
  provider = aws.global
  for_each = {
    for dvo in aws_acm_certificate.primary.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
  zone_id = aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

# Certificate validation waiters — skipped on first apply (HTTP) so Terraform doesn't
# hang waiting for DNS that isn't delegated yet. On second apply (HTTPS), DNS is live
# and these complete in seconds.
resource "aws_acm_certificate_validation" "primary" {
  count                   = var.health_check_protocol == "HTTPS" ? 1 : 0
  provider                = aws.primary
  certificate_arn         = aws_acm_certificate.primary.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_acm_certificate_validation" "dr" {
  count                   = var.health_check_protocol == "HTTPS" ? 1 : 0
  provider                = aws.dr
  certificate_arn         = aws_acm_certificate.dr.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ── Alerting ──────────────────────────────────────────────────────────────────
# Three alarm channels:
#   1. us-east-1  — Route53 health check failure (regional failover)
#   2. ap-southeast-2 — SQS DLQ depth (failed event processing)
#   3. ap-southeast-1 — RDS replication lag (data loss risk on failover)
# CloudWatch Route53 health check metrics are only available in us-east-1.

resource "aws_sns_topic" "failover_alerts" {
  provider = aws.global
  name     = "wiseling-failover-alerts"
  tags     = { Project = var.app_name }
}

resource "aws_sns_topic_subscription" "failover_email" {
  provider  = aws.global
  topic_arn = aws_sns_topic.failover_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── Channel 2: SQS DLQ alarms (primary region) ────────────────────────────────

resource "aws_sns_topic" "ops_alerts_primary" {
  provider = aws.primary
  name     = "wiseling-ops-alerts-primary"
  tags     = { Project = var.app_name }
}

resource "aws_sns_topic_subscription" "ops_alerts_primary_email" {
  provider  = aws.primary
  topic_arn = aws_sns_topic.ops_alerts_primary.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "conversions_dlq" {
  provider            = aws.primary
  alarm_name          = "wiseling-conversions-dlq-not-empty"
  alarm_description   = "Messages in wiseling-conversions-dlq — conversion events failed processing. Check wallet-consumer logs."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  dimensions          = { QueueName = "wiseling-conversions-dlq" }
  alarm_actions       = [aws_sns_topic.ops_alerts_primary.arn]
  ok_actions          = [aws_sns_topic.ops_alerts_primary.arn]
  tags                = { Project = var.app_name }
}

resource "aws_cloudwatch_metric_alarm" "withdrawals_dlq" {
  provider            = aws.primary
  alarm_name          = "wiseling-withdrawals-dlq-not-empty"
  alarm_description   = "Messages in wiseling-withdrawals-dlq — withdrawal/transfer events failed processing. Check wallet-consumer logs."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  dimensions          = { QueueName = "wiseling-withdrawals-dlq" }
  alarm_actions       = [aws_sns_topic.ops_alerts_primary.arn]
  ok_actions          = [aws_sns_topic.ops_alerts_primary.arn]
  tags                = { Project = var.app_name }
}

# ── Channel 3: RDS replication lag (DR region) ────────────────────────────────

resource "aws_sns_topic" "ops_alerts_dr" {
  provider = aws.dr
  name     = "wiseling-ops-alerts-dr"
  tags     = { Project = var.app_name }
}

resource "aws_sns_topic_subscription" "ops_alerts_dr_email" {
  provider  = aws.dr
  topic_arn = aws_sns_topic.ops_alerts_dr.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "rds_replica_lag" {
  provider            = aws.dr
  alarm_name          = "wiseling-rds-replica-lag-high"
  alarm_description   = "RDS replica lag above 30s — failover risks data loss. Investigate primary RDS and network connectivity between regions."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 30
  dimensions          = { DBInstanceIdentifier = "wiseling-rds-replica-sgp" }
  alarm_actions       = [aws_sns_topic.ops_alerts_dr.arn]
  ok_actions          = [aws_sns_topic.ops_alerts_dr.arn]
  tags                = { Project = var.app_name }
}

# ── Channel 1: Route53 health check (us-east-1) ───────────────────────────────

resource "aws_cloudwatch_metric_alarm" "primary_unhealthy" {
  provider            = aws.global
  alarm_name          = "wiseling-primary-region-unhealthy"
  alarm_description   = "Primary region health check is failing. Route53 has already switched traffic to DR. Evaluate whether to promote the RDS replica via the failover workflow."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  dimensions = {
    HealthCheckId = aws_route53_health_check.primary.id
  }
  alarm_actions = [aws_sns_topic.failover_alerts.arn]
  ok_actions    = [aws_sns_topic.failover_alerts.arn]
  tags          = { Project = var.app_name }
}
