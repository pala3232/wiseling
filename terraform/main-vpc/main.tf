terraform {

  backend "s3" {
    bucket = "wiseling-terraform-state-pala3105"
    key    = "main-vpc/terraform.tfstate"
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
  region = var.aws_region
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
    tags = {
        Name = "${var.app_name}-vpc"
        Project = var.app_name
    }
}

resource "aws_subnet" "public" {
  map_public_ip_on_launch = true
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-southeast-2a"
    tags = {
        Name = "${var.app_name}-public-subnet"
        Project = var.app_name
        "karpenter.sh/discovery" = "wiseling-eks-cluster"
    }
}

resource "aws_subnet" "public_2" {
  map_public_ip_on_launch = true
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-southeast-2b"
  tags = {
    Name    = "${var.app_name}-public-subnet-2"
    Project = var.app_name
    "karpenter.sh/discovery" = "wiseling-eks-cluster"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name    = "${var.app_name}-igw"
    Project = var.app_name
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name    = "${var.app_name}-public-rt"
    Project = var.app_name
  }
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.ap-southeast-2.dynamodb"
  route_table_ids = [aws_route_table.public.id, aws_route_table.private.id]
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "ap-southeast-2a"
  tags = {
    Name    = "${var.app_name}-private-subnet"
    Project = var.app_name
  }
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "ap-southeast-2b"
  tags = {
    Name    = "${var.app_name}-private-subnet-2"
    Project = var.app_name
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name    = "${var.app_name}-private-rt"
    Project = var.app_name
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private.id
}

