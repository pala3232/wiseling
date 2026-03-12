output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "public_subnet_2_id" {
  value = aws_subnet.public_2.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "private_subnet_2_id" {
  value = aws_subnet.private_2.id
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}

output "eks_nodes_sg_id" {
  value = aws_security_group.eks_nodes.id
}

output "private_route_table_id" {
  value = aws_route_table.private.id
}

output "eks_cluster_sg_id" {
  value = aws_security_group.eks_cluster.id
}
