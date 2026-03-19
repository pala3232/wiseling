output "rds_endpoint"          { value = aws_db_instance.main.endpoint }
output "rds_instance_id"       { value = aws_db_instance.main.id }
output "rds_arn"               { value = aws_db_instance.main.arn }
output "rds_identifier"        { value = aws_db_instance.main.identifier }
output "conversions_queue_url" { value = aws_sqs_queue.conversions.url }
output "withdrawals_queue_url" { value = aws_sqs_queue.withdrawals.url }
output "dynamodb_table_name"   { value = aws_dynamodb_table.outbox.name }
output "ecr_repo_urls"         { value = { for k, v in aws_ecr_repository.services : k => v.repository_url } }
