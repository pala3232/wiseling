terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  required_version = ">= 1.3.0"
  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/02-data-sgp/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

# Primary region provider (for reading primary RDS identifier)
provider "aws" {
  alias  = "primary"
  region = "ap-southeast-2"
}

# DR region provider
provider "aws" {
  alias  = "dr"
  region = var.aws_region
}

data "terraform_remote_state" "network_sgp" {
  backend = "s3"
  config = {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/01-network-sgp/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

data "terraform_remote_state" "data_primary" {
  backend = "s3"
  config = {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/02-data/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

# RDS subnet group in Singapore
resource "aws_db_subnet_group" "wiseling_sgp" {
  provider   = aws.dr
  name       = "${var.app_name}-subnet-group-sgp"
  subnet_ids = data.terraform_remote_state.network_sgp.outputs.all_private_subnet_ids
  tags       = { Project = var.app_name, Region = "sgp" }
}

# Cross-region read replica — points at primary RDS
resource "aws_db_instance" "wiseling_replica" {
  provider               = aws.dr
  identifier             = "${var.app_name}-rds-replica-sgp"
  replicate_source_db    = data.terraform_remote_state.data_primary.outputs.rds_arn
  instance_class         = "db.t3.micro"
  db_subnet_group_name   = aws_db_subnet_group.wiseling_sgp.name
  vpc_security_group_ids = [data.terraform_remote_state.network_sgp.outputs.rds_sg_id]
  skip_final_snapshot    = true
  publicly_accessible    = false

  # These are ignored on read replicas but required by Terraform
  # They will be used after promotion
  parameter_group_name = "default.postgres16"

  tags = {
    Name    = "${var.app_name}-rds-replica-sgp"
    Project = var.app_name
    Role    = "read-replica"
  }
}

# Placeholder secret — updated by failover workflow after promotion
resource "aws_secretsmanager_secret" "db_urls_sgp" {
  provider                = aws.dr
  name                    = "${var.app_name}/db-urls-sgp"
  recovery_window_in_days = 0
  tags                    = { Project = var.app_name, Region = "sgp" }
}

resource "aws_secretsmanager_secret_version" "db_urls_sgp" {
  provider  = aws.dr
  secret_id = aws_secretsmanager_secret.db_urls_sgp.id
  # Points at replica endpoint — read-only until failover promotes it
  secret_string = jsonencode({
    auth       = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.wiseling_replica.endpoint}/wiseling"
    wallet     = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.wiseling_replica.endpoint}/wiseling"
    conversion = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.wiseling_replica.endpoint}/wiseling"
    withdrawal = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.wiseling_replica.endpoint}/wiseling"
  })
}

# JWT secret mirror in Singapore
resource "aws_secretsmanager_secret" "jwt_sgp" {
  provider                = aws.dr
  name                    = "${var.app_name}-jwt-secret-key-sgp"
  description             = "JWT secret key mirror for ${var.app_name} DR region"
  recovery_window_in_days = 0
  tags                    = { project = var.app_name, Region = "sgp" }
}

# ── SQS Queues ────────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "conversions_dr" {
  provider                  = aws.dr
  name                      = "wiseling-conversions"
  message_retention_seconds = 86400
  visibility_timeout_seconds = 30
  tags                      = { Project = var.app_name, Region = "dr" }
}

resource "aws_sqs_queue" "withdrawals_dr" {
  provider                  = aws.dr
  name                      = "wiseling-withdrawals"
  message_retention_seconds = 86400
  visibility_timeout_seconds = 30
  tags                      = { Project = var.app_name, Region = "dr" }
}