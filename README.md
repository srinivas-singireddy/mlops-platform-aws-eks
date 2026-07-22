# MLOps Platform on AWS EKS

A production-grade reference architecture for running ML workloads on
AWS EKS. Built as a portfolio project to demonstrate modern platform
engineering patterns: infrastructure as code, GitOps delivery,
observability, and cost-aware operations.

> **Status:** 🚧 Under active construction. See [docs/PROGRESS.md](docs/PROGRESS.md).

## Architecture at a glance
_Diagram forthcoming — [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)_

## Key design decisions
See [docs/adr/](docs/adr/) — each decision is documented with context,
alternatives, and trade-offs.

## What this demonstrates — built
- Terraform-provisioned AWS infrastructure (VPC, EKS, IAM, S3), four roots split by lifecycle
- GitOps delivery via ArgoCD (app-of-apps pattern)
- Observability stack: Prometheus, Grafana, Loki, Alertmanager (Grafana Alloy as collector)
- Cost-aware operations: ephemeral cluster pattern, budget guardrails
- Karpenter Spot autoscaling — deployed and validated in a dev/ephemeral EKS environment
  (provision→consolidate cycle, IRSA auto-discovery confirmed)

## Roadmap — designed, not yet live
- CI/CD via GitHub Actions with OIDC federation (keyless AWS auth)
- Model serving: KServe + vLLM for LLM inference on GPU node pools
- munich-rag-compliance running as a tenant workload on this platform

## Cost
See [docs/COST.md](docs/COST.md) — typical monthly spend during active
development: €20–30 with disciplined destroy/apply cycles.

## Running it yourself
_Instructions forthcoming as each phase completes._

## Author
Srinivas Singireddy — Cloud & DevOps / Platform Engineer, Munich
- LinkedIn: [linkedin.com/in/srinivas-singireddy](https://www.linkedin.com/in/srinivas-singireddy/)
- GitHub: [srinivas-singireddy](https://github.com/srinivas-singireddy)

## Documentation

- [Architecture overview](docs/architecture.md) — high-level system design with diagrams
- [Lessons learned](docs/lessons-learned.md) — issues, decisions, and architectural takeaways documented throughout the build
- [Architecture Decision Records](docs/adr/) — the reasoning behind specific choices