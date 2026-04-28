# -----------------------------------------------------------------------------
# AWS Load Balancer Controller
# -----------------------------------------------------------------------------
# Watches Kubernetes Ingress and Service resources, provisions ALBs/NLBs in
# AWS. Required for HTTP/HTTPS ingress to anything in the cluster.
#
# IRSA pattern: the controller's ServiceAccount is annotated with an IAM role
# that allows it to create ALBs, register targets, etc. Standard pattern from
# AWS docs — uses the official IAM policy from the controller's GitHub.
# -----------------------------------------------------------------------------

# IRSA module reads the controller's recommended IAM policy from upstream
module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name                              = "${data.terraform_remote_state.cluster.outputs.cluster_name}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = data.terraform_remote_state.cluster.outputs.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.10.1"
  namespace  = "kube-system"

  wait          = true
  wait_for_jobs = true
  timeout       = 600

  values = [yamlencode({
    clusterName = data.terraform_remote_state.cluster.outputs.cluster_name
    region      = data.aws_region.current.name
    vpcId       = data.terraform_remote_state.network.outputs.vpc_id

    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.alb_controller_irsa.iam_role_arn
      }
    }

    resources = {
      requests = {
        cpu    = "50m"
        memory = "128Mi"
      }
    }

    webhookNamespaceSelectors = [{
      key      = "elbv2.k8s.aws/webhook-enabled"
      operator = "NotIn"
      values   = ["false"] # Stays a string. No quoting tricks needed.
    }]
  })]
}
