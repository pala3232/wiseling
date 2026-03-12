resource "aws_iam_policy" "dynamodb-policy" {
  name        = "dynamodb-policy"
  description = "Allow read access to DynamoDB tables"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem"
        ]
        Resource = "arn:aws:dynamodb:ap-southeast-2:359707702022:table/wiseling-outbox"
      }
    ]
  })
}