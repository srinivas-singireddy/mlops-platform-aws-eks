variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "aws_profile" {
  type    = string
  default = "mlops-platform"
}

variable "cluster_name" {
  type    = string
  default = "mlops-lab"
}

variable "kubernetes_version" {
  type        = string
  default     = "1.31" # Latest stable EKS version as of early 2026
  description = "Kubernetes minor version for control plane and managed addons"
}

variable "node_instance_types" {
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"] # Diversify spot pools
  description = "Instance types for managed node group. Multiple types improve spot availability."
}

variable "node_group_min_size" {
  type    = number
  default = 1
}

variable "node_group_max_size" {
  type    = number
  default = 4
}

variable "node_group_desired_size" {
  type    = number
  default = 2
}

variable "cluster_endpoint_public_access_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the Kubernetes API. Lock down for production; open for lab."
}
