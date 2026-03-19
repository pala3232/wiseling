variable "app_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "eks_cluster_id" {
  type = string
}

variable "name_suffix" {
  type    = string
  default = ""
}
