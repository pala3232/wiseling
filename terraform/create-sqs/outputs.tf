output "conversions_queue_url" {
  value = aws_sqs_queue.wiseling_conversions.url
}

output "withdrawals_queue_url" {
  value = aws_sqs_queue.wiseling_withdrawals.url
}