terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

# IAM roles for EKS

resource "aws_iam_role" "eks_cluster" {
  name = "${var.app_name}-eks-cluster-role${var.name_suffix}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "eks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = { Project = var.app_name }
}

resource "aws_iam_role" "eks_node" {
  name = "${var.app_name}-eks-node-role${var.name_suffix}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = { Project = var.app_name }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "node_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cni_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# EKS cluster

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids         = var.public_subnet_ids
    security_group_ids = [var.eks_cluster_sg_id]
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags       = { Name = var.cluster_name, Project = var.app_name }
  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# OIDC

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# VPC CNI IRSA

resource "aws_iam_role" "vpc_cni" {
  name = "${var.app_name}-vpc-cni-role${var.name_suffix}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-node"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
  tags = { Project = var.app_name }
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Launch templates

resource "aws_launch_template" "eks_nodes" {
  name_prefix = "eks-nodes${var.name_suffix}-"
  network_interfaces {
    associate_public_ip_address = false
    delete_on_termination       = true
    security_groups             = [var.eks_nodes_sg_id]
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  tags = { Project = var.app_name }
}

resource "aws_launch_template" "karpenter" {
  name_prefix = "karpenter${var.name_suffix}-"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  tags = { Project = var.app_name }
}

# Bootstrap node group

resource "aws_eks_node_group" "bootstrap" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "bootstrap"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = [var.private_subnet_2_id]
  depends_on      = [aws_eks_cluster.main]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  instance_types = ["t3.large"]

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  tags = { Name = "${var.app_name}-bootstrap-node${var.name_suffix}", Project = var.app_name }
}

# Admin access entry

resource "aws_eks_access_entry" "admin" {
  count         = var.admin_iam_arn != "" ? 1 : 0
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.admin_iam_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  count         = var.admin_iam_arn != "" ? 1 : 0
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.admin_iam_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope  { type = "cluster" }
}
