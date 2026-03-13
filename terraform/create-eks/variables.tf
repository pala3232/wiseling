variable "aws_region" {
  default = "ap-southeast-2"
}
variable "app_name" {
  default = "wiseling"
}

variable "vpc_id" {
  description = "VPC ID for EKS"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for EKS"
  type        = list(string)
}

variable "eks_cluster_sg_id" {
  description = "Security group ID for EKS cluster"
  type        = string
}