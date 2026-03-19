terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  required_version = ">= 1.3.0"
  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/01-network/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

provider "aws" { region = "ap-southeast-2" }

module "network" {
  source       = "../../../modules/network"
  app_name     = "wiseling"
  cluster_name = "wiseling-eks-cluster"
  vpc_cidr     = "10.0.0.0/16"
  az_1         = "ap-southeast-2a"
  az_2         = "ap-southeast-2b"
  pub_cidr_1   = "10.0.1.0/24"
  pub_cidr_2   = "10.0.2.0/24"
  priv_cidr_1  = "10.0.3.0/24"
  priv_cidr_2  = "10.0.4.0/24"
  aws_region   = "ap-southeast-2"
  enable_dynamodb_endpoint = true
}

output "vpc_id"                 { value = module.network.vpc_id }
output "all_public_subnet_ids"  { value = module.network.all_public_subnet_ids }
output "all_private_subnet_ids" { value = module.network.all_private_subnet_ids }
output "public_subnet_id"       { value = module.network.public_subnet_id }
output "public_subnet_2_id"     { value = module.network.public_subnet_2_id }
output "private_subnet_id"      { value = module.network.private_subnet_id }
output "private_subnet_2_id"    { value = module.network.private_subnet_2_id }
output "rds_sg_id"              { value = module.network.rds_sg_id }
output "eks_nodes_sg_id"        { value = module.network.eks_nodes_sg_id }
output "eks_cluster_sg_id"      { value = module.network.eks_cluster_sg_id }
output "private_route_table_id" { value = module.network.private_route_table_id }
