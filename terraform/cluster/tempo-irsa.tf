# ─────────────────────────────────────────────────────────────
# Tempo IRSA — one role, scoped to the traces bucket only
# Lives here (not bootstrap) because the trust policy depends on
# the EKS cluster OIDC provider, which is recreated every apply.
# The bucket it points at, however, is durable and lives in bootstrap.
# ─────────────────────────────────────────────────────────────

locals {
  tempo_namespace       = "monitoring"
  tempo_service_account = "tempo"
}

data "aws_iam_policy_document" "tempo_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:${local.tempo_namespace}:${local.tempo_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "tempo" {
  name               = "tempo-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.tempo_assume.json

  tags = {
    Project   = "mlops-platform"
    Phase     = "1"
    Component = "tempo"
  }
}

data "aws_iam_policy_document" "tempo_s3" {
  statement {
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.tempo_traces_bucket}"
    ]
  }

  statement {
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::${var.tempo_traces_bucket}/*"
    ]
  }
}

resource "aws_iam_role_policy" "tempo_s3" {
  name   = "tempo-s3-access"
  role   = aws_iam_role.tempo.id
  policy = data.aws_iam_policy_document.tempo_s3.json
}

output "tempo_role_arn" {
  value       = aws_iam_role.tempo.arn
  description = "IRSA role ARN for Tempo's service account annotation"
}
