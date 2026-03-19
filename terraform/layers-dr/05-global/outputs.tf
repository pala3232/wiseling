output "hosted_zone_id" {
  value = aws_route53_zone.main.zone_id
}

output "name_servers" {
  value       = aws_route53_zone.main.name_servers
  description = "Paste these into Cloudflare as custom nameservers"
}

# output "dr_ingress_cert_annotation" {
#   value = "alb.ingress.kubernetes.io/certificate-arn: ${aws_acm_certificate_validation.dr.certificate_arn}"
#}
# output "primary_ingress_cert_annotation" {
#   value = "alb.ingress.kubernetes.io/certificate-arn: ${aws_acm_certificate_validation.primary.certificate_arn}"
#}

# also uncomment these on second run.