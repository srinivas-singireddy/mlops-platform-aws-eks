variable "region" {
  type    = string
  default = "eu-central-1"

}

variable "aws_profile" {
  type    = string
  default = "mlops-platform"

}

variable "name" {
  type        = string
  default     = "mlops-lab"
  description = "Environment name prefix"

}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR block for the VPC"

}

variable "azs" {
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b"]
  description = "Availability Zones to span"
}

variable "public_subnet_cidrs" {

  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]

}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]

}

variable "nat_instance_type" {
  type    = string
  default = "t4g.nano" # ARM, ~€3/month. Cheapest viable NAT.
}
