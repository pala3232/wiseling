terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"

  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/01-network/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

provider "aws" {
  region = var.aws_region
}

# VPC and subnets

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name                     = "${var.app_name}-vpc"
    Project                  = var.app_name
    "karpenter.sh/discovery" = "wiseling-eks-cluster"
  }
}

# Subnets  

resource "aws_subnet" "public" {
  map_public_ip_on_launch = true
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-southeast-2a"
  tags = {
    Name                                         = "${var.app_name}-public-subnet"
    Project                                      = var.app_name
    "karpenter.sh/discovery"                     = "wiseling-eks-cluster"
    "kubernetes.io/role/elb"                     = "1"
    "kubernetes.io/cluster/wiseling-eks-cluster" = "shared"
  }
}

resource "aws_subnet" "public_2" {
  map_public_ip_on_launch = true
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-southeast-2b"
  tags = {
    Name                                         = "${var.app_name}-public-subnet-2"
    Project                                      = var.app_name
    "karpenter.sh/discovery"                     = "wiseling-eks-cluster"
    "kubernetes.io/role/elb"                     = "1"
    "kubernetes.io/cluster/wiseling-eks-cluster" = "shared"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "ap-southeast-2a"
  tags = {
    Name                                         = "${var.app_name}-private-subnet"
    Project                                      = var.app_name
    "karpenter.sh/discovery"                     = "wiseling-eks-cluster"
    "kubernetes.io/role/internal-elb"            = "1"
    "kubernetes.io/cluster/wiseling-eks-cluster" = "shared"
  }
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "ap-southeast-2b"
  tags = {
    Name                                         = "${var.app_name}-private-subnet-2"
    Project                                      = var.app_name
    "karpenter.sh/discovery"                     = "wiseling-eks-cluster"
    "kubernetes.io/role/internal-elb"            = "1"
    "kubernetes.io/cluster/wiseling-eks-cluster" = "shared"
  }
}

# Gateways & routing

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.app_name}-igw", Project = var.app_name }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.app_name}-nat-eip", Project = var.app_name }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${var.app_name}-nat-gw", Project = var.app_name }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.app_name}-public-rt", Project = var.app_name }
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.app_name}-private-rt", Project = var.app_name }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.ap-southeast-2.dynamodb"
  route_table_ids = [aws_route_table.public.id, aws_route_table.private.id]
  tags = { Project = var.app_name }
}

# Security groups

resource "aws_security_group" "eks_nodes" {
  name   = "wiseling-eks-nodes-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                     = "wiseling-eks-nodes-sg"
    "karpenter.sh/discovery" = "wiseling-eks-cluster"
  }
}

resource "aws_security_group" "eks_cluster" {
  name   = "wiseling-eks-cluster-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "wiseling-eks-cluster-sg", Project = var.app_name }
}

resource "aws_security_group" "rds" {
    tags = { Name = "wiseling-rds-sg", Project = var.app_name }
  name   = "wiseling-rds-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
