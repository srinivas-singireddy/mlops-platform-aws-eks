# -----------------------------------------------------------------------------
# External Secrets Operator
# -----------------------------------------------------------------------------
# Syncs secrets from AWS Secrets Manager (or SSM Parameter Store) into native
# Kubernetes Secrets. Let's keep secrets out of Git while still using
# GitOps — we put the SecretStore + ExternalSecret manifests in Git, but the
# actual secret values live in AWS.
#
# IRSA: the operator's ServiceAccount needs secretsmanager:GetSecretValue and
# ssm:GetParameter permissions.
# -----------------------------------------------------------------------------

resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

# IAM policy for External Secrets Operator
data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid    = "AllowReadSecretsManager"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecrets",
    ]
    # Scope to secrets tagged for this project — least privilege
    resources = ["arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:mlops-platform/*"]
  }

  statement {
    sid    = "AllowReadSSMParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/mlops-platform/*"]
  }
}

resource "aws_iam_policy" "external_secrets" {
  name   = "${data.terraform_remote_state.cluster.outputs.cluster_name}-external-secrets"
  policy = data.aws_iam_policy_document.external_secrets.json
}

module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name = "${data.terraform_remote_state.cluster.outputs.cluster_name}-external-secrets"

  role_policy_arns = {
    main = aws_iam_policy.external_secrets.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = data.terraform_remote_state.cluster.outputs.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "0.10.7"
  namespace  = kubernetes_namespace.external_secrets.metadata[0].name

  wait    = true
  timeout = 600

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "external-secrets"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_secrets_irsa.iam_role_arn
  }

  set {
    name  = "resources.requests.cpu"
    value = "10m"
  }

  set {
    name  = "resources.requests.memory"
    value = "32Mi"
  }


  depends_on = [helm_release.alb_controller]
}

# A default ClusterSecretStore that downstream ExternalSecrets can reference.
# This is the "where do I look for secrets?" config — points to AWS Secrets
# Manager and uses the IRSA service account for auth.
resource "kubectl_manifest" "cluster_secret_store" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "aws-secrets-manager"
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = data.aws_region.current.name
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  })

  depends_on = [helm_release.external_secrets]
}
