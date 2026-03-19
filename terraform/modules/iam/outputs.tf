output "pod_role_arn"      { value = aws_iam_role.pod_role.arn }
output "karpenter_role_arn" { value = aws_iam_role.karpenter.arn }
