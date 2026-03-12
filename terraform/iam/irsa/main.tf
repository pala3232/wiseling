# provisions IAM role for IRSA on the cluster
terraform {

  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "create-iam/terraform.tfstate"
    region = "ap-southeast-2"

  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"

}

provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "create-eks/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [data.terraform_remote_state.eks.outputs.oidc_provider_arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "oidc.eks.ap-southeast-2.amazonaws.com/id/${data.terraform_remote_state.eks.outputs.eks_cluster_id}:sub"
      values   = ["system:serviceaccount:wiseling:wiseling-sa", "system:serviceaccount:kube-system:wiseling-sa"]
    }
  }
}

resource "aws_iam_role" "pod_role" {
  name               = "pod-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

resource "aws_iam_role_policy_attachment" "attach-secrets" {
  role       = aws_iam_role.pod_role.name
  policy_arn = aws_iam_policy.external_secrets_read_secret.arn
}

resource "aws_iam_role_policy_attachment" "attach-cloudwatch" {
  role       = aws_iam_role.pod_role.name
  policy_arn = aws_iam_policy.cloudwatch-policy.arn
}

resource "aws_iam_role_policy_attachment" "attach-dynamodb" {
  role       = aws_iam_role.pod_role.name
  policy_arn = aws_iam_policy.dynamodb-policy.arn
}

resource "aws_iam_role_policy_attachment" "attach-sqs" {
  role       = aws_iam_role.pod_role.name
  policy_arn = aws_iam_policy.sqs_policy.arn
}

resource "aws_iam_policy" "aws_lb_controller" {
  name   = "AWSLoadBalancerControllerPolicy"
  policy = file("${path.module}/policies/lb-controller-policy.json")
}

resource "aws_iam_role_policy_attachment" "aws_lb_controller" {
  role       = aws_iam_role.pod_role.name
  policy_arn = aws_iam_policy.aws_lb_controller.arn
}

resource "aws_iam_role" "karpenter" {
  name = "wiseling-karpenter-role"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume.json
}

data "aws_iam_policy_document" "karpenter_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [data.terraform_remote_state.eks.outputs.oidc_provider_arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "oidc.eks.ap-southeast-2.amazonaws.com/id/${data.terraform_remote_state.eks.outputs.eks_cluster_id}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter-sa"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "karpenter" {
  role       = aws_iam_role.karpenter.name
  policy_arn = aws_iam_policy.karpenter.arn
}