resource "aws_iam_policy" "sqs_policy" {
  name = "wiseling-sqs-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ]
      Resource = [
        "arn:aws:sqs:ap-southeast-2:359707702022:wiseling-conversions",
        "arn:aws:sqs:ap-southeast-2:359707702022:wiseling-withdrawals"
      ]
    }]
  })
}