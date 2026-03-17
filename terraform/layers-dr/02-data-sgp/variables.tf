variable "aws_region" { default = "ap-southeast-1" }
variable "app_name"   { default = "wiseling" }
variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}
