variable "app_name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_2_id" {
  type = string
}

variable "eks_cluster_sg_id" {
  type = string
}

variable "eks_nodes_sg_id" {
  type = string
}

variable "admin_iam_arn" {
  type    = string
  default = ""
}

variable "github_actions_role_arn" {
  type    = string
  default = ""
}

variable "aws_region" {
  type = string
}

variable "name_suffix" {
  type    = string
  default = ""
}
