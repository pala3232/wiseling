terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  required_version = ">= 1.3.0"
  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "layers/01-network-sgp/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

provider "aws" { region = var.aws_region }

resource "aws_vpc" "main" {
  cidr_block           = "10.1.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name                     = "${var.app_name}-vpc-sgp"
    Project                  = var.app_name
    "karpenter.sh/discovery" = "${var.app_name}-eks-cluster-sgp"
  }
}

resource "aws_subnet" "public" {
  map_public_ip_on_launch = true
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.1.1.0/24"
  availability_zone       = "ap-southeast-1a"
  tags = {
    Name                                                    = "${var.app_name}-public-subnet-sgp"
    Project                                                 = var.app_name
    "karpenter.sh/discovery"                                = "${var.app_name}-eks-cluster-sgp"
    "kubernetes.io/role/elb"                                = "1"
    "kubernetes.io/cluster/${var.app_name}-eks-cluster-sgp" = "shared"
  }
}

resource "aws_subnet" "public_2" {
  map_public_ip_on_launch = true
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.1.2.0/24"
  availability_zone       = "ap-southeast-1b"
  tags = {
    Name                                                    = "${var.app_name}-public-subnet-2-sgp"
    Project                                                 = var.app_name
    "karpenter.sh/discovery"                                = "${var.app_name}-eks-cluster-sgp"
    "kubernetes.io/role/elb"                                = "1"
    "kubernetes.io/cluster/${var.app_name}-eks-cluster-sgp" = "shared"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.1.3.0/24"
  availability_zone = "ap-southeast-1a"
  tags = {
    Name                                                    = "${var.app_name}-private-subnet-sgp"
    Project                                                 = var.app_name
    "karpenter.sh/discovery"                                = "${var.app_name}-eks-cluster-sgp"
    "kubernetes.io/role/internal-elb"                       = "1"
    "kubernetes.io/cluster/${var.app_name}-eks-cluster-sgp" = "shared"
  }
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.1.4.0/24"
  availability_zone = "ap-southeast-1b"
  tags = {
    Name                                                    = "${var.app_name}-private-subnet-2-sgp"
    Project                                                 = var.app_name
    "karpenter.sh/discovery"                                = "${var.app_name}-eks-cluster-sgp"
    "kubernetes.io/role/internal-elb"                       = "1"
    "kubernetes.io/cluster/${var.app_name}-eks-cluster-sgp" = "shared"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.app_name}-igw-sgp", Project = var.app_name }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.app_name}-nat-eip-sgp", Project = var.app_name }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${var.app_name}-nat-gw-sgp", Project = var.app_name }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.app_name}-public-rt-sgp", Project = var.app_name }
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.app_name}-private-rt-sgp", Project = var.app_name }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "public" { 
  subnet_id = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "public_2"  { 
  subnet_id = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "private"   { 
  subnet_id = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
resource "aws_route_table_association" "private_2" { 
  subnet_id = aws_subnet.private_2.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "eks_nodes" {
  name   = "${var.app_name}-eks-nodes-sg-sgp"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 0; to_port = 0; protocol = "-1"; self = true }
  ingress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["10.1.0.0/16"] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags = {
    Name                     = "${var.app_name}-eks-nodes-sg-sgp"
    "karpenter.sh/discovery" = "${var.app_name}-eks-cluster-sgp"
  }
}

resource "aws_security_group" "eks_cluster" {
  name   = "${var.app_name}-eks-cluster-sg-sgp"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["10.1.0.0/16"] }
  egress  { from_port = 0;   to_port = 0;   protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "${var.app_name}-eks-cluster-sg-sgp", Project = var.app_name }
}

resource "aws_security_group" "rds" {
  name   = "${var.app_name}-rds-sg-sgp"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 5432; to_port = 5432; protocol = "tcp"; security_groups = [aws_security_group.eks_nodes.id] }
  egress  { from_port = 0;    to_port = 0;    protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "${var.app_name}-rds-sg-sgp", Project = var.app_name }
}
