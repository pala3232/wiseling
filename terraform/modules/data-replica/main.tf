resource "aws_db_subnet_group" "main" {
  name       = "${var.app_name}-subnet-group-sgp"
  subnet_ids = var.private_subnet_ids
  tags       = { Project = var.app_name }
}

# Cross-region read replica — points at primary RDS ARN
resource "aws_db_instance" "replica" {
  identifier             = "${var.app_name}-rds-replica-sgp"
  replicate_source_db    = var.primary_rds_arn
  instance_class         = "db.t3.micro"
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]
  skip_final_snapshot    = true
  publicly_accessible    = false
  # Required by Terraform but ignored on read replicas; used after promotion
  parameter_group_name   = "default.postgres16"
  tags = {
    Name    = "${var.app_name}-rds-replica-sgp"
    Project = var.app_name
    Role    = "read-replica"
  }
}

# Placeholder secret — updated by failover workflow after promotion
resource "aws_secretsmanager_secret" "db_urls" {
  name                    = "${var.app_name}/db-urls-sgp"
  recovery_window_in_days = 0
  tags                    = { Project = var.app_name }
}

resource "aws_secretsmanager_secret_version" "db_urls" {
  secret_id = aws_secretsmanager_secret.db_urls.id
  # Points at replica endpoint — read-only until failover promotes it
  secret_string = jsonencode({
    auth       = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.replica.endpoint}/${var.app_name}"
    wallet     = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.replica.endpoint}/${var.app_name}"
    conversion = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.replica.endpoint}/${var.app_name}"
    withdrawal = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.replica.endpoint}/${var.app_name}"
  })
}

resource "aws_secretsmanager_secret" "jwt" {
  name                    = "${var.app_name}-jwt-secret-key-sgp"
  description             = "JWT secret key mirror for ${var.app_name} DR region"
  recovery_window_in_days = 0
  tags                    = { project = var.app_name }
}

resource "aws_sqs_queue" "conversions" {
  name                       = "${var.app_name}-conversions"
  message_retention_seconds  = 86400
  visibility_timeout_seconds = 30
  tags                       = { Project = var.app_name }
}

resource "aws_sqs_queue" "withdrawals" {
  name                       = "${var.app_name}-withdrawals"
  message_retention_seconds  = 86400
  visibility_timeout_seconds = 30
  tags                       = { Project = var.app_name }
}
