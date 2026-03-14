variable "aws_region" {
  default = "ap-southeast-2"
}

variable "app_name" {
  default = "wiseling"
}

variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}
