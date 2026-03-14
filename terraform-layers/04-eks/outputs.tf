output "eks_cluster_id" {
  value = split("/", aws_eks_cluster.main.identity[0].oidc[0].issuer)[4]
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "eks_cluster_name" {
  value = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}
