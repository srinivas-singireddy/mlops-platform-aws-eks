# ADR 0006: Observability via GitOps

## Status
Accepted — 2026-04-29

## Context
The platform needs metrics, logs, and dashboards. The two main options:

1. **Cloud-native:** AWS CloudWatch + Container Insights + Managed Grafana
2. **Self-hosted:** kube-prometheus-stack + Loki + Promtail in cluster

## Decision
Self-hosted via GitOps:
- kube-prometheus-stack (Prometheus, Grafana, Alertmanager) for metrics
- Loki + Promtail for logs
- All deployed via ArgoCD watching the deploy repo
- Each component is an ArgoCD Application with Helm values pinned to
  specific chart versions

## Consequences

**Accepted:**
- Portable across clouds — same stack works on GKE, AKS, on-prem
- Vendor-neutral skill demonstration — what most companies actually run
- Single Grafana for both metrics and logs (correlation across both)
- Free (besides the EBS storage); CloudWatch Container Insights starts
  at ~€2/GB ingested

**Traded away:**
- Operational burden (we patch, upgrade, manage retention)
- Storage management — Prometheus and Loki PVs are our problem
- No tight EKS integration (CloudWatch Logs, X-Ray tracing) without
  additional setup

**Mitigations:**
- Lab-scoped retention (7 days) keeps storage costs minimal
- ArgoCD's automated sync + selfHeal means manual interventions are
  reverted to Git's version
- Chart versions are pinned, not "latest" — predictable upgrades

## Alternatives considered
1. **AWS Container Insights + CloudWatch Logs + Managed Grafana**:
   rejected, vendor-locks the observability skill set
2. **Datadog or New Relic**: rejected, recurring SaaS cost; doesn't
   demonstrate self-hosting capability
3. **Distributed Loki** (read/write/backend split): rejected for lab,
   single-binary is simpler and equivalent for this scale

## EKS-specific notes
kube-prometheus-stack assumes it can scrape kube-etcd, scheduler,
controller-manager, and kube-proxy directly. On EKS, the first three
are AWS-managed and unreachable; kube-proxy runs but on a non-default
port. We disable these scrape targets in values.yaml to avoid spurious
alerts.

## Follow-ups
- Switch Loki to S3 backend for durability across cluster recreates
- Add ALB Ingress + Let's Encrypt TLS for Grafana (deferred until
  domain is acquired)
- Consider Tempo for distributed tracing in a future phase


## Implementation note — log collector choice

Initially the plan called for Promtail (the long-time default Loki agent).
During Phase 4, we noticed that Promtail reached End-of-Life on March 2,
2026. Grafana Labs has migrated all log-collection development to Grafana
Alloy, their distribution of the OpenTelemetry Collector.

We chose Alloy over Promtail for three reasons:
1. Future-proof — Promtail receives no further updates or security patches
2. Unified telemetry — single agent for logs, metrics, traces, profiles
3. OTLP-native — important for the future ML-platform phase where model
   serving emits OpenTelemetry data directly

The Loki Helm chart itself moved from grafana/helm-charts to
grafana-community/helm-charts on March 16, 2026. We use the new repo
from initial deployment.

Architectural takeaway: portfolio projects benefit from being current.
Demonstrating Promtail in 2026 would signal "this person is following
old tutorials"; demonstrating Alloy signals awareness of the ecosystem's
evolution. Worth a few hours of research before adopting any
"recommended" component.

## Implementation note — Helm chart repository discipline

The Grafana ecosystem split its Helm charts in early 2026:
- Commercially-maintained charts (Alloy, Mimir, Tempo, Pyroscope) stay
  at https://grafana.github.io/helm-charts
- Community-maintained charts (Grafana OSS, Loki, Promtail) moved to
  https://grafana-community.github.io/helm-charts

These look symmetrical but are different repos with different
maintenance models. Pinning the wrong URL means the chart won't
resolve at all.

Architectural takeaway: Helm chart repo URLs are not stable across
projects you'd think are related. Always verify the current repo
via artifacthub.io or the project's README before pinning. For
reproducibility, prefer pinning a specific chart version (e.g.
targetRevision: 0.10.1) rather than letting Helm resolve "latest"
— a chart that moves repos can break a "latest" install silently.

## Implementation note — chart-version structural drift

When pinning Helm chart versions, structural drift between major
versions is the silent killer. The Loki chart between 6.x and 13.x
moved `deploymentMode` from top-level into the `loki:` block, renamed
the `SingleBinary` value to `Monolithic`, and changed the conditional
logic of the `singleBinary:` config block.

A `values.yaml` written for 6.x silently produces wrong behavior in
13.x — fields are ignored, defaults apply, and the resulting pods
look like they're working but aren't configured as intended.

Discipline: before any chart-version upgrade, run
  helm show values <chart> --version <new-version>
and diff against the structure of your existing values.yaml. Look
for keys that disappeared, were renamed, or moved nesting levels.

This isn't unique to Loki — the same pattern affects nearly every
mature Helm chart. Plan for it as part of upgrade reviews.

## Implementation note — Helm values structure verification

For any new Helm chart at any version, before committing your
values.yaml to Git, run:

  helm show values <chart-repo>/<chart-name> --version <version> | grep -E "^[a-z]+:"

This shows the chart's expected top-level keys. Cross-reference your
values.yaml against this list:
- Keys you reference must appear at the right nesting level
- Keys not in the chart's structure are silently ignored
- Renaming/moving fields between major versions is common

Then validate the rendering:

  helm template <release> <chart-repo>/<chart-name> --version <version> \
    --values your-values.yaml --namespace <ns> > /tmp/rendered.yaml
  grep -E "^kind:" /tmp/rendered.yaml | sort | uniq -c

This shows what resources will actually be created. Verify the
Kubernetes resource types and counts match expectations before push.

Combined, these two commands take 15 seconds and catch ~80% of
"silently misconfigured" Helm deployments.

## Implementation note — Loki has no standalone UI

Loki is purposefully a storage+query backend with no built-in UI.
The architectural decision: visualization is delegated to Grafana,
which has a mature UI and treats Loki as a queryable datasource
alongside Prometheus, Tempo, etc.

This means:
- Users interact with logs only through Grafana's Explore tab
- Alloy writes to Loki via HTTP API (port 3100)
- Grafana reads from Loki via the same API
- No "Loki dashboard URL" to expose externally
- Operators query Loki directly only via logcli (CLI tool) or
  raw curl for debugging

For the platform's externally-exposed UIs, this means we have:
- ArgoCD UI (GitOps state)
- Grafana UI (metrics, logs, dashboards — single pane of glass)

We do NOT need to expose Loki separately, simplifying ALB/Ingress
configuration and reducing attack surface.

## Implementation note — VPC CNI pod density limits

Encountered the EKS pod density wall during Phase 4: a t3.medium worker
node can only run ~17 pods due to AWS VPC CNI's default IP allocation
strategy (each pod gets a real VPC IP, capped by ENI/IP-per-ENI limits
of the instance type).

With ~17 platform pods (ArgoCD, cert-manager, ESO, ALB controller,
EBS CSI, CoreDNS, system pods) and ~17 observability pods (Prometheus,
Grafana, Alertmanager, Loki, Alloy, node-exporter), the 2-node t3.medium
cluster filled to 100% capacity. New pods couldn't schedule, ArgoCD
reported Degraded.

Three solution paths considered:
1. Add a 3rd node — quick fix, doesn't address root cause
2. Use larger instance types (m5.large, ~29 pods) — incremental improvement
3. Enable VPC CNI prefix delegation — assigns /28 prefixes, ~110 pods
   per t3.medium

Adopted (3) for the long-term solution: cost-neutral, 6× density
improvement, modern AWS-recommended approach. Documented in
`terraform/cluster/main.tf` cluster_addons.vpc-cni configuration_values.

Architectural lesson: VPC CNI gives pods first-class VPC networking
(security groups, flow logs, native AWS integration) but introduces
density constraints absent in overlay CNIs. Prefix delegation removes
the constraint without sacrificing the integration benefit. Always
configure prefix delegation for non-trivial workloads on EKS.