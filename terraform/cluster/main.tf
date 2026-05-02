provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "mlops-platform"
      Environment = "lab"
      ManagedBy   = "terraform"
      Component   = "cluster"
    }
  }
}

# Configure kubernetes/helm providers to use the EKS cluster we create below.
# They read cluster connection details from the module's outputs.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--profile", var.aws_profile]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--profile", var.aws_profile]
    }
  }
}

# -----------------------------------------------------------------------------
# EKS cluster
# -----------------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31" # Pinned to a specific major for stability

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  # Networking — pulled from the network module's outputs
  vpc_id                   = data.terraform_remote_state.network.outputs.vpc_id
  subnet_ids               = data.terraform_remote_state.network.outputs.private_subnet_ids
  control_plane_subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids

  # API endpoint access
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  cluster_endpoint_private_access      = true

  # Enable IRSA — this creates the OIDC provider
  enable_irsa = true

  # Grant the current caller (you) cluster admin via access entries.
  # This is the modern replacement for the older aws-auth ConfigMap.
  enable_cluster_creator_admin_permissions = true

  # Managed addons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  # Managed node group
  eks_managed_node_groups = {
    default = {
      name           = "default"
      instance_types = var.node_instance_types
      capacity_type  = "SPOT"

      min_size     = var.node_group_min_size
      max_size     = var.node_group_max_size
      desired_size = var.node_group_desired_size

      # Amazon Linux 2023 AMI
      ami_type = "AL2023_x86_64_STANDARD"

      # Disk config — 20GB gp3 is plenty for a lab
      disk_size = 20

      # Labels to help with workload placement later
      labels = {
        role = "general"
      }

      tags = {
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      }
    }
  }

  tags = {
    Environment = "lab"
  }
}

# -----------------------------------------------------------------------------
# IRSA role for EBS CSI driver
# The EBS CSI driver needs IAM permissions to create/delete EBS volumes.
# Using IRSA — a dedicated role bound to the driver's ServiceAccount —
# rather than granting these permissions to the node IAM role.
# -----------------------------------------------------------------------------

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}
