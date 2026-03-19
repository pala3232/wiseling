terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  required_version = ">= 1.3.0"
  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/02-data-sgp/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

# All resources in this layer live in the DR region
provider "aws" { region = "ap-southeast-1" }

data "terraform_remote_state" "network_dr" {
  backend = "s3"
  config = {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/01-network-sgp/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

# Primary RDS ARN — needed to create the cross-region read replica
data "terraform_remote_state" "data_primary" {
  backend = "s3"
  config = {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/02-data/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

module "data" {
  source             = "../../../modules/data-replica"
  app_name           = "wiseling"
  db_password        = var.db_password
  private_subnet_ids = data.terraform_remote_state.network_dr.outputs.all_private_subnet_ids
  rds_sg_id          = data.terraform_remote_state.network_dr.outputs.rds_sg_id
  primary_rds_arn    = try(data.terraform_remote_state.data_primary.outputs.rds_arn, "")
}

output "replica_endpoint"      { value = module.data.replica_endpoint }
output "conversions_queue_url" { value = module.data.conversions_queue_url }
output "withdrawals_queue_url" { value = module.data.withdrawals_queue_url }
