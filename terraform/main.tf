terraform {
  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "root/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

module "jwt_secret_key" {
  source = "./jwt-secret-key"
}
module "main_vpc" {
  source = "./main-vpc"
}

module "create_dynamodb" {
  source = "./create-dynamodb"
}

module "create_sqs" {
  source = "./create-sqs"
}

module "create_registry" {
  source = "./create-registry"
}


module "create_eks" {
  source             = "./create-eks"
  vpc_id             = module.main_vpc.vpc_id
  public_subnet_ids  = module.main_vpc.all_public_subnet_ids
  private_subnet_ids = module.main_vpc.all_private_subnet_ids  
  eks_cluster_sg_id  = module.main_vpc.eks_cluster_sg_id
  eks_nodes_sg_id    = module.main_vpc.eks_nodes_sg_id
}



module "iam_irsa" {
  source = "./iam/irsa"
  oidc_provider_arn = module.create_eks.oidc_provider_arn
  eks_cluster_id    = module.create_eks.eks_cluster_id
}

module "create_rds" {
  source = "./create-rds"
  private_subnet_ids = module.main_vpc.all_private_subnet_ids
  rds_sg_id = module.main_vpc.rds_sg_id
}
