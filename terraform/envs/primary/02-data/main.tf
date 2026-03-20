terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  required_version = ">= 1.3.0"
  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/02-data/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

provider "aws" { region = "ap-southeast-2" }

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/01-network/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

module "data" {
  source                  = "../../../modules/data-primary"
  app_name                = "wiseling"
  db_password             = var.db_password
  private_subnet_ids      = data.terraform_remote_state.network.outputs.all_private_subnet_ids
  rds_sg_id               = data.terraform_remote_state.network.outputs.rds_sg_id
  dynamodb_replica_region = "ap-southeast-1"
}

output "rds_endpoint"          { value = module.data.rds_endpoint }
output "rds_instance_id"       { value = module.data.rds_instance_id }
output "rds_arn"               { value = module.data.rds_arn }
output "rds_identifier"        { value = module.data.rds_identifier }
output "conversions_queue_url" { value = module.data.conversions_queue_url }
output "withdrawals_queue_url" { value = module.data.withdrawals_queue_url }
output "dynamodb_table_name"   { value = module.data.dynamodb_table_name }
