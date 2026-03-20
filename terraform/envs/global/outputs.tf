output "hosted_zone_id" {
  value = aws_route53_zone.main.zone_id
}

output "name_servers" {
  value       = aws_route53_zone.main.name_servers
  description = "Paste these into Cloudflare as custom nameservers"
}

output "primary_cert_arn" {
  value       = aws_acm_certificate.primary.arn
  description = "Use in the primary ingress annotation: alb.ingress.kubernetes.io/certificate-arn"
}

output "dr_cert_arn" {
  value       = aws_acm_certificate.dr.arn
  description = "Use in the DR ingress annotation: alb.ingress.kubernetes.io/certificate-arn"
}
