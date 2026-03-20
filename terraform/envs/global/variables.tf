variable "app_name" { default = "wiseling" }

variable "domain_name" {
  description = "Your registered domain e.g. wiseling.xyz"
  type        = string
  default     = ""
}

variable "primary_alb_dns" {
  description = "DNS name of the primary ALB (from: kubectl get ingress wiseling-ingress -n wiseling)"
  type        = string
  default     = "dummy-primary.example.com"
}

variable "primary_alb_zone_id" {
  description = "Hosted zone ID of the primary ALB. ALBs in ap-southeast-2 use Z1GM3OXH4ZPM65"
  type        = string
  default     = "Z1GM3OXH4ZPM65"
}

variable "dr_alb_dns" {
  description = "DNS name of the DR ALB (from: kubectl get ingress wiseling-ingress -n wiseling)"
  type        = string
  default     = "dummy-dr.example.com"
}

variable "dr_alb_zone_id" {
  description = "Hosted zone ID of the DR ALB. ALBs in ap-southeast-1 use Z1LMS91P8CMLE5"
  type        = string
  default     = "Z1LMS91P8CMLE5"
}

variable "alert_email" {
  description = "Email address to notify when the primary region health check fails"
  type        = string
}

variable "health_check_protocol" {
  description = "Use HTTP on first apply (before NS delegation to Cloudflare). Switch to HTTPS after cert validates."
  type        = string
  default     = "HTTP"
  validation {
    condition     = contains(["HTTP", "HTTPS"], var.health_check_protocol)
    error_message = "Must be HTTP or HTTPS."
  }
}
