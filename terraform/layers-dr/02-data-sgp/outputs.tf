output "replica_endpoint" {
  value = aws_db_instance.wiseling_replica.endpoint
}

output "replica_identifier" {
  value = aws_db_instance.wiseling_replica.identifier
}

output "db_urls_secret_arn" {
  value = aws_secretsmanager_secret.db_urls_sgp.arn
}

