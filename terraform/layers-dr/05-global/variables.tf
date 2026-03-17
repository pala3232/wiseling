variable "app_name" { default = "wiseling" }

variable "domain_name" {
  description = "Your registered domain e.g. wiseling.xyz"
  type        = string
  default = ""
}

variable "primary_alb_dns" {
  description = "DNS name of the primary ALB in ap-southeast-2 (from kubectl get ingress -n wiseling)"
  type        = string
  default = ""
}

variable "primary_alb_zone_id" {
  description = "Hosted zone ID of the primary ALB. ALBs in ap-southeast-2 use Z1GM3OXH4ZPM65"
  type        = string
  default     = "Z1GM3OXH4ZPM65"
}

variable "dr_alb_dns" {
  description = "DNS name of the DR ALB in ap-southeast-1 (from kubectl get ingress -n wiseling)"
  type        = string
  default = ""
}

variable "dr_alb_zone_id" {
  description = "Hosted zone ID of the DR ALB. ALBs in ap-southeast-1 use Z1LMS91P8CMLE5"
  type        = string
  default     = "Z1LMS91P8CMLE5"
}
