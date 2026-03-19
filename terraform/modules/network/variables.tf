variable "app_name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "az_1" {
  type = string
}

variable "az_2" {
  type = string
}

variable "pub_cidr_1" {
  type = string
}

variable "pub_cidr_2" {
  type = string
}

variable "priv_cidr_1" {
  type = string
}

variable "priv_cidr_2" {
  type = string
}

variable "name_suffix" {
  type    = string
  default = ""
}

variable "aws_region" {
  type = string
}

variable "enable_dynamodb_endpoint" {
  type    = bool
  default = false
}
