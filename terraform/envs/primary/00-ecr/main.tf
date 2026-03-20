terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  required_version = ">= 1.3.0"
  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/00-ecr/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

provider "aws" { region = "ap-southeast-2" }

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
    scan_on_push = false
  }

  tags = { project = "wiseling" }

  lifecycle {
    prevent_destroy = true
  }
}

output "ecr_repo_urls" {
  value = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}
