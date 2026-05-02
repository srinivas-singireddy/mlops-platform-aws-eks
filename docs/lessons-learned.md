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

### Interview talking point

> "I initially deployed a NAT instance instead of NAT Gateway to save about 30 euros a month. The first non-trivial workload — EKS node group bootstrap — failed because the instance's iptables config didn't apply reliably on first boot. I spent 30 minutes debugging, then made the call to switch to NAT Gateway. The architectural lesson: cost optimizations that increase failure surface aren't actually optimizations. A single recovery incident wiped out the savings. I documented the original choice and the revision in the same ADR — that postmortem is itself the most valuable artifact from the experience."

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

### Interview talking point

> "On EKS, every fresh cluster gets a new API endpoint hostname with a unique cluster-ID hex. After destroy/apply, your local kubeconfig points at yesterday's cluster, which no longer exists. The fix is `aws eks update-kubeconfig`. I built it into my daily up/down automation so I don't have to remember it. I also use a `kctx` shell alias that prints the current context — prevents the all-too-common 'I just deleted production' moment when you have multiple clusters."

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

### Interview talking point

> "The official Kubernetes provider validates manifests at plan time against the cluster's schema. That breaks if you're installing a CRD and a custom resource of that CRD in the same Terraform module — at plan time the CRD doesn't exist yet, so plan fails. The standard fix in the community is the gavinbunney/kubectl provider, which uses `kubectl_manifest` and doesn't validate until apply time. I document this choice in an ADR so future engineers don't 'fix' my code back to the official provider and break it."

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

### Interview talking point

> "The AWS Load Balancer Controller registers a cluster-wide MutatingWebhookConfiguration on Services. By default it applies to every namespace — including namespaces of platform components installed in the same Terraform apply. If the LB controller pods aren't Ready when cert-manager creates its internal Services, Helm install fails. Three guards together solve it: `wait = true` so Terraform doesn't consider the LB controller 'done' until pods are Ready, namespace selectors that scope the webhook to opted-in namespaces, and explicit `depends_on` from downstream releases. The architectural lesson: cluster-wide admission webhooks introduce ordering dependencies between otherwise-independent Helm releases."

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

### Interview talking point

> "I configured a Helm chart's namespaceSelector with a `set` block that included a string `'false'`. Helm's `set` re-encodes through YAML, where unquoted `false` becomes a boolean. Kubernetes rejected the resulting MutatingWebhookConfiguration because the API expects a list of strings, not booleans. Two fixes: escape-quote the value, or switch the entire helm_release to `values = [yamlencode(...)]`. I picked yamlencode because it preserves HCL types end-to-end with no encoding ambiguity. Architectural lesson: prefer yamlencode over set blocks for any non-trivial Helm chart configuration."

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

### Interview talking point

> "I had been writing single-line set blocks with semicolons separating attributes — which works in some HCL dialects but is invalid in Terraform HCL2. The linter caught it; `terraform validate` would have too if I'd run it. The lesson: I always run `fmt`, `validate`, then `plan` now, in that exact order. Pre-commit hooks enforce `fmt` and `validate` automatically so the discipline isn't something I have to remember."

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

### Interview talking point

> "My instinct after a series of code changes was to destroy and rebuild for certainty. I caught myself and ran `terraform plan` first — it showed only minor cosmetic changes, no actual drift. Destroying would have cost me 30 minutes and taught me nothing. The architectural lesson: in production you can't destroy and rebuild at will, so you build the habit of trusting the plan diff in the lab too. 'Plan, decide, act' beats 'destroy when uncertain' every time."

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

### Interview talking point

> "In a two-repo GitOps pattern, you need exactly one bridge — an ArgoCD Application pointing at the deploy repo. When I first set this up, I applied the bridge manually with kubectl. After destroy/apply, it was gone, and the cluster came up with ArgoCD healthy but empty. I moved the bridge to Terraform via the kubectl provider's `kubectl_manifest`. The architectural lesson: in GitOps, bootstrap is the chicken-and-egg moment, and whoever owns infrastructure must own the bootstrap manifest."

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

### Interview talking point

> "I was about to deploy Promtail as my log shipper, then noticed in Grafana's docs that it had reached EOL on March 2, 2026 and all development had moved to Grafana Alloy. I made the switch before deploying. The lesson: any tutorial more than 12 months old needs verification against current project documentation. Tooling in the cloud-native space moves fast — Promtail, Calico, Flannel, Helm v2 are all examples of 'what tutorials still teach' diverging from 'what production teams actually run.'"

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

### Interview talking point

> "When I was setting up the LGTM stack, Loki and Alloy ended up in different Helm repos despite both being from Grafana Labs. Grafana split their charts in early 2026 into commercial-tier and community-tier repos. The URLs look symmetrical but are different. I now verify every chart's current repo before pinning, and prefer specific version pins over 'latest' — a chart that moves repos can break a 'latest' install silently."

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

### Interview talking point

> "I ran into stale chart version numbers carried forward from older tutorials. The right discipline: `helm search repo --versions` is a 10-second check that prevents real bugs. I now verify every targetRevision against live `helm search` output before pinning. This is part of a four-step pre-commit pattern I follow for any Helm-based work: search for current version, show values for current structure, render with my values via helm template, then commit. Maybe 90 seconds total, catches 80% of 'silently misconfigured chart' bugs."

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

### Interview talking point

> "I was about to deploy Loki using values.yaml written for an older chart version. Helm charts are tolerant — they silently ignore unrecognized fields and apply defaults. The chart would have deployed but in the wrong mode, with wrong config. I caught it by running `helm show values` against the current chart version and `helm template` to inspect the rendered output. The architectural lesson: chart-version structural drift is silent. Always verify your values.yaml against the chart's current expected structure before pinning."

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

### Interview talking point

> "Grafana stores admin credentials in two places: env vars from the Secret, and an internal SQLite database on the PVC. On first startup, env vars seed the DB. After that, env-var changes are ignored — the DB is the source of truth. So switching to ESO-sourced credentials after Grafana already started didn't actually update the live password. The fix is `grafana cli admin reset-admin-password` inside the pod once. Architectural takeaway: any application with a persistent DB containing credentials has this property; account for it when designing credential rotation."

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

### Interview talking point

> "When you have a CRD managed by another controller, ArgoCD's default drift detection conflicts with that controller. ArgoCD reports OutOfSync because the controller writes fields ArgoCD doesn't see in Git. The fix is `ignoreDifferences` with jqPathExpressions for the controller-owned fields, plus `RespectIgnoreDifferences=true` in syncOptions so the sync engine respects the rule. Architectural takeaway: in GitOps, ArgoCD owns spec, and other controllers own status and admission-injected fields. That boundary is implicit but not enforced — you have to make it explicit per Application."

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

### Interview talking point

> "I had each secret as its own ArgoCD Application — clean conceptually but it doesn't scale and it conflates GitOps reconciliation units with Kubernetes resource types. I refactored to co-locate secrets with their consuming workloads using ArgoCD's multi-source pattern: the chart from one source, supporting manifests like ExternalSecrets from another source filtered to a specific path. Each workload's folder now contains its chart values, its secrets, and any other supporting resources — single mental unit per workload. Scales naturally to dozens of workloads."

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

### Interview talking point

> "EKS only creates a gp2 StorageClass by default. gp3 is the modern default — ~20% cheaper, decoupled IOPS from size — but you have to define it yourself. I added a `storage_classes.tf` to the platform Terraform module that defines gp3 and unsets gp2's default annotation. Every future workload now gets gp3 without specifying storage classes. The lesson: treat StorageClass as platform infrastructure, not workload config."

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

### Interview talking point

> "On EKS, the default VPC CNI gives every pod a real VPC IP, capped by ENI/IP-per-ENI limits of the instance type. A t3.medium can only run about 17 pods. I hit this wall when my observability stack pushed the cluster past capacity. The fix is enabling VPC CNI prefix delegation — `ENABLE_PREFIX_DELEGATION=true` on the managed addon. Prefix delegation allocates /28 prefixes (16 IPs each) per ENI instead of individual IPs, raising t3.medium density to ~110 pods. Cost-neutral, modern AWS-recommended approach. Architectural lesson: VPC CNI gives pods first-class VPC networking but introduces density constraints. Prefix delegation removes them without sacrificing the integration benefit. Always configure it for non-trivial production EKS clusters."

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

### Interview talking point

> "I tried to verify Loki health with `kubectl exec` and a wget command. The command failed because Loki's container is minimal — no wget, no curl, just the binary. This is correct behavior for production-grade images. The right pattern is port-forward + curl from your laptop, or spin up a one-off curl pod with `kubectl run`. Architectural principle: minimal containers are the goal; debugging is a separate concern with separate tooling."

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
