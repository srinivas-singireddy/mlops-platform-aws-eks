variable "region" {
  description = "AWS region for bootstrap resources"
  type        = string
  default     = "eu-central-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile name"
  type        = string
  default     = "mlops-platform"
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "mlops"
}
