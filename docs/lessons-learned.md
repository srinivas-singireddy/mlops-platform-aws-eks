# MLOps Platform Build — Lessons Learned

> **AWS EKS Solutions Architect Portfolio Project**
> 18 issues, decisions, and architectural takeaways from the platform build.

## Why this document exists

This document captures every meaningful issue encountered during the MLOps platform build — from initial network setup through observability stack deployment. It serves three purposes:

1. **A reference for future-me.** Most of these issues will recur in different forms in future projects. Having the diagnostic and the resolution captured here means I won't re-debug from scratch.
2. **A learning artifact for others.** The same patterns trip up most engineers building production EKS for the first time. If this saves someone a debugging session, it was worth writing.
3. **An interview reference.** Each issue includes a "talking point" — a concise first-person framing suitable for "tell me about a difficult problem you solved" interview prompts.

These are real issues. Real diagnostic outputs led to each conclusion. The honest framing ("I hit this, here's how I solved it, here's what I'd do differently next time") is more credible than smooth tutorial-speak.

## Project context

A production-grade MLOps platform on AWS EKS, provisioned via Terraform across separate modules (network → cluster → platform), with workloads delivered through ArgoCD watching a separate deploy repo (two-repo GitOps pattern). The platform layer includes cert-manager, External Secrets Operator, AWS Load Balancer Controller, and ArgoCD itself; the application layer (managed via GitOps) deploys kube-prometheus-stack, Loki, and Grafana Alloy for unified observability.

Architectural decisions documented in seven ADRs covering: single-account topology, NAT strategy, EKS module choice, Terraform/ArgoCD boundary, two-repo GitOps pattern, observability via GitOps, and AWS Secrets Manager + ESO for secrets management. See [`docs/adr/`](./adr/) for the full set.

## Table of contents

| # | Issue | Phase |
|---|-------|-------|
| 1 | [NAT instance failed — nodes could not join EKS cluster](#issue-1--nat-instance-failed--nodes-could-not-join-eks-cluster) | Phase 2 |
| 2 | [kubectl could not connect after first cluster bring-up](#issue-2--kubectl-could-not-connect-after-first-cluster-bring-up) | Phase 2 |
| 3 | [kubernetes_manifest failed at plan time — CRD not yet installed](#issue-3--kubernetes_manifest-failed-at-plan-time--crd-not-yet-installed) | Phase 3 |
| 4 | [AWS Load Balancer Controller webhook race](#issue-4--aws-load-balancer-controller-webhook-race) | Phase 3 |
| 5 | [Boolean type drift in Helm set blocks](#issue-5--boolean-type-drift-in-helm-set-blocks) | Phase 3 |
| 6 | [Terraform HCL syntax — semicolons are not separators](#issue-6--terraform-hcl-syntax--semicolons-are-not-separators) | Phase 3 |
| 7 | [Trust the plan, not the impulse to destroy](#issue-7--trust-the-plan-not-the-impulse-to-destroy) | Phase 3 |
| 8 | [ArgoCD root Application not auto-bootstrapped](#issue-8--argocd-root-application-not-auto-bootstrapped) | Phase 4 |
| 9 | [Promtail end-of-life — caught before deploying](#issue-9--promtail-end-of-life--caught-before-deploying) | Phase 4 |
| 10 | [Helm chart repo URLs differ within the same vendor](#issue-10--helm-chart-repo-urls-differ-within-the-same-vendor) | Phase 4 |
| 11 | [Stale chart versions — verify before pinning](#issue-11--stale-chart-versions--verify-before-pinning) | Phase 4 |
| 12 | [Loki chart structural drift between major versions](#issue-12--loki-chart-structural-drift-between-major-versions) | Phase 4 |
| 13 | [Grafana password caching — env vars vs persistent DB](#issue-13--grafana-password-caching--env-vars-vs-persistent-db) | Phase 4 |
| 14 | [ArgoCD perpetual OutOfSync on controller-managed CRDs](#issue-14--argocd-perpetual-outofsync-on-controller-managed-crds) | Phase 4 |
| 15 | [Architectural critique — Secret as ArgoCD Application](#issue-15--architectural-critique--secret-as-argocd-application) | Phase 4 |
| 16 | [EBS gp3 StorageClass missing from EKS defaults](#issue-16--ebs-gp3-storageclass-missing-from-eks-defaults) | Phase 4 |
| 17 | [EKS pod density wall — VPC CNI hard limit](#issue-17--eks-pod-density-wall--vpc-cni-hard-limit) | Phase 4 |
| 18 | [Minimal containers — wget not in production images](#issue-18--minimal-containers--wget-not-in-production-images) | Phase 4 |

---

## Issue 1 — NAT instance failed — nodes could not join EKS cluster

**Phase:** Phase 2 — EKS cluster bring-up

### Problem

After 34 minutes of `terraform apply`, the EKS managed node group failed with `NodeCreationFailure: Instances failed to join the kubernetes cluster`. Worker node console logs showed `nodeadm` repeatedly retrying EC2 `DescribeInstances` API calls and timing out.

### Why it happened

The Phase 1 design used a custom NAT instance (t4g.nano) rather than NAT Gateway to save ~€29/month. The user-data script that should configure `iptables MASQUERADE` and IP forwarding did not reliably execute on first boot, possibly due to timing of `dnf install -y iptables-services` on Amazon Linux 2023. Worker nodes in private subnets had no outbound internet access; they could not reach the EC2 API endpoint they need at startup, so they never registered with the EKS control plane.

### Options considered

- **Path A — Switch to NAT Gateway.** Managed AWS service; ~25 minutes to fully recover. Costs ~€32/month if running 24/7, ~€8/month with destroy/apply discipline.
- **Path B — Debug the NAT instance.** Stay with the cost-optimized choice. Could take 30 minutes if the user-data fix is simple, 2+ hours for deeper iptables/AL2023 issues.

### What I chose

**Path A — NAT Gateway.** Updated the network module to replace the NAT instance + ENI + EIP-association with a single `aws_nat_gateway` resource. Updated the private route table target accordingly. Re-applied network module, then cluster module — nodes joined within minutes.

### Architectural takeaway

**Cost optimizations that increase the failure surface are not optimizations.** A single 30-minute incident debugging the NAT instance wiped out the entire month of theoretical savings. Production-grade infrastructure favors managed services where the cost-vs-reliability trade-off is favorable. The original NAT-instance ADR was retained but updated with a "Status: revised" block documenting the postmortem — interviewers respond well to ADRs that show evolution of thinking, not just initial choices.


---

## Issue 2 — kubectl could not connect after first cluster bring-up

**Phase:** Phase 2 — post-apply

### Problem

`kubectl` returned `Unable to connect to the server: dial tcp: lookup <hex>.eks.amazonaws.com: no such host` after a successful `terraform apply` of the cluster module.

### Why it happened

`~/.kube/config` did not yet have an entry for the new cluster. Worse, it had a stale entry from a previous experiment pointing at a hostname that no longer exists — DNS rightly answered "no such host." Each EKS cluster gets a unique cluster-ID hex in its API endpoint hostname, regenerated on every cluster recreation.

### Options considered

- **Single command.** `aws eks update-kubeconfig --name mlops-lab --region eu-central-1 --profile mlops-platform`. This calls EKS API, fetches current endpoint and CA cert, writes a new context, sets it current.

### What I chose

Ran `update-kubeconfig`. Verified `kubectl get nodes` returned 2 Ready nodes. **This must be re-run after every fresh cluster apply** because the API hostname changes each time.

### Architectural takeaway

In daily destroy/apply rhythms, kubeconfig refresh is a step that's easy to forget. Building it into the morning automation (a Taskfile target or shell alias) eliminates the friction. Also worth periodically running `kubectl config get-contexts` and deleting stale entries — accumulated kubeconfig debt is a common source of "I just deleted production" moments when engineers have multiple clusters.


---

## Issue 3 — kubernetes_manifest failed at plan time — CRD not yet installed

**Phase:** Phase 3 — platform services

### Problem

`terraform plan` errored: `API did not recognize GroupVersionKind from manifest (CRD may not be installed). no matches for kind "ClusterIssuer" in group "cert-manager.io"`. Same issue affected `ClusterSecretStore` for External Secrets Operator.

### Why it happened

The official `hashicorp/kubernetes` provider's `kubernetes_manifest` resource validates manifests at plan time by querying the cluster's API for the resource type's schema. The Helm release that installs cert-manager (which creates the CRD) and the `kubernetes_manifest` that creates a `ClusterIssuer` (which uses the CRD) live in the same Terraform module. At plan time, the CRD doesn't exist yet — Terraform asks the API "what's a ClusterIssuer?" and the API replies "I've never heard of that." `depends_on` doesn't help because dependency only sequences operations during apply, not plan.

### Options considered

- **A — Switch to `kubectl_manifest` (gavinbunney/kubectl provider).** A community provider that does NOT validate at plan time — it just applies the manifest at apply time. Standard solution for this exact problem.
- **B — Two-stage apply.** `terraform apply -target=helm_release.cert_manager` first to install the CRD, then `terraform apply` for the rest. Functional but fragile — anyone running it fresh has to know the magic two-step.

### What I chose

**A — `kubectl_manifest`.** Added `gavinbunney/kubectl` to `versions.tf`, configured a `kubectl` provider block with the cluster auth, replaced `kubernetes_manifest` resources with `kubectl_manifest` (using `yaml_body = yamlencode({...})` instead of `manifest = {...}`).

### Architectural takeaway

When mixing CRD installation and CRD usage in the same Terraform module, you have two providers with fundamentally different validation models — choose accordingly. The `gavinbunney/kubectl` community provider is the de facto standard for "apply this manifest at apply-time, don't validate at plan-time." Worth knowing about — it's a permanent fixture in production EKS Terraform code.


---

## Issue 4 — AWS Load Balancer Controller webhook race

**Phase:** Phase 3 — platform services

### Problem

After AWS LB Controller installed successfully via Helm, downstream Helm releases for cert-manager and External Secrets failed with `failed calling webhook "mservice.elbv2.k8s.aws": no endpoints available for service "aws-load-balancer-webhook-service"`.

### Why it happened

AWS LB Controller registers a `MutatingWebhookConfiguration` that intercepts every Service creation cluster-wide. When cert-manager and ESO Helm releases tried to create their internal Services, Kubernetes asked the LB controller's webhook to validate them. But the LB controller's pods weren't fully Ready yet — the webhook had no endpoints, so it timed out, Service creation failed, Helm install failed, Terraform errored.

### Options considered

- **A — Re-run apply.** By the time you re-run, LB controller pods are Ready. Quick fix to unblock, but doesn't prevent recurrence on fresh cluster.
- **B — Fix forward properly with three changes.** Add `wait = true` and `timeout = 600` on the LB controller `helm_release` so Terraform waits for pods to be Ready. Add `webhookNamespaceSelectors` to scope the webhook so it doesn't apply to namespaces that don't need it. Add explicit `depends_on = [helm_release.alb_controller]` on cert-manager, ArgoCD, and ESO Helm releases.

### What I chose

**Both A and B.** Path A to unblock immediately, Path B as a permanent fix for fresh-cluster bring-up.

### Architectural takeaway

Cluster-wide admission webhooks introduce ordering constraints between Helm releases that are otherwise independent. When mixing multiple platform components in a single apply, treat the webhook controllers as foundational dependencies — install them first, restrict their scope to the namespaces that actually need them, and explicitly sequence downstream installs.


---

## Issue 5 — Boolean type drift in Helm set blocks

**Phase:** Phase 3 — platform services

### Problem

`terraform apply` failed with: `cannot patch "aws-load-balancer-webhook" with kind MutatingWebhookConfiguration: json: cannot unmarshal bool into Go struct field LabelSelectorRequirement.webhooks.namespaceSelector.matchExpressions.values of type string`.

### Why it happened

I configured `webhookNamespaceSelectors[0].values[0] = "false"` via Helm `set` blocks. Helm's `set` parameter renders values through YAML, which treats unquoted `false` as a boolean. Kubernetes' API expects this field to be a list of strings, so it rejected the boolean. The HCL string `"false"` was silently converted: HCL string → Helm set → YAML render → boolean → Kubernetes JSON → rejected.

### Options considered

- **A — Escape quotes in the set value.** `value = "\"false\""`. Forces Helm to keep it as a string. Functional but cryptic.
- **B — Switch the Helm release from `set` blocks to a `values = [yamlencode({...})]` block.** In the yamlencode approach, HCL types pass through end-to-end — strings stay strings, booleans stay booleans. No YAML re-encoding ambiguity.

### What I chose

**B — yamlencode block.** Replaced all individual `set` blocks for the LB controller with one `values = [yamlencode({...})]` block. Less verbose and eliminates type-drift bugs entirely.

### Architectural takeaway

For non-trivial Helm releases with a mix of strings, booleans, and lists, prefer `values = [yamlencode(...)]` over ad-hoc `set` blocks. Helm `set` introduces a YAML-encoding step where type drift is silent and easy to miss. The `yamlencode` approach preserves HCL types end-to-end. After hitting this once, I now use `set` only for the simplest single-string values, and `yamlencode` for everything else.


---

## Issue 6 — Terraform HCL syntax — semicolons are not separators

**Phase:** Phase 3 — platform services

### Problem

VS Code flagged `Required attribute "value" not specified` on every line of code I had written as `set { name = "X"; value = "Y" }`. `terraform validate` confirmed.

### Why it happened

Terraform HCL does NOT support semicolons to separate attributes on a single line. The parser saw `name = "clusterName"`, the semicolon as garbage, and concluded `value` was missing. Plan was passing in some Terraform versions because of lenient parsing, but the linter was correct: the syntax is invalid. The compact single-line style I was using is HCL2-illegal.

### Options considered

- **Multi-line set blocks (standard HCL style).** Each attribute on its own line. Verbose but conventional and unambiguous.
- **`values = [yamlencode({...})]` block.** Single nested map, eliminates set blocks entirely. Recommended for resources with many fields.

### What I chose

Multi-line `set` blocks for resources with few fields, `yamlencode` block for complex resources. Pre-commit hooks added: `terraform_fmt` and `terraform_validate` enforced via `pre-commit-config.yaml`.

### Architectural takeaway

`terraform validate` is the single most-skipped step in the Terraform workflow. It runs in milliseconds and catches syntax errors, missing required attributes, and type mismatches before they reach the much heavier `plan` operation. The right cadence is: `terraform fmt` → `terraform validate` → `terraform plan` → `terraform apply`. Pre-commit hooks should enforce the first two automatically. Skipping validate is how silent type-drift bugs reach production.


---

## Issue 7 — Trust the plan, not the impulse to destroy

**Phase:** Phase 3 — platform services

### Problem

After fixing the syntax issues, my instinct was to `terraform destroy` and rebuild from scratch for certainty. Was that the right call?

### Why it happened

In a lab, destroy-and-recreate is always safe and tempting. In production, you can't — there's state, traffic, customers. Building the habit of "plan before acting" matters more than the lab outcome. The impulse to destroy when uncertain bypasses the actual diagnostic: comparing code to reality.

### Options considered

- **A — Destroy and recreate.** Guaranteed clean state, costs 30 minutes of teardown and apply.
- **B — `terraform plan` first, then decide.** Read the diff between code and cluster. Plan output tells you whether destroy is necessary.

### What I chose

**B.** Ran plan, which showed `0 to add, 4 to change, 0 to destroy` — the cluster was in the desired state, only minor `timeout` adjustments needed. No destroy required. Applied in 30 seconds.

### Architectural takeaway

Destroying without first understanding state is a bad habit, even in a lab where it's safe. Production architects build muscle memory by always planning first — read what's drifted, decide whether to act, then act. "Destroying because uncertainty is uncomfortable" is exactly the reflex that's dangerous when you're later operating real production systems. The discipline of `terraform plan` before any decision is the same discipline whether you're in a lab or running a Fortune-500 deployment.


---

## Issue 8 — ArgoCD root Application not auto-bootstrapped

**Phase:** Phase 4 — daily ritual recovery

### Problem

After morning `mlops-up`, ArgoCD pods were Running but no Applications existed in the cluster. The kube-prometheus-stack and other workloads weren't deployed. Why didn't GitOps "just work"?

### Why it happened

The two-repo GitOps pattern needs a single bridge: an ArgoCD `Application` resource pointing at the deploy repo. I had previously applied `k8s/bootstrap/root-app.yaml` manually via `kubectl apply` — which only existed in the cluster's etcd. When `terraform destroy` removed the cluster, the bridge went with it. Today's fresh cluster came up with ArgoCD healthy but ignorant of the deploy repo.

### Options considered

- **A — Apply manually each morning.** `kubectl apply -f k8s/bootstrap/root-app.yaml` after every cluster recreation. Simple but error-prone (forgotten step).
- **B — Add the bootstrap to a `task up` Taskfile target.** Better than manual, but encoding bootstrap in operations rather than infrastructure.
- **C — Move the bootstrap to Terraform via `kubectl_manifest`.** Treats the bridge as platform infrastructure. Idempotent, automated, declarative.

### What I chose

**C — `kubectl_manifest` in `terraform/platform/argocd.tf`.** Added the root Application as a Terraform resource so a clean `terraform apply` produces a fully-functional GitOps cluster end-to-end. Removed the manual YAML file with a README pointing to the new location.

### Architectural takeaway

**In GitOps, "bootstrap" is the chicken-and-egg moment where Git-managed manifests don't yet exist in the cluster.** Whoever owns infrastructure (Terraform, in our case) must own the bootstrap manifest, because no other tool can apply it before itself exists. This is one of the most common GitOps pitfalls — fragile bootstrap that depends on engineer memory rather than infrastructure code. Treating the bridge as Terraform-owned makes the cluster self-bootstrapping.


---

## Issue 9 — Promtail end-of-life — caught before deploying

**Phase:** Phase 4 — observability stack

### Problem

The original Phase 4 plan called for Promtail as the log shipper to Loki. Reading current Grafana documentation, I noticed Promtail had reached End-of-Life on March 2, 2026. Continuing as planned would have deployed deprecated, unsupported software in a portfolio project.

### Why it happened

The plan I was working from was written with patterns from late 2025. Grafana Labs migrated all log-collection development to Grafana Alloy (their OpenTelemetry Collector distribution). Promtail still works but receives no updates or security patches. Tutorials and articles online lag the ecosystem; cross-checking with primary sources (the project's own docs) caught the deprecation.

### Options considered

- **A — Deploy Promtail anyway since it still works.** Path of least resistance, but signals "outdated tutorial follower" to a recruiter. Technical debt from day one.
- **B — Switch to Grafana Alloy.** Modern, OTel-native, actively developed. Different config syntax (component-based) but same architectural role.

### What I chose

**B — Grafana Alloy.** Replaced `apps/promtail/` plans with `apps/alloy/`. Wrote an Alloy config using its component-based syntax (`discovery.kubernetes` → `discovery.relabel` → `loki.source.kubernetes` → `loki.write`).

### Architectural takeaway

Portfolio projects benefit from being current. Demonstrating Promtail in mid-2026 would signal "this person is following old tutorials." Demonstrating Alloy signals awareness of the ecosystem's evolution. The discipline: cross-check any tool's status with primary sources (project docs, GitHub) before adopting it. Two years of ecosystem lag is normal in tutorial content; you have to do the verification yourself.



---

## Issue 10 — Helm chart repo URLs differ within the same vendor

**Phase:** Phase 4 — chart repository discovery

### Problem

I drafted Application manifests with `repoURL: https://grafana.github.io/helm-charts` for Alloy and `https://grafana-community.github.io/helm-charts` for Loki. The asymmetry seemed wrong — why two different repos for the same vendor?

### Why it happened

Grafana Labs split their Helm charts in early 2026: commercially-maintained charts (Alloy, Mimir, Tempo, Pyroscope) stayed at `grafana/helm-charts`; community-maintained charts (Grafana OSS, Loki, Promtail) moved to `grafana-community/helm-charts`. They look symmetrical but are different repos with different maintenance models. Pinning the wrong URL means the chart won't resolve at all.

### Options considered

- **Verify each chart's current repo before pinning.** Use `helm repo add` + `helm search repo --versions` for every chart. Takes 30 seconds per chart.

### What I chose

Verified both repos via `helm search repo`. Confirmed Alloy at the main Grafana repo, Loki at the community repo. Pinned both correctly. Added a Taskfile target `verify:helm-versions` to check pinned versions against latest available, periodically.

### Architectural takeaway

**Helm chart repo URLs are not stable across projects you'd think are related.** Always verify the current repo via artifacthub.io or the project's README before pinning. For reproducibility, prefer pinning a specific chart version rather than letting Helm resolve "latest" — a chart that moves repos can break a "latest" install silently.


---

## Issue 11 — Stale chart versions — verify before pinning

**Phase:** Phase 4 — chart version management

### Problem

I had `targetRevision: 0.10.1` for Alloy and `6.18.0` for Loki in my Application manifests. Running `helm search repo` showed actual current versions: Alloy `1.8.0` (chart) installing app version `v1.16.0`, Loki `13.5.0` installing app `3.7.1` — far from what I'd written.

### Why it happened

I was writing version numbers from memory based on patterns I'd seen in articles from late 2025. The Alloy chart had jumped major versions (0.x → 1.x). The Loki chart had moved through several major versions. Stale tutorial knowledge that I'd carried forward without verification.

### Options considered

- **Run `helm search repo --versions` immediately before pinning, every time.** Simple, fast (10 seconds), eliminates the issue.

### What I chose

Verified live: `helm repo add grafana https://grafana.github.io/helm-charts && helm repo update grafana && helm search repo grafana/alloy --versions | head -3`. Pinned to current chart versions. Added a `verify:helm-versions` Taskfile target to check pinned versions against latest periodically.

### Architectural takeaway

The Helm ecosystem moves fast. Charts can change repo URLs, structural conventions, and major versions every 6-18 months. Trust nothing about chart versions in any document — including documentation given by tools — without verifying. The pattern is: `helm search repo` for current versions, `helm show values` for current structure, `helm template` for rendered output, before committing.


---

## Issue 12 — Loki chart structural drift between major versions

**Phase:** Phase 4 — Loki deployment

### Problem

My drafted `apps/loki/values.yaml` based on chart 6.x had `deploymentMode: SingleBinary` at the top level. Chart 13.x renamed it to `Monolithic` and changed how the `singleBinary:` config block worked. The chart was tolerant — silently ignored unrecognized fields and applied defaults.

### Why it happened

Major-version Helm chart bumps frequently restructure values. Old fields are renamed, moved nesting levels, or removed entirely — but the chart silently ignores fields it doesn't recognize, applying defaults. The old values.yaml "works" in that the chart deploys, but it deploys with wrong config.

### Options considered

- **Verify chart structure against `helm show values` before committing.** Run `helm show values <repo>/<chart> --version <ver>` and diff against your values.yaml.
- **Render with `helm template` and inspect the output.** See exactly what Kubernetes resources will be created, with what configuration.

### What I chose

**Both as discipline.** Ran `helm show values grafana-community/loki --version 13.5.0` and discovered `deploymentMode` had moved to top-level and renamed to `Monolithic`. Then ran `helm template` to verify the rendered output had only one StatefulSet (correct for Monolithic mode), no read/write/backend split. Updated values.yaml.

### Architectural takeaway

**Chart-version structural drift is the silent killer.** A values.yaml written for chart 6.x silently produces wrong behavior in 13.x — fields are ignored, defaults apply, pods look like they're working but aren't configured as intended. Discipline: before any chart-version upgrade, run `helm show values` and diff against existing values.yaml. Look for keys that disappeared, were renamed, or moved nesting levels.


---

## Issue 13 — Grafana password caching — env vars vs persistent DB

**Phase:** Phase 4 — secrets pipeline integration

### Problem

After wiring Grafana to read admin credentials from a Secret synced by ESO from AWS Secrets Manager, login still failed with the AWS-stored password. All diagnostic checks (Secret exists, Secret has correct password, env vars reference correct Secret) passed.

### Why it happened

Grafana stores admin credentials in **two places**: environment variables (set at pod startup from the Secret) and its internal SQLite database (persisted on the Grafana PVC). On first startup, env vars seed the database. On subsequent restarts, Grafana ignores env var changes if they conflict with the database — treating the database as source of truth for any user-modifiable setting. So switching the credential source after first deployment doesn't actually update the live admin password.

### Options considered

- **A — Reset password from inside the running pod.** `kubectl exec ... grafana cli admin reset-admin-password <new>`. Forces the database to match the env var.
- **B — Wipe Grafana's persistent volume and start fresh.** Nuclear option. Loses any dashboard customizations.

### What I chose

**A — `grafana cli admin reset-admin-password`.** Read the current Secret value, ran the reset command inside the pod, login worked immediately.

### Architectural takeaway

Any application with a persistent DB containing credentials has this property. Future model-serving and ML-platform components (KServe, MLflow, etc.) will need the same care. The bootstrapping pattern: provide credentials via env vars on first startup, the application persists them, subsequent env-var changes are ignored. To update post-bootstrap, either wipe the PV or use the application's admin tooling to reset.


---

## Issue 14 — ArgoCD perpetual OutOfSync on controller-managed CRDs

**Phase:** Phase 4 — ESO integration

### Problem

ExternalSecret resource showed `health: Healthy, message: "Secret was synced"` (functional) but `sync: OutOfSync` (drift detected). Forcing sync didn't resolve it.

### Why it happened

External Secrets Operator's admission webhook injects default fields on ExternalSecret creation: `conversionStrategy`, `decodingStrategy`, `metadataPolicy` in `remoteRef`; `deletionPolicy` in `target`. These don't exist in the Git source, but ESO writes them to the cluster. ArgoCD compares Git vs live and sees a difference. ArgoCD's default behavior is to flag any discrepancy as drift, even controller-managed fields it shouldn't own.

### Options considered

- **A — Add controller-injected fields explicitly to Git.** Mirror the defaults in the values.yaml. Verbose, repetitive, fragile if defaults change.
- **B — Use `ignoreDifferences` in the Application.** Tell ArgoCD which fields are controller-owned. Reusable pattern, decoupled from controller version changes.

### What I chose

**B — `ignoreDifferences`** with `jqPathExpressions` for the four controller-managed fields. Added `RespectIgnoreDifferences=true` in `syncOptions` so the sync engine (not just visual diff) respects the rule.

### Architectural takeaway

**ArgoCD owns spec, the controller owns status and admission-injected fields.** This boundary is implicit but not enforced — ArgoCD doesn't know which fields are controller-owned. Use `ignoreDifferences` to make the boundary explicit. The same pattern applies to cert-manager Certificates, Karpenter NodePools, and any CRD whose controller writes status or injects defaults.


---

## Issue 15 — Architectural critique — Secret as ArgoCD Application

**Phase:** Phase 4 — refactoring

### Problem

I had created `apps/kube-prometheus-stack-secret/` as a separate ArgoCD Application managing a single ExternalSecret. The user pushed back: "treating a Secret as an Application feels weird."

### Why it happened

In Kubernetes thinking, "Application" usually means a workload that runs and does work. A Secret is configuration data consumed by workloads. Calling it an Application is a category error — and the pattern doesn't scale (imagine 30 secrets each requiring its own Application).

### Options considered

- **A — Keep separate Applications for secrets.** Conceptually awkward, ArgoCD UI fragmentation, doesn't scale.
- **B — Co-locate secrets with their consuming workload.** ArgoCD multi-source pattern: chart from one source, additional manifests (the ExternalSecret) from another source's `path` with `directory.include` filtering.
- **C — Group all secrets in one shared "external-secrets-config" Application.** Decouples secrets from consumers, creates orphan risk when workloads are deleted.

### What I chose

**B — co-located.** Moved `external-secret.yaml` into `apps/kube-prometheus-stack/` alongside the chart values. Added a third source to the Application pointing at this path with `directory.include: external-secret.yaml`. ArgoCD UI now shows the Helm chart resources and the ExternalSecret as a unified workload.

### Architectural takeaway

**Architectural instincts about "this feels wrong" are signals worth investigating.** In this case, the instinct correctly flagged that "Application per resource" doesn't scale and conflates the GitOps unit with the Kubernetes resource type. The co-located pattern with multi-source Applications is what real teams use.


---

## Issue 16 — EBS gp3 StorageClass missing from EKS defaults

**Phase:** Phase 4 — observability deployment

### Problem

Grafana PVC stuck in Pending. `kubectl describe pvc` showed: `storageclass.storage.k8s.io "gp3" not found`.

### Why it happened

EKS only creates a `gp2` StorageClass by default. The `gp3` StorageClass — modern AWS-recommended default, ~20% cheaper, decoupled IOPS/throughput — is not auto-created. Workloads asking for `gp3` get Pending PVCs that never bind.

### Options considered

- **A — Create gp3 StorageClass via Terraform in the platform module.** Architecturally clean: gp3 becomes part of cluster bootstrap, applies to every future workload.
- **B — Change values.yaml to use gp2 (legacy).** Quick patch but leaves a permanent debt — using legacy storage default in a portfolio project.

### What I chose

**A — Terraform-managed gp3 StorageClass.** Added `terraform/platform/storage_classes.tf`: removed the `is-default-class` annotation from gp2, defined gp3 with `is-default-class=true`. Every future PVC defaults to gp3 with no per-workload config.

### Architectural takeaway

On EKS, treat `StorageClass` as platform-level configuration, not workload-level. Define modern defaults (gp3) once in the platform module so individual workloads don't need to specify storage classes at all. Same principle applies to networking defaults (NetworkPolicies), security defaults (PodSecurityPolicy successors), etc. — push platform decisions to the platform layer.

---

## Issue 17 — EKS pod density wall — VPC CNI hard limit

**Phase:** Phase 4 — full observability stack

### Problem

After deploying Loki and Alloy, the kube-prometheus-stack Application went Degraded. Grafana pod stuck Pending with event: `0/2 nodes are available: 2 Too many pods.`

### Why it happened

AWS VPC CNI gives every pod a real VPC IP. Each EC2 instance has a hard limit on ENIs and IPs per ENI. A `t3.medium` can run only ~17 pods total. With ~34 platform + observability pods running, both nodes were at 100% pod capacity. Adding even one more pod (the rolling-update replacement Grafana pod) couldn't schedule.

### Options considered

- **A — Add a 3rd node.** Quick unblock, doesn't address root cause.
- **B — Use larger instance types (m5.large, ~29 pods).** Doubled cost per node, partial improvement.
- **C — Enable VPC CNI prefix delegation.** `ENABLE_PREFIX_DELEGATION=true` env var on the VPC CNI managed addon. Allocates /28 prefixes (16 IPs each) per ENI instead of single IPs. t3.medium goes from ~17 pods to ~110 pods. Cost-neutral.

### What I chose

**C — VPC CNI prefix delegation** for the long-term fix; **A** to unblock today. Added `configuration_values = jsonencode({env = {ENABLE_PREFIX_DELEGATION = "true", WARM_PREFIX_TARGET = "1"}})` to the cluster module's `vpc-cni` addon. Modern AWS-recommended approach.

### Architectural takeaway

**VPC CNI gives pods first-class VPC networking but introduces density constraints absent in overlay CNIs.** Prefix delegation removes the constraint without sacrificing the integration benefit. Always configure prefix delegation for non-trivial workloads on EKS — it's a one-line change with 6× density improvement at zero cost. This is one of the highest-ROI EKS configurations and one of the most-asked-about in interviews.


---

## Issue 18 — Minimal containers — wget not in production images

**Phase:** Phase 4 — Loki diagnostics

### Problem

Diagnostic command `kubectl exec ... wget -qO- http://localhost:3100/ready` failed with `executable file not found in $PATH`.

### Why it happened

Modern Grafana Loki container images are intentionally minimal — they ship only the `loki` binary plus a few essential utilities. No `wget`, no `curl`, no `bash` (just `sh`). This is a security and image-size best practice for production containers.

### Options considered

- **A — Use port-forward and curl from your laptop.** `kubectl port-forward svc/loki 3100:3100` then `curl http://localhost:3100/ready` from a separate terminal.
- **B — Spin up a temporary debugging pod with curl built in.** `kubectl run -it --rm tmp-curl --image=curlimages/curl ... -- curl ...`. Spins up, runs, deletes itself.
- **C — Use `kubectl debug` (newer feature).** Attach an ephemeral debug container with extra tools to a running pod.

### What I chose

Used (A) for ad-hoc verification and (B) for repeatable in-cluster checks. The mental shift: production-grade containers don't ship debugging tools, and that's correct — debugging is a separate concern with separate tooling.

### Architectural takeaway

**Production-grade container images are minimal by design.** When you can't shell in with familiar tools, the right pattern is: port-forward for one-off checks, ephemeral debug pods for in-cluster checks, kubectl debug for attaching to running pods. Trying to "fix" the lack of tooling by using bigger base images is the wrong instinct — it expands attack surface and image size for marginal debugging convenience.


---
## Issue 19 — VPC CNI prefix delegation requires TWO independent settings

**Phase:** Phase 4 — observability stack scaling

### Problem

After deploying the full observability stack, the cluster filled to 100% pod capacity. Enabled VPC CNI prefix delegation via Terraform (`ENABLE_PREFIX_DELEGATION=true` on the managed addon) and rolled the nodes. ENIs showed `/28` prefixes correctly assigned, but `kubectl get nodes -o jsonpath='...allocatable.pods...'` still reported 17 pods per node — same as before. Pods continued to fail scheduling with "Too many pods" errors.

### Why it happened

EKS pod density isn't a single setting — it's the intersection of two completely independent configurations:

1. **VPC CNI env vars** (DaemonSet level) tell the network plugin to allocate `/28` prefixes per ENI instead of individual IPs. Confirmed working when ENIs show `Ipv4Prefixes` array populated.
2. **kubelet's `--max-pods` flag** is set at node bootstrap and never recalculated during the node's lifetime. The EKS bootstrap script defaults this to the instance type's IP-allocation default (17 for t3.medium), regardless of whether VPC CNI is configured for prefix delegation.

So even with VPC CNI happily allocating prefixes, kubelet was still capping at 17 pods because that's what it was told at boot. To make matters worse, attempting the obvious fix (`bootstrap_extra_args = "--use-max-pods false --kubelet-extra-args '--max-pods=110'"`) silently produced no change in `terraform plan` — because the cluster was running **AL2023** AMIs, which use `nodeadm` for bootstrap, not the legacy `bootstrap.sh` script. The `bootstrap_extra_args` field is only honored by AL2-era bootstrap scripts. On AL2023, it's accepted by the Terraform module but produces zero effect.

### Options considered

- **A — Pin nodes to AL2 AMI for compatibility with `bootstrap_extra_args`.** Reverts to legacy AMI; misses AL2023 security/performance improvements.
- **B — Use `cloudinit_pre_nodeadm` in the EKS module to inject a NodeConfig YAML.** AL2023-correct mechanism. Sets `kubelet.config.maxPods` and the `--max-pods` flag via `nodeadm`'s native config format.
- **C — Switch to Karpenter.** Karpenter computes `max-pods` per node automatically and configures CNI mode transparently. Bigger refactor, deferred to Phase 5.

### What I chose

**B — `cloudinit_pre_nodeadm`** in `terraform/cluster/main.tf`:

```hcl
eks_managed_node_groups = {
  default = {
    # ... other config ...
    cloudinit_pre_nodeadm = [
      {
        content_type = "application/node.eks.aws"
        content      = <<-EOT
          ---
          apiVersion: node.eks.aws/v1alpha1
          kind: NodeConfig
          spec:
            kubelet:
              config:
                maxPods: 110
              flags:
                - --max-pods=110
        EOT
      }
    ]
  }
}
```

Combined with the VPC CNI env vars on the addon, this gives nodes 110 pods/node density at zero additional cost. `terraform apply` triggered a launch template version bump and node group rolling update. After the new nodes joined, `kubectl get nodes` confirmed `pods: 110`.

### Architectural takeaway

**EKS pod density is a multi-layer setting that requires alignment across configurations that look independent.** The CNI plugin, the kubelet, and the AMI's bootstrap mechanism each contribute to the final value. Setting only one of them produces silent partial failures.

The deeper lesson: **silent acceptance of configuration that doesn't take effect is the worst kind of bug.** `terraform apply` succeeded with `bootstrap_extra_args`. Nothing errored. But nothing changed either. Always verify config changes by checking the actual running state (`kubectl get nodes -o ...allocatable.pods...`), never by trusting the tool's "no errors" signal alone.

This is also one of the strongest arguments for Karpenter over managed node groups: Karpenter handles all three pieces (CNI mode, max-pods, AMI bootstrap) transparently per node. Manually configured node groups require explicit per-AMI alignment that's easy to get wrong.


---

## Issue 20 — Killed both worker nodes simultaneously, lost addon reconciliation

**Phase:** Phase 4 — recovering from the prefix delegation rollout

### Problem

To force kubelet recalculation of `allocatable.pods` after enabling prefix delegation, terminated both worker EC2 instances simultaneously. New replacement instances joined but stayed `NotReady` for 15+ minutes. `kubectl get pods -n kube-system -l k8s-app=aws-node` showed zero pods. Same for kube-proxy. Network plugin DaemonSets simply weren't getting their pods scheduled.

### Why it happened

When both nodes terminate simultaneously, the cluster has no functioning data plane for several minutes. The EKS managed addon controllers (which install `aws-node` and `kube-proxy` DaemonSets) lose their reconciliation foothold during this window — they can't query the cluster API for state, can't redeploy DaemonSets, and don't auto-recover when nodes return.

Specifically:
- DaemonSet objects survived (in etcd, managed by EKS control plane)
- But their pods on the old nodes were gone (nodes terminated)
- Replacement nodes joined fresh, no addon pods on them
- Addon controllers should have recreated the DaemonSet pods on new nodes — but didn't, because reconciliation got stuck

### Options considered

- **A — Wait longer for addon reconciliation to recover.** Could take indefinitely if the controller is wedged.
- **B — Force EKS addon reconciliation via API.** `aws eks update-addon --resolve-conflicts OVERWRITE` triggers a re-deployment from scratch.
- **C — Delete and recreate the addon entirely.** Heavier hammer; works but not necessary if (B) succeeds.

### What I chose

**B — forced reconciliation:**

```bash
aws eks update-addon \
  --cluster-name mlops-lab \
  --addon-name vpc-cni \
  --resolve-conflicts OVERWRITE \
  --profile mlops-platform --region eu-central-1

aws eks update-addon \
  --cluster-name mlops-lab \
  --addon-name kube-proxy \
  --resolve-conflicts OVERWRITE \
  --profile mlops-platform --region eu-central-1
```

Within ~60 seconds, DaemonSets redeployed onto the new nodes. Nodes transitioned to Ready. Cluster recovered.

### Architectural takeaway

**Even managed services can get into bad reconciliation states under unusual sequences.** "All worker nodes gone simultaneously" is exactly that kind of edge case. The fix pattern: explicitly trigger reconciliation via the AWS API rather than waiting for auto-recovery.

**Better practice for forcing node replacement on EKS:** roll one node at a time. Terminate one EC2 instance, wait for replacement to be Ready (`kubectl get nodes -w`), only then terminate the next. This keeps at least one node Ready throughout, preserving addon reconciliation continuity.

The saved time of terminating both at once isn't worth the recovery time when something goes wrong. This is one of those infrastructure principles that's easy to internalize after a single incident — you never make this mistake again.


---
## Issue 21 — Admission webhook deadlock locked out kube-system

**Phase:** Phase 4 — same recovery as Issue 20

### Problem

After forcing addon reconciliation in Issue 20, the new nodes were *still* NotReady. Investigation showed `aws-node` and `kube-proxy` DaemonSets had zero running pods. Pod creation events showed:

```
FailedCreate: failed calling webhook "mpod.elbv2.k8s.aws":
no endpoints available for service "aws-load-balancer-webhook-service"
```

But the AWS LB Controller pod itself couldn't run because:

```
FailedScheduling: 0/2 nodes are available:
2 node(s) had untolerated taint {node.kubernetes.io/not-ready}
```

A circular dependency.

### Why it happened

Classic Kubernetes admission webhook deadlock. The dependency chain:

1. AWS LB Controller's `MutatingWebhookConfiguration` intercepts ALL pod creation cluster-wide (default scope, no namespace selector restricting it)
2. New nodes start NotReady because their CNI plugin (aws-node) isn't running
3. aws-node DaemonSet wants to create pods on new nodes, but the webhook intercepts the create call
4. Webhook has no endpoints (LB Controller pod isn't running)
5. aws-node creation fails
6. Nodes stay NotReady
7. LB Controller pod can't schedule (NotReady taint, no toleration)
8. Webhook stays endpointless
9. Goto 5 — deadlock

### Options considered

- **A — Wait for the system to self-recover.** Would never happen — circular dependency.
- **B — Delete the MutatingWebhookConfiguration directly.** Breaks the cycle. Controller will recreate it when it starts.
- **C — Manually edit the webhook to add a namespace-scope filter.** More surgical but requires more thought; deletion is simpler emergency response.

### What I chose

**B — emergency deletion:**

```bash
kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook
```

Within ~60 seconds, kube-system DaemonSets created their pods. Nodes went Ready. AWS LB Controller pod scheduled. The controller recreated the webhook on its own startup.

### Architectural takeaway

**Mutating admission webhooks that intercept ALL pod creation (cluster-wide scope) are operationally fragile.** Even AWS-managed components like aws-node depend on pods being creatable, which means they depend on the webhook being callable, which means they depend on the controller being running, which depends on the cluster having Ready nodes... circular dependency land.

**Best practice:** scope every cluster-wide webhook to opted-in namespaces, never letting it intercept kube-system or other infrastructure namespaces. The AWS-recommended pattern for the LB Controller specifically:

```yaml
webhookNamespaceSelectors:
  - key: elbv2.k8s.aws/pod-readiness-gate-inject
    operator: In
    values: ["enabled"]
```

This makes the webhook opt-in: it applies only to namespaces explicitly labeled to receive readiness gate injection. Default behavior: webhook applies to nothing.

**The emergency lever** — `kubectl delete mutatingwebhookconfiguration <name>` — is worth memorizing. When a cluster is hopelessly deadlocked because a webhook is unreachable, this command is your last resort. The controller will recreate the webhook when it starts.

---
---
## Issue 22 — EKS Extended Support pricing trap

**Phase:** Phase 4.5 — Kubernetes version upgrade

### Problem

May 2026 bill showed $26.95 for EKS against an expected ~$8. Line item
breakdown revealed two separate charges for the exact same 44.917
cluster-hours: `Amazon EKS cluster usage` at $4.49 and `Amazon EKS
extended support usage` at $22.46. The cluster had been on Kubernetes
1.31.

### Why it happened

EKS bills the control plane in two tiers based on Kubernetes minor
version:

- **Standard support:** $0.10/hr — the price everyone quotes and
  budgets for
- **Extended support:** $0.60/hr — triggered automatically when your
  version exits the ~14-month standard support window

The transition is silent. No banner in the EKS console. No warning
during `terraform apply`. AWS sends a Health Dashboard notification
60+ days in advance, easy to miss. The cluster continues running
normally — the only signal is a Cost Explorer line item, and only if
you expand the EKS breakdown.

The compounding factor: my `kubernetes_version` variable had a comment
saying `# Latest stable EKS version as of early 2026`. It was accurate
when written. It silently became wrong as the support window moved.

### Options considered

- **A — Upgrade the running cluster sequentially (1.31 → 1.32 → 1.33
  → 1.34).** Correct approach for long-lived production clusters where
  destroy is not an option. Each step takes 15–20 minutes, must be done
  one minor version at a time.
- **B — Destroy and recreate at the target version directly.** Valid
  only for ephemeral clusters. Jump to any supported version in a single
  apply — no sequential steps needed.

### What I chose

**B** — destroyed the cluster, updated `kubernetes_version = "1.34"` in
`terraform/cluster/variables.tf`, applied fresh. The ephemeral
destroy/apply workflow turns a multi-hour sequential upgrade into a
single variable change. Updated the variable description to document the
current support window explicitly so the drift can't silently recur.

```hcl
variable "kubernetes_version" {
  type    = string
  default = "1.34"
  description = <<-EOT
    Kubernetes minor version for EKS control plane and managed addons.
    Standard support window (no surcharge) as of May 2026:
      Standard : 1.33, 1.34, 1.35, 1.36
      Extended  : 1.30, 1.31, 1.32  ← 6x hourly cost, avoid these
    Review quarterly:
    https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
  EOT
}
```

### Architectural takeaway

This is a **time-decaying configuration** — correct when written,
silently wrong as time passes, with financial consequences. The same
pattern applies to TLS certificates, IAM access keys, container base
images with known CVEs, and deprecated API versions. A robust platform
needs a mechanism to surface these proactively: variable descriptions
with expiry context, quarterly version reviews, and billing alarms set
low enough to catch the change within days rather than at month-end.

For a personal lab this cost ~€20 extra. At 200 clusters with a $0.50/hr
surcharge, that is $876,000/year of preventable spend. The fix is always
the same: lifecycle awareness, not reactive billing analysis.


---
## Issue 23 — Interactive Terraform destroy prompt as a cost risk

**Phase:** Phase 4.5 — operational discipline

### Problem

Ran `terraform destroy` at the end of a Saturday session, saw the
confirmation prompt, got distracted by personal work, and forgot to
answer it. The cluster ran unattended from Saturday 6 PM to Monday
8 AM — approximately 38 hours — billing continuously at the
extended-support rate throughout that window.

### Why it happened

The Terraform confirmation prompt (`Do you really want to destroy all
resources? Enter 'yes' to confirm`) is designed as a safety gate. In a
daily destroy/apply workflow, it becomes a liability — a hanging process
that is indistinguishable from a completed destroy if you walk away
before answering.

The failure mode is subtle: shell history shows the `terraform destroy`
command was run. The terminal is not closed. Nothing signals that it is
waiting for input. Easy to assume it completed.

### Options considered

- **A — Always verify completion before walking away.** Run an explicit
  post-destroy check (`aws eks list-clusters`, `aws ec2
  describe-nat-gateways`) as a manual step after every session. Simple,
  requires no tooling changes, but depends on discipline.
- **B — Move to `-auto-approve` with the safety gate at the Taskfile
  level.** The Taskfile `prompt` field presents a confirmation before
  the automation starts. Once confirmed, terraform never waits for
  input again. The hanging-prompt failure mode is eliminated entirely.

### What I chose

**A** as an immediate habit change, **B** as the target state once the
Taskfile is formalised in Phase 5. Added the following end-of-session
verification as a discipline until then:

```bash
# Run after every destroy — only walk away when both return empty
aws eks list-clusters \
  --region eu-central-1 \
  --profile mlops-platform
# Expected: { "clusters": [] }

aws ec2 describe-nat-gateways \
  --region eu-central-1 \
  --profile mlops-platform \
  --filter "Name=state,Values=available,pending" \
  --query 'NatGateways[].NatGatewayId'
# Expected: []
```

Target Taskfile pattern for Phase 5:

```yaml
tasks:
  mlops-down:
    desc: "Destroy MLOps platform — confirms before proceeding"
    prompt: "This will destroy the entire MLOps cluster. Continue?"
    cmds:
      - cd terraform/platform && terraform destroy -auto-approve
      - cd terraform/cluster && terraform destroy -auto-approve
      - cd terraform/network && terraform destroy -auto-approve
```

### Architectural takeaway

**Interactive prompts mid-automation are a liability in daily
workflows.** The discipline for ephemeral lab infrastructure: make the
workflow either fully automated with a pre-flight confirmation at a
higher level, or fully manual with an explicit end-state verification
step. Never a hybrid where the automation requires a mid-run human
response that is easy to miss.

This incident also illustrates why low-threshold billing alarms matter
independently of operational discipline. Even with perfect habits,
unexpected spend happens. A CloudWatch billing alarm at €15/month would
have surfaced this by Sunday morning rather than at month-end.


---
## Issue 24 — StatefulSet `creationTimestamp: null` causes permanent ArgoCD OutOfSync loop

**Phase:** Phase 4.5 — GitOps validation post cluster rebuild

### Problem

After a clean cluster rebuild on Kubernetes 1.34, the Loki Application
showed `Healthy` but `OutOfSync`. ArgoCD had performed 17 automated
self-heal attempts in a single session — each one succeeding (`Sync OK`,
`phase: Succeeded`), then immediately triggering again. The diff showed
a single line on the live side that was absent from Git:

```yaml
# Live cluster (right side of diff)
metadata:
  creationTimestamp: null   # ← injected by Kubernetes API server
  name: storage
```

### Why it happened

Kubernetes automatically injects `creationTimestamp: null` into
`volumeClaimTemplates.metadata` when storing a StatefulSet — a field
the API server adds that does not exist in the Helm chart output and
should not be added to Git. ArgoCD detects this as drift, syncs the
StatefulSet (succeeds), Kubernetes immediately re-injects the field,
ArgoCD detects drift again. Infinite loop.

Two attempted fixes did not resolve it:

**Attempt 1 — `ignoreDifferences` with `jsonPointers`:**
```yaml
ignoreDifferences:
  - group: apps
    kind: StatefulSet
    name: loki
    jsonPointers:
      - /spec/volumeClaimTemplates/0/metadata/creationTimestamp
```
Still OutOfSync.

**Attempt 2 — `ignoreDifferences` with `jqPathExpressions` plus
`RespectIgnoreDifferences=true`:**
```yaml
ignoreDifferences:
  - group: apps
    kind: StatefulSet
    name: loki
    jqPathExpressions:
      - .spec.volumeClaimTemplates[].metadata.creationTimestamp
syncOptions:
  - RespectIgnoreDifferences=true
```
Still OutOfSync.

Both attempts failed because the Application had `ServerSideApply=true`
in `syncOptions`. This is a confirmed open bug in ArgoCD (issues #11143
and #24791, present from v2.x through v3.x): `ignoreDifferences` is not
reliably respected by the server-side apply diff engine for
`volumeClaimTemplates` fields, regardless of whether `jsonPointers` or
`jqPathExpressions` is used.

### Options considered

- **A — Remove `ServerSideApply=true` from the Loki Application.**
  Loki has no CRDs and no admission webhooks requiring server-side field
  ownership tracking. Client-side apply is correct for this workload.
  `ignoreDifferences` with `jsonPointers` works correctly under
  client-side apply.
- **B — Fix at the `argocd-cm` ConfigMap level with a global
  `managedFieldsManagers` customisation.** System-wide change affecting
  all StatefulSets. Not GitOps-managed unless patched into the ArgoCD
  Helm values. Heavier and broader than the problem warrants.

### What I chose

**A — removed `ServerSideApply=true` from the Loki Application.**
Resolved immediately on the next ArgoCD reconciliation. Final working
manifest:

```yaml
ignoreDifferences:
  - group: apps
    kind: StatefulSet
    name: loki
    jsonPointers:
      - /spec/volumeClaimTemplates/0/metadata/creationTimestamp

syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
    # ServerSideApply=true ← removed; not needed for this workload
```

### Architectural takeaway

**`ServerSideApply` and drift protection are orthogonal concerns that
are easy to conflate.**

- `selfHeal: true` protects against humans changing cluster state —
  ArgoCD detects and reverts manual `kubectl edit` changes.
- `ServerSideApply=true` protects against multiple controllers
  overwriting each other's fields — relevant when ArgoCD and an HPA,
  or ArgoCD and a mutating webhook, share ownership of the same fields.

They solve different problems. Applying `ServerSideApply` as a blanket
option to all Applications introduces this `volumeClaimTemplates` diff
bug for any StatefulSet-based workload without providing any benefit
unless competing field ownership actually exists.

Any StatefulSet with `volumeClaimTemplates` is susceptible to the
`creationTimestamp` drift on every fresh cluster bring-up. It is a
predictable first-deploy issue to check for on Loki, Prometheus,
any database-backed workload, and any future ML platform component
(KServe model servers, MLflow tracking server) added in Phase 6.



---

## Cross-cutting themes

Reading the 18 issues together, several patterns emerge that are worth treating as their own interview material:

### 1. The "verify before pinning" discipline

Three issues (Helm chart repo URLs, stale chart versions, structural drift between major versions) all stem from trusting documentation or memory rather than running quick verification commands. The discipline I now follow before any Helm-based work: `helm repo update` → `helm search repo --versions` → `helm show values` → `helm template`. Maybe 90 seconds total. Catches ~80% of "silently misconfigured chart" bugs.

### 2. Cost-vs-reliability trade-offs

NAT instance vs Gateway, t3.medium vs m5.large, default VPC CNI vs prefix delegation — recurring theme of "the cheaper option introduces failure modes that cost more than the savings during a single incident." Production-grade infrastructure favors managed services where the cost-vs-reliability trade-off is favorable. Lab projects can afford to demonstrate awareness of this trade-off in ADRs even when the lab choice is the cheaper one.

### 3. Bootstrap and the chicken-and-egg problem

GitOps tools manage applications, but those tools themselves must be installed before they can manage anything. Same for CRDs and the custom resources that use them. Same for admission webhooks and the workloads they intercept. The architectural answer is consistent: whoever owns infrastructure (Terraform) owns the bootstrap. Tools that need to exist before GitOps can run cannot themselves be installed via GitOps.

### 4. ArgoCD owns spec, controllers own status

ArgoCD's default drift detection conflicts with controller-managed fields on CRDs. ESO injects defaults; cert-manager writes Certificate status; Karpenter writes NodePool status. The boundary exists implicitly but isn't enforced — you make it explicit with `ignoreDifferences` per Application. The same pattern recurs throughout production GitOps; learn it once, apply it everywhere.

### 5. Production-grade containers are minimal

Loki has no wget. Grafana has no curl. Some containers don't even have bash. This is correct behavior — debugging tools expand attack surface and image size. The right debugging pattern is port-forward + tools-on-your-laptop, ephemeral debug pods, or kubectl debug. Knowing this distinguishes "I've operated production Kubernetes" from "I've read tutorials."

---

## Closing reflection

The value of this build isn't the cluster itself — it's the catalogue of decisions and recoveries that produced it. That catalogue is what distinguishes a senior architect from a tutorial follower.

Several of these stories — particularly the NAT instance failure, the pod density wall, and the Grafana credential caching — are the kind of "tell me about a time you debugged a production issue" answers that interviewers value. They show real, hands-on troubleshooting under time pressure, with cost implications, and with architectural reasoning rather than just "I rebuilt it."

If you're reading this looking to learn from someone else's mistakes: each issue here cost between 15 minutes and 2 hours of debugging time. The lessons are cheaper to read than to learn.
