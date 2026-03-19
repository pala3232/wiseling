resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name                     = "${var.app_name}-vpc${var.name_suffix}"
    Project                  = var.app_name
    "karpenter.sh/discovery" = var.cluster_name
  }
}

resource "aws_subnet" "public" {
  map_public_ip_on_launch = true
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.pub_cidr_1
  availability_zone       = var.az_1
  tags = {
    Name                                        = "${var.app_name}-public-subnet${var.name_suffix}"
    Project                                     = var.app_name
    "karpenter.sh/discovery"                    = var.cluster_name
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "public_2" {
  map_public_ip_on_launch = true
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.pub_cidr_2
  availability_zone       = var.az_2
  tags = {
    Name                                        = "${var.app_name}-public-subnet-2${var.name_suffix}"
    Project                                     = var.app_name
    "karpenter.sh/discovery"                    = var.cluster_name
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.priv_cidr_1
  availability_zone = var.az_1
  tags = {
    Name                                        = "${var.app_name}-private-subnet${var.name_suffix}"
    Project                                     = var.app_name
    "karpenter.sh/discovery"                    = var.cluster_name
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.priv_cidr_2
  availability_zone = var.az_2
  tags = {
    Name                                        = "${var.app_name}-private-subnet-2${var.name_suffix}"
    Project                                     = var.app_name
    "karpenter.sh/discovery"                    = var.cluster_name
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.app_name}-igw${var.name_suffix}", Project = var.app_name }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.app_name}-nat-eip${var.name_suffix}", Project = var.app_name }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${var.app_name}-nat-gw${var.name_suffix}", Project = var.app_name }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.app_name}-public-rt${var.name_suffix}", Project = var.app_name }
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.app_name}-private-rt${var.name_suffix}", Project = var.app_name }
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
  count           = var.enable_dynamodb_endpoint ? 1 : 0
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.${var.aws_region}.dynamodb"
  route_table_ids = [aws_route_table.public.id, aws_route_table.private.id]
  tags            = { Project = var.app_name }
}

resource "aws_security_group" "eks_nodes" {
  name   = "${var.app_name}-eks-nodes-sg${var.name_suffix}"
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
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                     = "${var.app_name}-eks-nodes-sg${var.name_suffix}"
    "karpenter.sh/discovery" = var.cluster_name
  }
}

resource "aws_security_group" "eks_cluster" {
  name   = "${var.app_name}-eks-cluster-sg${var.name_suffix}"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.app_name}-eks-cluster-sg${var.name_suffix}", Project = var.app_name }
}

resource "aws_security_group" "rds" {
  name   = "${var.app_name}-rds-sg${var.name_suffix}"
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

  tags = { Name = "${var.app_name}-rds-sg${var.name_suffix}", Project = var.app_name }
}
