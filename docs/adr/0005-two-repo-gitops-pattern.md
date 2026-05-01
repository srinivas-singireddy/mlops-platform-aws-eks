# ADR 0005: Two-Repo GitOps Pattern

## Status
Accepted — 2026-04-29

## Context
The platform supports two distinct categories of change:
- Infrastructure changes (network, EKS cluster, IAM, platform services)
  — released weekly to monthly, require operator action, require AWS API
  privileges
- Application changes (workloads, dashboards, ML services) — released
  many times per day, ideally automated, scoped to Kubernetes only

Mixing these in one repository creates noise, complicates access control,
and obscures the GitOps narrative.

## Decision
Two repositories:

- **mlops-platform-aws-eks** — infrastructure (Terraform) and platform
  services. Operator-driven via `terraform apply`. Owns AWS resources.
- **mlops-platform-deploy** — Kubernetes Application manifests watched
  by ArgoCD. Changes here reconcile automatically to the cluster.

A single bootstrap Application lives in mlops-platform-aws-eks
(`k8s/bootstrap/root-app.yaml`) and points ArgoCD at the deploy repo's
`apps/` folder, implementing the app-of-apps pattern.

## Consequences

**Accepted:**
- Clean separation of infra and app concerns
- ArgoCD watches a stable repo not affected by infra changes
- Deploy repo changes have low-friction review and merge
- Conventional industry pattern — easy to onboard others

**Traded away:**
- Two repos to maintain (READMEs, branch protection, CI configs)
- Cross-repo changes need coordination

**Mitigations:**
- Both READMEs cross-link
- This ADR documents the boundary

## Alternatives considered
1. **Single repo (monorepo)**: rejected, mixes infra/app concerns and
   creates noisy Git history
2. **Three+ repos** (per-app deploy repos): rejected, overkill for a
   single-engineer project


## Implementation note — bootstrap automation

The two-repo pattern requires a single bridge: an ArgoCD Application
in the cluster that points at the deploy repo. Without it, ArgoCD
has no idea what to deploy, even if all the YAML in the deploy repo
is correct.

The bridge resource (k8s/bootstrap/root-app.yaml) lives in this
repo but must be applied to the cluster as part of platform bootstrap.
We apply it via Terraform's kubectl_manifest resource in the platform
module, so a clean `terraform apply` produces a fully-functional
GitOps cluster — no manual `kubectl apply` step required.

Architectural lesson: in GitOps, "bootstrap" is the chicken-and-egg
moment where Git-managed manifests don't yet exist in the cluster.
Whoever owns infrastructure (Terraform, in our case) must own the
bootstrap manifest, because no other tool can apply it before
itself exists.