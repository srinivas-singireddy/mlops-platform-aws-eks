# ADR 0004: Terraform/ArgoCD Responsibility Boundary

## Status
Accepted — 2026-04-25

## Context
A common GitOps anti-pattern is "everything via ArgoCD," which sounds
clean but breaks down at bootstrap. ArgoCD itself must exist before it
can install anything. Components that need IRSA or AWS-native resources
(IAM roles, OIDC trust relationships, AWS Secrets Manager bindings) sit
awkwardly inside pure GitOps because their lifecycle is tightly coupled
to AWS infrastructure managed by Terraform.

## Decision
Two-tier responsibility model:

**Terraform manages (the platform layer):**
- ArgoCD itself
- AWS Load Balancer Controller (needs IRSA, needs AWS account-level IAM)
- External Secrets Operator (needs IRSA, scoped to project secret prefix)
- cert-manager (no AWS coupling but installed here for ordering simplicity)
- Any future component requiring an IAM role bound to a ServiceAccount
- ClusterIssuers, ClusterSecretStores — cluster-wide configs that the
  platform layer above depends on

**ArgoCD manages (the application layer):**
- Observability stack (Prometheus, Grafana, Loki)
- Model serving (KServe, vLLM)
- Sample applications
- Anything that doesn't need AWS-native bootstrapping

## Consequences

**Accepted:**
- Single source of truth per concern: AWS-coupled = Terraform, K8s-only = Git
- ArgoCD bootstrap is robust — if ArgoCD breaks, Terraform can replace it
- Adding a new platform component requires Terraform changes (slightly
  slower) but the trade-off is correctness
- Two tools managing the cluster — possible drift between them

**Mitigations:**
- Clear naming convention: anything in `terraform/platform` is Terraform's;
  anything in `k8s/apps` is ArgoCD's. No overlap.
- ArgoCD never targets the kube-system, cert-manager, argocd, or
  external-secrets namespaces (these are Terraform's domain)
- Drift detection: `terraform plan` periodically against the platform
  module catches manual cluster changes

## Alternatives considered
1. **Pure GitOps** — ArgoCD installs everything including itself.
   Rejected: bootstrap fragility, IRSA roles are AWS resources that
   don't fit cleanly in Kubernetes manifests, recovery from a broken
   ArgoCD requires breaking out of GitOps anyway.
2. **Pure Terraform** — Terraform installs every workload via Helm.
   Rejected: Terraform is poor at managing application-level
   resources (no continuous reconciliation, slow apply cycles, no
   sync visibility).
3. **Crossplane** — Kubernetes-native infrastructure management.
   Rejected for this project: adds a third tool to learn, would
   force a bigger architectural decision than this lab justifies.
   Worth revisiting if this project grows.

## Follow-ups
- Document this boundary in the README so future contributors don't
  add Helm releases in the wrong place
- Consider adding a CI check that fails if `terraform/platform/` adds
  a new resource without an ADR update

  ## Implementation note — 2026-04-26

When the platform module installs CRDs (cert-manager, External Secrets)
AND custom resources of those CRDs (ClusterIssuer, ClusterSecretStore)
in the same Terraform apply, the official `kubernetes_manifest` resource
fails at plan time because it validates against the cluster's schema
before the CRDs exist.

Resolution: use `kubectl_manifest` from the gavinbunney/kubectl provider
for these manifests. Unlike `kubernetes_manifest`, it doesn't validate
at plan time, so a clean `terraform apply` works on a fresh cluster.

This is a well-known Terraform-Kubernetes provider issue with no
upstream fix planned. Documented here so future contributors don't
"correct" it back to `kubernetes_manifest`.

## Implementation note — 2026-04-26 (continued)

The AWS Load Balancer Controller registers a cluster-wide
MutatingWebhookConfiguration on Services. By default this webhook
applies to ALL namespaces — including those of platform components
installed in the same Terraform apply. This causes a race: if the
LB controller's webhook pods aren't Ready when cert-manager or
External Secrets create their internal Services, Helm install fails
with "no endpoints available for service".

Resolution:
1. Restrict the webhook with `webhookNamespaceSelectors`:
   only apply to namespaces explicitly opted in.
2. Set `wait = true` on the LB controller's Helm release so
   Terraform waits for pods to be Ready.
3. Add `depends_on = [helm_release.alb_controller]` on every
   downstream Helm release in the platform module.

Documented here so future contributors don't remove these guards
without understanding why they exist.

## Implementation note — 2026-04-26 (continued)

Use multi-line `set` blocks (or `values = [yamlencode(...)]`) in
helm_release resources. Single-line `set { name = "X"; value = "Y" }`
syntax with semicolons is not valid HCL — Terraform's parser silently
misinterprets it on some versions and the `value` attribute is treated
as missing.

## Implementation note — 2026-04-28 (continued)

Helm provider `set` blocks render values through YAML, which means
unquoted strings that look like booleans (`true`/`false`) or numbers
get silently re-typed during rendering. This bit us when configuring
`webhookNamespaceSelectors[0].values[0] = "false"` — Kubernetes rejected
the resulting MutatingWebhookConfiguration because the `values` field
expects a list of strings but received a list containing one boolean.

Resolution: switched the entire alb_controller Helm release from
individual `set` blocks to a single `values = [yamlencode(...)]` block.
The yamlencode function preserves HCL types end-to-end with no string-
to-boolean conversion ambiguity.

Architectural takeaway: for any non-trivial Helm release with a mix of
strings, booleans, and lists, prefer `values = [yamlencode(...)]` over
ad-hoc `set` blocks. The latter introduces a YAML-encoding step where
type drift is silent and easy to miss.

