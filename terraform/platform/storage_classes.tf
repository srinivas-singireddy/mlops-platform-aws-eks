# -----------------------------------------------------------------------------
# StorageClasses
# 
# EKS only creates a gp2 StorageClass by default. gp3 is the modern default
# for new EBS volumes — better performance, ~20% cheaper. We define it here
# and make it the cluster default.
# -----------------------------------------------------------------------------

# Remove the "default" annotation from gp2 — only one StorageClass can be default
resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  force = true # Override the existing annotation set by EKS

  depends_on = [data.aws_eks_cluster.this]
}

# Define gp3 and mark it as default
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    fsType    = "ext4"
    encrypted = "true"
  }

  depends_on = [kubernetes_annotations.gp2_not_default]
}
