terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  required_version = ">= 1.3.0"
  backend "s3" {
    # Keeping the original key so existing ECR state is reused without migration
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/00-ecr/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

provider "aws" { region = "ap-southeast-2" }

# ── ECR ───────────────────────────────────────────────────────────────────────

locals {
  services = toset([
    "auth-service",
    "wallet-service",
    "conversion-service",
    "withdrawal-service",
    "frontend",
    "locust",
  ])
}

resource "aws_ecr_repository" "services" {
  for_each = local.services

  name                 = "wiseling/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { project = "wiseling" }

  lifecycle {
    prevent_destroy = true
  }
}

# ── GitHub Actions OIDC ───────────────────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # AWS no longer validates thumbprints for GitHub, but the field is required
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
  tags = { project = "wiseling" }
}

resource "aws_iam_role" "github_actions" {
  name = "wiseling-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { project = "wiseling" }
}

resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "ecr_repo_urls" {
  value = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
