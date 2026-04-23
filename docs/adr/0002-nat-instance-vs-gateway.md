# ADR 0002: NAT Instance over NAT Gateway

## Status

Accepted — 2026-04-20

## Context

Private subnets in the VPC need outbound internet access for package
installs, ECR image pulls, OS updates, and AWS API calls that don't have
VPC endpoints. AWS offers two NAT options.

## Decision

Use a `t4g.nano` NAT instance (Amazon Linux 2023, ARM) with IP forwarding
and iptables MASQUERADE, rather than AWS's managed NAT Gateway.

## Consequences

**Accepted:**

- Monthly cost: ~€3 vs ~€32 for NAT Gateway (≈10× cheaper)
- Learning value: understand the mechanics of NAT, routing, and
  source/dest check
- Easier to delete/recreate in destroy cycles

**Traded away:**

- Single point of failure (one instance, one AZ)
- Lower max throughput (~5 Gbps vs NAT Gateway's 100 Gbps)
- Manual patching (no managed service)
- No automatic failover

**Mitigations:**

- Not a production environment — no SLA obligations
- Cluster is ephemeral; NAT instance recreated on every apply
- Using S3 VPC endpoint so ECR image layer pulls bypass NAT entirely
- Source/dest check disabled on the ENI (required for NAT forwarding)

## Alternatives considered

1. **NAT Gateway:** correct production choice; too expensive here.
2. **Fck-nat / HA NAT instance:** community AMIs with built-in failover.
   Adds complexity unnecessary for a learning lab. Worth revisiting if
   this project grows.
3. **Public subnets only:** would eliminate NAT entirely but exposes
   workloads directly — unacceptable for a platform that demonstrates
   enterprise patterns.

## Follow-ups

- If this project runs 24/7 long-term, migrate to NAT Gateway
- If multi-AZ resilience is added, switch to fck-nat HA pattern
- Document IP forwarding user-data in operations runbook
