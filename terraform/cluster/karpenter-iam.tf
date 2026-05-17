# ─────────────────────────────────────────────────────────────
# Karpenter IAM — two roles + SQS + EventBridge
# All resources here because they depend on the EKS cluster
# OIDC provider, which lives in terraform/cluster.
# ─────────────────────────────────────────────────────────────

locals {
  # The Karpenter controller pod runs in the "karpenter" namespace
  # with a service account also called "karpenter".
  # These two values are used in the IRSA trust policy.
  karpenter_namespace       = "karpenter"
  karpenter_service_account = "karpenter"
}

# ── 1. Controller role (assumed by the Karpenter pod via IRSA) ──

data "aws_iam_policy_document" "karpenter_controller_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type = "Federated"
      # The EKS module exposes the OIDC provider ARN as an output.
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      # This binds the role to exactly one service account in one namespace.
      # A different SA or namespace cannot assume this role.
      values = ["system:serviceaccount:${local.karpenter_namespace}:${local.karpenter_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "karpenter-controller-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume.json

  tags = {
    Project = "mlops-platform"
    Phase   = "5"
  }
}

# The controller policy follows the principle of least privilege as
# documented in https://karpenter.sh/docs/reference/cloudformation/
# The key permissions are:
#   ec2:RunInstances             — launch new nodes
#   ec2:TerminateInstances       — delete nodes during consolidation
#   ec2:DescribeInstanceTypes    — read pricing/capacity data
#   pricing:GetProducts          — read Spot pricing (used for instance selection)
#   sqs:ReceiveMessage           — poll the interruption queue
#   sqs:DeleteMessage            — acknowledge processed interruption events
#   iam:PassRole                 — attach the node instance profile when launching

data "aws_iam_policy_document" "karpenter_controller" {
  statement {
    sid    = "AllowEC2"
    effect = "Allow"
    actions = [
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateTags",
      "ec2:DeleteLaunchTemplate",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowIAMInstanceProfile"
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "AllowSSMGetParameter"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:eu-central-1::parameter/aws/service/eks/optimized-ami/*",
      "arn:aws:ssm:eu-central-1::parameter/aws/service/bottlerocket/*",
    ]
  }

  statement {
    sid       = "AllowPricing"
    effect    = "Allow"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowSQS"
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.karpenter_interruption.arn]
  }

  statement {
    sid     = "AllowPassRole"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    # Scoped to exactly the node role — cannot be used to pass arbitrary roles
    resources = [aws_iam_role.karpenter_node.arn]
  }

  statement {
    sid       = "AllowEKSDescribe"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [module.eks.cluster_arn]
  }
}

resource "aws_iam_policy" "karpenter_controller" {
  name   = "karpenter-controller-${var.cluster_name}"
  policy = data.aws_iam_policy_document.karpenter_controller.json
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

# ── 2. Node role (assumed by EC2 instances Karpenter launches) ──

data "aws_iam_policy_document" "karpenter_node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_node" {
  name               = "karpenter-node-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.karpenter_node_assume.json

  tags = {
    Project = "mlops-platform"
    Phase   = "5"
  }
}

# These four managed policies are the same ones your managed node group
# nodes already have. They are required for:
#   AmazonEKSWorkerNodePolicy       — kubelet to join the cluster
#   AmazonEKS_CNI_Policy            — VPC CNI to configure pod networking
#   AmazonEC2ContainerRegistryReadOnly — pull images from ECR
#   AmazonSSMManagedInstanceCore    — SSM Session Manager access (no bastion needed)

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The instance profile is a wrapper around the role. EC2 doesn't accept
# IAM roles directly — it requires an instance profile. The Karpenter
# controller references the instance profile name when launching instances.
resource "aws_iam_instance_profile" "karpenter_node" {
  name = "karpenter-node-${var.cluster_name}"
  role = aws_iam_role.karpenter_node.name
}

# ── 3. Allow Karpenter-launched nodes to join the cluster ──
# EKS uses the aws-auth ConfigMap to map IAM roles to Kubernetes groups.
# Karpenter nodes need the system:bootstrappers and system:nodes groups.
# This appends to the existing aws-auth entry (which already has the
# managed node group role).

resource "kubernetes_config_map_v1_data" "aws_auth_karpenter" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  # force = true is required to merge with the existing ConfigMap entry
  # that the EKS module already created for the managed node group.
  force = true

  data = {
    mapRoles = yamlencode([
      # Existing managed node group role — keep this or existing nodes break
      {
        rolearn  = module.eks.eks_managed_node_groups["default"].iam_role_arn
        username = "system:node:{{EC2PrivateDNSName}}"
        groups   = ["system:bootstrappers", "system:nodes"]
      },
      # Karpenter node role — new nodes Karpenter provisions use this
      {
        rolearn  = aws_iam_role.karpenter_node.arn
        username = "system:node:{{EC2PrivateDNSName}}"
        groups   = ["system:bootstrappers", "system:nodes"]
      },
    ])
  }
}

# ── 4. SQS queue for Spot interruption + rebalance events ──
# When AWS is about to reclaim a Spot instance, it sends a two-minute
# warning via the EC2 Instance Interruption Notice. Karpenter subscribes
# to these events and proactively drains the node before it's terminated,
# gracefully rescheduling pods.
#
# Without this, your pod just dies when the Spot instance disappears.

resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "karpenter-${var.cluster_name}"
  message_retention_seconds = 300  # 5 minutes — events are processed quickly
  sqs_managed_sse_enabled   = true # encryption at rest

  tags = {
    Project = "mlops-platform"
    Phase   = "5"
  }
}

# Allow EventBridge to send messages to this queue
data "aws_iam_policy_document" "karpenter_sqs" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.karpenter_interruption.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id
  policy    = data.aws_iam_policy_document.karpenter_sqs.json
}

# ── 5. EventBridge rules — route EC2 lifecycle events → SQS ──
# Karpenter watches for four event types:
#   SpotInterruption     — 2-min warning before Spot reclamation
#   RebalanceRecommendation — EC2 suggesting you move to healthier AZ
#   StateChange          — node enters shutting-down/terminated state
#   ScheduledChange      — AWS Health events (maintenance, retirement)

resource "aws_cloudwatch_event_rule" "karpenter_spot_interruption" {
  name        = "karpenter-spot-interruption-${var.cluster_name}"
  description = "Capture EC2 Spot interruption warnings for Karpenter"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_spot_interruption" {
  rule      = aws_cloudwatch_event_rule.karpenter_spot_interruption.name
  target_id = "karpenter-interruption"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_rebalance" {
  name        = "karpenter-rebalance-${var.cluster_name}"
  description = "Capture EC2 rebalance recommendations for Karpenter"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_rebalance" {
  rule      = aws_cloudwatch_event_rule.karpenter_rebalance.name
  target_id = "karpenter-rebalance"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_state_change" {
  name        = "karpenter-state-change-${var.cluster_name}"
  description = "Capture EC2 state changes for Karpenter"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_state_change" {
  rule      = aws_cloudwatch_event_rule.karpenter_state_change.name
  target_id = "karpenter-state-change"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# ── 6. Outputs consumed by terraform/platform and deploy repo ──

output "karpenter_controller_role_arn" {
  description = "IRSA role ARN — annotate the Karpenter ServiceAccount with this"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_node_instance_profile_name" {
  description = "Instance profile name — referenced in EC2NodeClass"
  value       = aws_iam_instance_profile.karpenter_node.name
}

output "karpenter_sqs_queue_url" {
  description = "SQS URL — passed to Karpenter Helm values"
  value       = aws_sqs_queue.karpenter_interruption.url
}

output "karpenter_sqs_queue_name" {
  description = "SQS queue name — also referenced in Helm values"
  value       = aws_sqs_queue.karpenter_interruption.name
}
