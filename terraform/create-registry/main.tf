terraform {

  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "create-registry/terraform.tfstate"
    region = "ap-southeast-2"

  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
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
    "withdrawal-processor"
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