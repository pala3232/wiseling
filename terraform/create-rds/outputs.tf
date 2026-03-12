output "rds_instance_id" {
  value = aws_db_instance.wiseling-rds-instance.id
}

output "rds_endpoint" {
  value = aws_db_instance.wiseling-rds-instance.endpoint
}

output "rds_port" {
  value = aws_db_instance.wiseling-rds-instance.port
}