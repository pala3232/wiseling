output "eks_cluster_id" {
  value = split("/", aws_eks_cluster.wiseling-eks-cluster.identity[0].oidc[0].issuer)[4]
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

variable "admin_iam_arn" {
  description = "IAM ARN for local kubectl access"
  type        = string
  default     = ""
  sensitive   = true
}