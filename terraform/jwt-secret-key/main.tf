terraform {

  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "jwt-secret-key/terraform.tfstate"
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

resource "aws_secretsmanager_secret" "jwt-secret-key" {
  name        = "${var.app_name}-jwt-secret-key"
  description = "JWT secret key for ${var.app_name}"
  tags = {
    "project" = var.app_name
  }
}