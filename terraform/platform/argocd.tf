# -----------------------------------------------------------------------------
# ArgoCD
# -----------------------------------------------------------------------------
# GitOps engine. Watches Git repos, syncs Kubernetes manifests into the
# cluster, provides a UI to inspect sync state.
#
# Phase 3: install ArgoCD itself.
# Phase 4+: configure ArgoCD to watch our repo's k8s/apps folder, then
# everything else lands via GitOps.
# -----------------------------------------------------------------------------

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "app.kubernetes.io/name" = "argocd"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.10"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # Sane lab defaults — single replica for everything
  values = [yamlencode({
    global = {
      domain = "argocd.local" # Internal-only for now; we'll add proper Ingress later
    }

    configs = {
      params = {
        # Disable TLS internally — ALB will terminate TLS later
        "server.insecure" = true
      }
    }

    server = {
      replicas = 1
      service = {
        type = "ClusterIP" # No public exposure yet — port-forward to access
      }
    }

    repoServer = {
      replicas = 1
    }

    applicationSet = {
      replicas = 1
    }

    controller = {
      replicas = 1
    }

    # Use HA Redis off (single replica) — fine for lab
    redis-ha = {
      enabled = false
    }
    redis = {
      enabled = true
    }

    dex = {
      enabled = false # No SSO needed for lab
    }
  })]
  wait       = true
  timeout    = 600
  depends_on = [helm_release.cert_manager, helm_release.alb_controller]
}

# -----------------------------------------------------------------------------
# Bootstrap Application — points ArgoCD at the deploy repo
# 
# This is the bridge between infrastructure (this repo) and applications
# (mlops-platform-deploy). Without this, ArgoCD has no idea which repo
# to watch. Applied via Terraform so a fresh cluster bootstrap is fully
# automated — no manual kubectl apply needed.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "argocd_root_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = "argocd"
      finalizers = [
        "resources-finalizer.argocd.argoproj.io"
      ]
    }
    spec = {
      project = "default"

      source = {
        repoURL        = var.deploy_repo_url
        targetRevision = var.deploy_repo_branch
        path           = "apps"
        directory = {
          recurse = true
          include = "*/application.yaml"
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true"
        ]
      }
    }
  })

  depends_on = [helm_release.argocd]
}
