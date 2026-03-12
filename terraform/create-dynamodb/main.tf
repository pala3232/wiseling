terraform {

  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "create-dynamodb/terraform.tfstate"
    region = "ap-southeast-2"

  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"

}

provider "aws" {
  alias  = "ap_southeast_2"
  region = "ap-southeast-2"
}

resource "aws_dynamodb_table" "wiseling-outbox" {
  provider = aws.ap_southeast_2

  name             = "wiseling-outbox"
  hash_key         = "pk"
  range_key    = "sk"
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"
  billing_mode = "PAY_PER_REQUEST"

    attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled = true
  }

  replica {
    region_name = "ap-southeast-1"
  }
}