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