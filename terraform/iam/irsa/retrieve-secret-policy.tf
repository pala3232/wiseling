resource "aws_iam_policy" "external_secrets_read_secret" {
  name = "external-secrets-read-secret"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:ap-southeast-2:359707702022:secret:wiseling-jwt-secret-key-*",
          "arn:aws:secretsmanager:ap-southeast-2:359707702022:secret:wiseling/db-urls-*"
        ]
      }
    ]
  })
}