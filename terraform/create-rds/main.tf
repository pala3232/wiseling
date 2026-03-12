# VPC needs to be provisioned first before this module can be applied.
terraform {

  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "create-rds/terraform.tfstate"
    region = "ap-southeast-2"

  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

}

data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "main-vpc/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

resource "aws_db_subnet_group" "wiseling" {
  name       = "wiseling-subnet-group"
  subnet_ids = [
    data.terraform_remote_state.vpc.outputs.private_subnet_id,
    data.terraform_remote_state.vpc.outputs.private_subnet_2_id
  ]
}


provider "aws" {
  region = var.aws_region
}

resource "aws_db_instance" "wiseling-rds-instance" {
  allocated_storage    = 10
  db_name              = "wiseling"
  engine               = "postgres"
  engine_version       = "16"
  instance_class       = "db.t3.micro"
  username             = "admin1"
  password             = var.db_password
  parameter_group_name = "default.postgres16"
  skip_final_snapshot  = true
  db_subnet_group_name = aws_db_subnet_group.wiseling.name
  vpc_security_group_ids = [data.terraform_remote_state.vpc.outputs.rds_sg_id]
    tags = {
        Name    = "wiseling-rds-instance"
        Project = var.app_name
    }
}