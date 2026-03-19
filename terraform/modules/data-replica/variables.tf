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

variable "primary_rds_arn" {
  type = string
}
