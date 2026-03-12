terraform {

  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "create-sqs/terraform.tfstate"
    region = "ap-southeast-2"

  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }

}

provider "aws" {
  region = var.aws_region
}

resource "aws_sqs_queue" "wiseling_conversions_dlq" {
  name                      = "${var.app_name}-conversions-dlq"
  message_retention_seconds = 1209600
  tags = { "project" = var.app_name }
}

resource "aws_sqs_queue" "wiseling_conversions" {
  name = "${var.app_name}-conversions"
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.wiseling_conversions_dlq.arn
    maxReceiveCount     = 3
  })
  tags = { "project" = var.app_name }
}

resource "aws_sqs_queue" "wiseling_withdrawals_dlq" {
  name                      = "${var.app_name}-withdrawals-dlq"
  message_retention_seconds = 1209600
  tags = { "project" = var.app_name }
}

resource "aws_sqs_queue" "wiseling_withdrawals" {
  name = "${var.app_name}-withdrawals"
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.wiseling_withdrawals_dlq.arn
    maxReceiveCount     = 3
  })
  tags = { "project" = var.app_name }
}
