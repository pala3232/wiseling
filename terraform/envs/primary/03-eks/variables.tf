variable "admin_iam_arn" {
  description = "IAM ARN for local kubectl access"
  type        = string
  default     = ""
  sensitive   = true
}
