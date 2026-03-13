resource "aws_secretsmanager_secret" "db_urls" {
  name = "wiseling/db-urls"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_urls" {
  secret_id     = aws_secretsmanager_secret.db_urls.id
  secret_string = jsonencode({
    auth       = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.wiseling-rds-instance.endpoint}/wiseling"
    wallet     = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.wiseling-rds-instance.endpoint}/wiseling"
    conversion = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.wiseling-rds-instance.endpoint}/wiseling"
    withdrawal = "postgresql+asyncpg://admin1:${var.db_password}@${aws_db_instance.wiseling-rds-instance.endpoint}/wiseling"
  })
}