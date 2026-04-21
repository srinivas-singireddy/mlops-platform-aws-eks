# ADR 0001: Single AWS Account, Single Region (eu-central-1)

## Status
Accepted — 2026-04-20

## Context
This project is a learning portfolio piece demonstrating MLOps platform
architecture on AWS EKS. It is operated by a single engineer, funded from
personal budget, and intended to be destroyed and re-applied regularly
to control costs.

A "real" enterprise landing zone would typically use:
- Multiple AWS accounts (Organizations + Control Tower) — one for
  networking, one per environment, one for logging, etc.
- Multi-region for DR
- Transit Gateway / RAM for cross-account networking
- Centralized IAM via Identity Center

## Decision
Use a single existing AWS account, single region (eu-central-1 Frankfurt),
with a dedicated IAM user (`terraform-mlops-platform`) holding
AdministratorAccess, scoped by resource tagging (`Project=mlops-platform`).

## Consequences

**Accepted:**
- Simpler bootstrapping; no Organizations setup needed
- Lower cost (no cross-account data transfer, one NAT instance, one EKS
  control plane)
- Faster iteration

**Traded away:**
- Cannot demonstrate multi-account blast-radius patterns in this project
- IAM permissions are broader than would be appropriate for production
- No built-in environment segregation (dev/staging/prod) — would need
  separate workspaces/states to simulate

**Mitigations:**
- All resources are tagged `Project=mlops-platform, Environment=lab, ManagedBy=terraform`
- Budget alerts set at €50/month with forecast alarms
- Cost anomaly detection active
- Project treated as ephemeral: `terraform destroy` is the norm, not the exception

## Alternatives considered
1. **Fresh AWS account with Organizations:** would enable stronger blast
   radius controls but adds 1-2 days of bootstrap that don't advance the
   core project goals.
2. **LocalStack or kind:** would eliminate AWS cost entirely but loses
   the "real EKS" signal that's the main portfolio value.

## Follow-ups
- If this project is extended into a full enterprise reference, migrate
  to a multi-account Control Tower landing zone — tracked in FUTURE.md.
