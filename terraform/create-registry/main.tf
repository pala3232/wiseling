terraform {


  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

}

provider "aws" {
  region = var.aws_region
}

resource "aws_ecr_repository" "wiseling-ecr-repo" {
  for_each = toset([
    "auth-service",
    "wallet-service",
    "conversion-service",
    "withdrawal-service",
    "withdrawal-processor",
    "frontend"
  ])
  name                 = "${var.app_name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }
  tags = {
    "project" = var.app_name
  }

}