data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket  = "mlops-tfstate-897175693580"
    key     = "network/terraform.tfstate"
    region  = "eu-central-1"
    profile = "mlops-platform"
  }
}

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket  = "mlops-tfstate-897175693580"
    key     = "cluster/terraform.tfstate"
    region  = "eu-central-1"
    profile = "mlops-platform"
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# EKS cluster auth — needed by k8s/helm providers
data "aws_eks_cluster" "this" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}
