# ADR 0003: Community EKS Module with Managed Spot Node Group

## Status

Accepted — 2026-04-23

## Context

Provisioning an EKS cluster in Terraform involves ~40 interconnected
resources: the control plane itself, IAM roles for cluster and nodes,
security groups, OIDC provider for IRSA, managed addons, launch
templates, node groups, and the complex interaction between them.

Writing this from scratch is possible but well-documented as a
time-sink. The community module `terraform-aws-modules/eks/aws` has
been battle-tested across thousands of deployments.

## Decision

- Use `terraform-aws-modules/eks/aws` v20.x as the EKS provisioning module
- Kubernetes version: 1.31 (current stable for EKS)
- Single managed node group using **spot instances**
  (t3.medium + t3a.medium for pool diversification)
- Enable IRSA (OIDC provider) for ServiceAccount-to-IAM-role binding
- Core managed addons: CoreDNS, kube-proxy, VPC CNI, EBS CSI driver
- Public API endpoint (open CIDR) — lab only

## Consequences

**Accepted:**

- ~1 day to working cluster vs estimated 3–5 days writing from scratch
- Battle-tested patterns for cluster auth, IRSA, addon lifecycle
- Spot instances: ~70% cheaper than on-demand; acceptable for lab
- IRSA from day 1 means every downstream workload uses least-privilege IAM
- Managed addons auto-upgrade with cluster minor version

**Traded away:**

- Don't fully understand every resource the module creates
  (mitigated: plan output reviewed carefully before apply)
- Module version upgrades can introduce breaking changes — pinned to
  `~> 20.31` to minimize surprise
- Spot nodes can be reclaimed with 2-minute warning
  (mitigated: lab has no SLA; workloads will be stateless)
- Public API endpoint accepts auth attempts from anywhere
  (mitigated: IAM auth required; cluster-creator-admin scoped to my
  IAM user; lock down before any sensitive data lands here)

## Alternatives considered

1. **Write EKS from scratch**: rejected, well-known time sink,
   no portfolio value from reinventing boilerplate.
2. **Fargate-only**: rejected, limits workload types (no DaemonSets,
   no EBS, no Karpenter), and Phase 5 of this project needs GPU nodes
   which Fargate doesn't support at all.
3. **Self-managed node group**: rejected, adds operational work
   (ASG lifecycle, node drain, AMI updates) that managed node groups
   handle for free.
4. **On-demand nodes**: rejected, 3x cost for no lab benefit.
   Spot reclaim events are themselves a useful thing to observe.

## Follow-ups

- Before any production-class workload: lock `cluster_endpoint_public_access_cidrs`
  to specific IPs, add a second node group for system workloads, add
  Karpenter for just-in-time node scaling
- Consider a Fargate profile for tiny workloads where per-pod billing wins
- Replace cluster-creator-admin with proper RBAC via access entries for
  multiple users
