# -----------------------------------------------------------------------------
# cert-manager
# -----------------------------------------------------------------------------
# Provides automatic TLS certificate management. Used downstream by ArgoCD,
# Grafana, and any Ingress that needs HTTPS. Issues certificates via
# Let's Encrypt (HTTP-01 challenge — works because we have an ALB).
#
# Note: we do NOT use IRSA here because cert-manager doesn't talk to AWS for
# HTTP-01 challenges. If we used DNS-01 with Route 53, we'd need IRSA + an
# IAM role with route53:ChangeResourceRecordSets — that's a future enhancement.
# -----------------------------------------------------------------------------

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
    labels = {
      "app.kubernetes.io/name" = "cert-manager"
    }
  }
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.16.2"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  wait    = true
  timeout = 600

  set {
    name  = "crds.enabled"
    value = "true"
  }

  set {
    name  = "global.leaderElection.namespace"
    value = "cert-manager"
  }

  set {
    name  = "resources.requests.cpu"
    value = "10m"
  }

  set {
    name  = "resources.requests.memory"
    value = "32Mi"
  }


  # Wait for AWS LB Controller webhook to be ready first
  depends_on = [helm_release.alb_controller]
}

# ClusterIssuer for Let's Encrypt staging (use this for testing — generous rate limits)
resource "kubectl_manifest" "letsencrypt_staging" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-staging"
    }
    spec = {
      acme = {
        server = "https://acme-staging-v02.api.letsencrypt.org/directory"
        email  = var.letsencrypt_email
        privateKeySecretRef = {
          name = "letsencrypt-staging-account-key"
        }
        solvers = [{
          http01 = {
            ingress = {
              class = "alb"
            }
          }
        }]
      }
    }
  })

  depends_on = [helm_release.cert_manager]
}

# ClusterIssuer for production Let's Encrypt — use only when you need a real cert
resource "kubectl_manifest" "letsencrypt_prod" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = var.letsencrypt_email
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        solvers = [{
          http01 = {
            ingress = {
              class = "alb"
            }
          }
        }]
      }
    }
  })

  depends_on = [helm_release.cert_manager]
}
