# VPC needs to be provisioned first before this module can be applied.
terraform {


  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

}



resource "aws_db_subnet_group" "wiseling" {
  name       = "wiseling-subnet-group"
  subnet_ids = var.private_subnet_ids
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
  vpc_security_group_ids = [var.rds_sg_id]
    tags = {
        Name    = "wiseling-rds-instance"
        Project = var.app_name
    }
}