terraform {
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    tls        = { source = "hashicorp/tls", version = "~> 4.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
  }
  required_version = ">= 1.3.0"
  backend "s3" {
    # Preserves state key from the original layers-dr/04-eks-sgp (renumbered 04→03)
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/04-eks-sgp/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

provider "aws" { region = "ap-southeast-1" }

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_cert)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", "wiseling-eks-cluster-sgp", "--region", "ap-southeast-1"]
  }
}

data "terraform_remote_state" "network_dr" {
  backend = "s3"
  config = {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/01-network-sgp/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

module "eks" {
  source              = "../../../modules/eks"
  app_name            = "wiseling"
  cluster_name        = "wiseling-eks-cluster-sgp"
  public_subnet_ids   = data.terraform_remote_state.network_dr.outputs.all_public_subnet_ids
  private_subnet_2_id = data.terraform_remote_state.network_dr.outputs.private_subnet_2_id
  eks_cluster_sg_id   = data.terraform_remote_state.network_dr.outputs.eks_cluster_sg_id
  eks_nodes_sg_id     = data.terraform_remote_state.network_dr.outputs.eks_nodes_sg_id
  admin_iam_arn       = var.admin_iam_arn
  aws_region          = "ap-southeast-1"
  name_suffix         = "-sgp"
}

resource "kubernetes_annotations" "aws_node" {
  depends_on  = [module.eks]
  api_version = "v1"
  kind        = "ServiceAccount"
  metadata {
    name      = "aws-node"
    namespace = "kube-system"
  }
  lifecycle { ignore_changes = all }
  annotations = {
    "eks.amazonaws.com/role-arn" = module.eks.vpc_cni_role_arn
  }
}

output "eks_cluster_id"       { value = module.eks.eks_cluster_id }
output "oidc_provider_arn"    { value = module.eks.oidc_provider_arn }
output "eks_cluster_name"     { value = module.eks.cluster_name }
output "eks_cluster_endpoint" { value = module.eks.cluster_endpoint }
