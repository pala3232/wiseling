output "cluster_endpoint"  { value = aws_eks_cluster.main.endpoint }
output "cluster_ca_cert"   { value = aws_eks_cluster.main.certificate_authority[0].data }
output "cluster_name"      { value = aws_eks_cluster.main.name }
output "eks_cluster_id"    { value = split("/", aws_eks_cluster.main.identity[0].oidc[0].issuer)[4] }
output "oidc_provider_arn" { value = aws_iam_openid_connect_provider.eks.arn }
output "vpc_cni_role_arn"  { value = aws_iam_role.vpc_cni.arn }
