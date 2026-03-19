terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  required_version = ">= 1.3.0"
  backend "s3" {
    # Preserves state key from the original layers-dr/03-iam-sgp (renumbered 03→04)
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/03-iam-sgp/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

provider "aws" { region = "ap-southeast-1" }

data "terraform_remote_state" "eks_dr" {
  backend = "s3"
  config = {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/04-eks-sgp/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

module "iam" {
  source            = "../../../modules/iam"
  app_name          = "wiseling"
  aws_region        = "ap-southeast-1"
  account_id        = "359707702022"
  oidc_provider_arn = data.terraform_remote_state.eks_dr.outputs.oidc_provider_arn
  eks_cluster_id    = data.terraform_remote_state.eks_dr.outputs.eks_cluster_id
  name_suffix       = "-sgp"
}

output "pod_role_arn"       { value = module.iam.pod_role_arn }
output "karpenter_role_arn" { value = module.iam.karpenter_role_arn }
