terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"

  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/02-data/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

provider "aws" {
  region = var.aws_region
}

# Read network outputs from remote state
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/01-network/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

#  RDS and related resources

resource "aws_db_subnet_group" "wiseling" {
  name       = "wiseling-subnet-group"
  subnet_ids = data.terraform_remote_state.network.outputs.all_private_subnet_ids
  tags = { Project = var.app_name }
}

resource "aws_db_instance" "wiseling" {
  allocated_storage      = 10
  db_name                = "wiseling"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = "db.t3.micro"
  username               = "admin1"
  password               = var.db_password
  parameter_group_name   = "default.postgres16"
  skip_final_snapshot    = true
  db_subnet_group_name   = aws_db_subnet_group.wiseling.name
  vpc_security_group_ids = [data.terraform_remote_state.network.outputs.rds_sg_id]
  tags = {
    Name    = "wiseling-rds-instance"
    Project = var.app_name
  }
}

resource "aws_secretsmanager_secret" "db_urls" {
  name                    = "wiseling/db-urls"
  recovery_window_in_days = 0
  tags = { Project = var.app_name }
}

resource "aws_secretsmanager_secret_version" "db_urls" {
  secret_id     = aws_secretsmanager_secret.db_urls.id
  secret_string = jsonencode({
    auth       = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.wiseling.endpoint}/wiseling"
    wallet     = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.wiseling.endpoint}/wiseling"
    conversion = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.wiseling.endpoint}/wiseling"
    withdrawal = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.wiseling.endpoint}/wiseling"
  })
}

# SQS queues and DynamoDB table are defined in the network layer as they are not tightly coupled to the RDS instance and can be used by other resources as well.

resource "aws_sqs_queue" "conversions_dlq" {
  name                      = "${var.app_name}-conversions-dlq"
  message_retention_seconds = 1209600
  tags                      = { project = var.app_name }
}

resource "aws_sqs_queue" "conversions" {
  name = "${var.app_name}-conversions"
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.conversions_dlq.arn
    maxReceiveCount     = 3
  })
  tags = { project = var.app_name }
}

resource "aws_sqs_queue" "withdrawals_dlq" {
  name                      = "${var.app_name}-withdrawals-dlq"
  message_retention_seconds = 1209600
  tags                      = { project = var.app_name }
}

resource "aws_sqs_queue" "withdrawals" {
  name = "${var.app_name}-withdrawals"
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.withdrawals_dlq.arn
    maxReceiveCount     = 3
  })
  tags = { project = var.app_name }
}

# DynamoDB table for outbox pattern, used by all services to store events before processing

resource "aws_dynamodb_table" "outbox" {
  name             = "wiseling-outbox"
  hash_key         = "pk"
  range_key        = "sk"
  billing_mode     = "PAY_PER_REQUEST"
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"
  tags = { Project = var.app_name }

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  replica {
    region_name = "ap-southeast-1"
  }
}

# ECR (prevent_destroy keeps repos even on full destroy) 

resource "aws_ecr_repository" "services" {
  for_each = toset([
    "auth-service",
    "wallet-service",
    "conversion-service",
    "withdrawal-service",
    "frontend"
  ])

  name                 = "${var.app_name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = { project = var.app_name }

  lifecycle {
    prevent_destroy = true
  }
}

# JWT secret 

resource "aws_secretsmanager_secret" "jwt" {
  name                    = "${var.app_name}-jwt-secret-key"
  description             = "JWT secret key for ${var.app_name}"
  recovery_window_in_days = 0
  tags                    = { project = var.app_name }
}
