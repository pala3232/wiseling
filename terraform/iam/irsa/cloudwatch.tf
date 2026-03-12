resource "aws_iam_policy" "cloudwatch-policy" {
  name        = "cloudwatch-policy"
  description = "Allow read access to CloudWatch metrics"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics"
        ]
        Resource = "*"
      }
    ]
  })
}