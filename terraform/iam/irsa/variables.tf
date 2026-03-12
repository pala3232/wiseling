variable "aws_region" {
  description = "AWS region where the EKS cluster is deployed"
  default     = "ap-southeast-2"
}
variable "app_name" {
  description = "Name of the application for tagging and naming resources"
  default     = "wiseling"
}

# I use no default. it's dynamic.