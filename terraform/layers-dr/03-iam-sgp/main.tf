terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  required_version = ">= 1.3.0"
  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/03-iam-sgp/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

provider "aws" { region = var.aws_region }

data "terraform_remote_state" "eks_sgp" {
  backend = "s3"
  config = {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/04-eks-sgp/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

locals {
  oidc_provider_arn = data.terraform_remote_state.eks_sgp.outputs.oidc_provider_arn
  eks_cluster_id    = data.terraform_remote_state.eks_sgp.outputs.eks_cluster_id
  oidc_id           = "oidc.eks.${var.aws_region}.amazonaws.com/id/${local.eks_cluster_id}"
}

# Pod role (IRSA)

data "aws_iam_policy_document" "pod_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
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
  name               = "pod-role-sgp"
  assume_role_policy = data.aws_iam_policy_document.pod_assume.json
  tags               = { Project = var.app_name, Region = "sgp" }
}

resource "aws_iam_policy" "secrets" {
  name = "external-secrets-read-secret-sgp"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [
        "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:${var.app_name}-jwt-secret-key-sgp-*",
        "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:${var.app_name}/db-urls-sgp-*"
      ]
    }]
  })
  tags = { Project = var.app_name, Region = "sgp" }
}

resource "aws_iam_policy" "cloudwatch" {
  name = "cloudwatch-policy-sgp"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics"]
      Resource = "*"
    }]
  })
  tags = { Project = var.app_name, Region = "sgp" }
}

resource "aws_iam_policy" "dynamodb" {
  name = "dynamodb-policy-sgp"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
      Resource = "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/${var.app_name}-outbox"
    }]
  })
  tags = { Project = var.app_name, Region = "sgp" }
}

resource "aws_iam_policy" "sqs" {
  name = "${var.app_name}-sqs-policy-sgp"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
      Resource = [
        "arn:aws:sqs:ap-southeast-2:${var.account_id}:${var.app_name}-conversions",
        "arn:aws:sqs:ap-southeast-2:${var.account_id}:${var.app_name}-withdrawals"
      ]
    }]
  })
  tags = { Project = var.app_name, Region = "sgp" }
}

resource "aws_iam_policy" "lb_controller" {
  name   = "AWSLoadBalancerControllerPolicy-sgp"
  policy = file("${path.module}/policies/lb-controller-policy.json")
  tags   = { Project = var.app_name, Region = "sgp" }
}

resource "aws_iam_role_policy_attachment" "attach_secrets"    { role = aws_iam_role.pod_role.name; policy_arn = aws_iam_policy.secrets.arn }
resource "aws_iam_role_policy_attachment" "attach_cloudwatch" { role = aws_iam_role.pod_role.name; policy_arn = aws_iam_policy.cloudwatch.arn }
resource "aws_iam_role_policy_attachment" "attach_dynamodb"   { role = aws_iam_role.pod_role.name; policy_arn = aws_iam_policy.dynamodb.arn }
resource "aws_iam_role_policy_attachment" "attach_sqs"        { role = aws_iam_role.pod_role.name; policy_arn = aws_iam_policy.sqs.arn }
resource "aws_iam_role_policy_attachment" "attach_lb"         { role = aws_iam_role.pod_role.name; policy_arn = aws_iam_policy.lb_controller.arn }

# Karpenter role

data "aws_iam_policy_document" "karpenter_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_id}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter-sa"]
    }
  }
}

resource "aws_iam_role" "karpenter" {
  name               = "${var.app_name}-karpenter-role-sgp"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume.json
  tags               = { Project = var.app_name, Region = "sgp" }
}

resource "aws_iam_policy" "karpenter" {
  name = "${var.app_name}-karpenter-policy-sgp"
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
        "eks:DescribeCluster", "ssm:GetParameter"
      ]
      Resource = "*"
    }]
  })
  tags = { Project = var.app_name, Region = "sgp" }
}

resource "aws_iam_role_policy_attachment" "karpenter" {
  role       = aws_iam_role.karpenter.name
  policy_arn = aws_iam_policy.karpenter.arn
}
