locals {
  oidc_id = "oidc.eks.${var.aws_region}.amazonaws.com/id/${var.eks_cluster_id}"
}

# Pod role (IRSA for app pods)

data "aws_iam_policy_document" "pod_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_id}:sub"
      values = [
        "system:serviceaccount:wiseling:wiseling-sa",
        "system:serviceaccount:kube-system:wiseling-sa"
      ]
    }
  }
}

resource "aws_iam_role" "pod_role" {
  name               = "pod-role${var.name_suffix}"
  assume_role_policy = data.aws_iam_policy_document.pod_assume.json
  tags               = { Project = var.app_name }
}

resource "aws_iam_role_policy_attachment" "attach_secrets" {
  role       = aws_iam_role.pod_role.name
  policy_arn = aws_iam_policy.secrets.arn
}

resource "aws_iam_role_policy_attachment" "attach_cloudwatch" {
  role       = aws_iam_role.pod_role.name
  policy_arn = aws_iam_policy.cloudwatch.arn
}

resource "aws_iam_role_policy_attachment" "attach_dynamodb" {
  role       = aws_iam_role.pod_role.name
  policy_arn = aws_iam_policy.dynamodb.arn
}

resource "aws_iam_role_policy_attachment" "attach_sqs" {
  role       = aws_iam_role.pod_role.name
  policy_arn = aws_iam_policy.sqs.arn
}

resource "aws_iam_role_policy_attachment" "attach_lb" {
  role       = aws_iam_role.pod_role.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# Karpenter role

data "aws_iam_policy_document" "karpenter_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_id}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter-sa"]
    }
  }
}

resource "aws_iam_role" "karpenter" {
  name               = "${var.app_name}-karpenter-role${var.name_suffix}"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume.json
  tags               = { Project = var.app_name }
}

resource "aws_iam_role_policy_attachment" "karpenter" {
  role       = aws_iam_role.karpenter.name
  policy_arn = aws_iam_policy.karpenter.arn
}

# Policies

resource "aws_iam_policy" "secrets" {
  name = "external-secrets-read-secret${var.name_suffix}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [
        "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:${var.app_name}-jwt-secret-key${var.name_suffix}-*",
        "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:${var.app_name}/db-urls${var.name_suffix}-*"
      ]
    }]
  })
  tags = { Project = var.app_name }
}

resource "aws_iam_policy" "cloudwatch" {
  name        = "cloudwatch-policy${var.name_suffix}"
  description = "CloudWatch read access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics"]
      Resource = "*"
    }]
  })
  tags = { Project = var.app_name }
}

resource "aws_iam_policy" "dynamodb" {
  name        = "dynamodb-policy${var.name_suffix}"
  description = "DynamoDB access for outbox table"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan",
        "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"
      ]
      Resource = "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/${var.app_name}-outbox"
    }]
  })
  tags = { Project = var.app_name }
}

resource "aws_iam_policy" "sqs" {
  name = "${var.app_name}-sqs-policy${var.name_suffix}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
      Resource = [
        "arn:aws:sqs:${var.aws_region}:${var.account_id}:${var.app_name}-conversions",
        "arn:aws:sqs:${var.aws_region}:${var.account_id}:${var.app_name}-withdrawals"
      ]
    }]
  })
  tags = { Project = var.app_name }
}

resource "aws_iam_policy" "lb_controller" {
  name   = "AWSLoadBalancerControllerPolicy${var.name_suffix}"
  policy = file("${path.module}/policies/lb-controller-policy.json")
  tags   = { Project = var.app_name }
}

resource "aws_iam_policy" "karpenter" {
  name = "${var.app_name}-karpenter-policy${var.name_suffix}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:RunInstances", "ec2:TerminateInstances", "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypes", "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups",
        "ec2:DescribeLaunchTemplates", "ec2:DescribeAvailabilityZones",
        "ec2:DescribeImages", "ec2:DescribeSpotPriceHistory",
        "ec2:CreateFleet", "ec2:CreateLaunchTemplate", "ec2:DeleteLaunchTemplate",
        "ec2:CreateTags", "ec2:DescribeLaunchTemplateVersions",
        "pricing:GetProducts",
        "iam:PassRole", "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile", "iam:AddRoleToInstanceProfile",
        "iam:TagInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:ListInstanceProfiles",
        "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ReceiveMessage",
        "eks:DescribeCluster",
        "ssm:GetParameter"
      ]
      Resource = "*"
    }]
  })
  tags = { Project = var.app_name }
}
