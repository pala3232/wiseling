variable "aws_region" {
  description = "AWS region where the EKS cluster is deployed"
  default     = "ap-southeast-2"
}
variable "app_name" {
  description = "Name of the application for tagging and naming resources"
  default     = "wiseling"
}

# I use no default. it's dynamic.

variable "oidc_provider_arn" {
  description = "OIDC provider ARN for EKS"
  type        = string
}

variable "eks_cluster_id" {
  description = "EKS cluster ID for OIDC policy"
  type        = string
}