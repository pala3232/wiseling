variable "app_name" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "rds_sg_id" {
  type = string
}

variable "dynamodb_replica_region" {
  type = string
}
