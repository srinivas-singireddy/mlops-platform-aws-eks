# Bootstrap

This directory previously held `root-app.yaml`, the ArgoCD bridge
Application that points at the deploy repo. As of <date>, this is
managed by Terraform — see `terraform/platform/argocd.tf`,
resource `kubectl_manifest.argocd_root_app`.

Why moved: a manual kubectl-applied resource doesn't survive
cluster recreation. Terraform-managed bootstrap means a fresh
`mlops-up` produces a fully-functional GitOps cluster.
See ADR 0005 implementation note.