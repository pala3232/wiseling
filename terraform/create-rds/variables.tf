variable "aws_region" {
  default = "ap-southeast-2"
}
variable "app_name" {
  default = "wiseling"
}

variable "db_password" {
  default = "admin12345"
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for RDS"
  type        = list(string)
}

variable "rds_sg_id" {
  description = "Security group ID for RDS"
  type        = string
}