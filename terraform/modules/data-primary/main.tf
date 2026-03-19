resource "aws_db_subnet_group" "main" {
  name       = "${var.app_name}-subnet-group"
  subnet_ids = var.private_subnet_ids
  tags       = { Project = var.app_name }
}

resource "aws_db_instance" "main" {
  allocated_storage       = 10
  db_name                 = var.app_name
  engine                  = "postgres"
  engine_version          = "16"
  instance_class          = "db.t3.micro"
  username                = "admin1"
  password                = var.db_password
  parameter_group_name    = "default.postgres16"
  skip_final_snapshot     = true
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [var.rds_sg_id]
  backup_retention_period = 1
  tags = {
    Name    = "${var.app_name}-rds-instance"
    Project = var.app_name
  }
}

resource "aws_secretsmanager_secret" "db_urls" {
  name                    = "${var.app_name}/db-urls"
  recovery_window_in_days = 0
  tags                    = { Project = var.app_name }
}

resource "aws_secretsmanager_secret_version" "db_urls" {
  secret_id = aws_secretsmanager_secret.db_urls.id
  secret_string = jsonencode({
    auth       = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.main.endpoint}/${var.app_name}"
    wallet     = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.main.endpoint}/${var.app_name}"
    conversion = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.main.endpoint}/${var.app_name}"
    withdrawal = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.main.endpoint}/${var.app_name}"
  })
}

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

resource "aws_dynamodb_table" "outbox" {
  name             = "${var.app_name}-outbox"
  hash_key         = "pk"
  range_key        = "sk"
  billing_mode     = "PAY_PER_REQUEST"
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"
  tags             = { Project = var.app_name }

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
    region_name = var.dynamodb_replica_region
  }
}

resource "aws_ecr_repository" "services" {
  for_each = toset([
    "auth-service",
    "wallet-service",
    "conversion-service",
    "withdrawal-service",
    "frontend",
    "locust"
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

resource "aws_secretsmanager_secret" "jwt" {
  name                    = "${var.app_name}-jwt-secret-key"
  description             = "JWT secret key for ${var.app_name}"
  recovery_window_in_days = 0
  tags                    = { project = var.app_name }
}
