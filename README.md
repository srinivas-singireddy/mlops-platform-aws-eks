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

## What this demonstrates
- Terraform-provisioned AWS infrastructure (VPC, EKS, IAM, S3)
- GitOps delivery via ArgoCD (app-of-apps pattern)
- Observability stack: Prometheus, Grafana, Loki
- Model serving: KServe + vLLM for LLM inference
- CI/CD via GitHub Actions with OIDC federation (no long-lived keys)
- Cost-aware operations: ephemeral cluster pattern, Karpenter autoscaling,
  budget guardrails

## Cost
See [docs/COST.md](docs/COST.md) — typical monthly spend during active
development: €25-40 with disciplined destroy/apply cycles.

## Running it yourself
_Instructions forthcoming as each phase completes._

## Author
Srinivas Singireddy — Solutions Architect, Munich
- LinkedIn: [linkedin.com/in/srinivas-singireddy](...)
- GitHub: [srinivas-singireddy](...)

## Documentation

- [Architecture overview](docs/architecture.md) — high-level system design with diagrams
- [Lessons learned](docs/lessons-learned.md) — 18 issues, decisions, and architectural takeaways from the build
- [Architecture Decision Records](docs/adr/) — the reasoning behind specific choices