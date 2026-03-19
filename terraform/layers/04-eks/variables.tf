variable "aws_region" {
  default = "ap-southeast-2"
}

variable "app_name" {
  default = "wiseling"
}

variable "admin_iam_arn" {
  description = "IAM ARN for local kubectl access"
  type        = string
  default     = ""
  sensitive   = true
}