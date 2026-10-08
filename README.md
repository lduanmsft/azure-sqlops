# Azure SQL Managed Instance Operations Agent

Design workspace for an Azure SQL Managed Instance (MI) operations agent MVP.

> **Status:** Proposed design only. The repository currently contains architecture, governance, and skill specifications. It does not contain a deployed agent, production automation, or tenant-validated capabilities.

## MVP outcome

The MVP assists operators with controlled operations for **existing** Azure SQL Managed Instances:

- Query MI state and initiate start or stop operations through Azure CLI/ARM.
- Run approved start/stop schedules with durable operation tracking.
- Collect read-only Azure and SQL evidence for automated troubleshooting.
- Produce evidence-based capacity and resize recommendations without automatically resizing.
- Draft Azure Support requests and create them only after explicit authorization and prerequisite checks.

The MVP is not a general autonomous database administrator. It does not provision or delete instances, apply SQL changes, automatically resize compute/storage, or make unapproved support or lifecycle changes.

## Important constraints

- Azure SQL MCP does not currently expose MI lifecycle management. Lifecycle actions therefore use `az sql mi` and/or Azure Resource Manager (ARM) APIs.
- Stop/start is available only for eligible instances and configurations. Eligibility must be checked at runtime; a requested action must not be assumed to be supported.
- Start and resize operations are long-running. The control plane must persist the Azure operation identifier and reconcile operation state across process restarts.
- Azure RBAC permissions do not grant access to SQL dynamic management views (DMVs). SQL troubleshooting requires separate database authentication and least-privilege SQL permissions.
- Azure Support API access depends on an eligible support plan, API entitlement, provider registration, and appropriate authorization. The agent must check prerequisites before offering ticket creation.
- Every mutable action is constrained by resource allowlists, least privilege, explicit approvals, audit records, deduplication, redaction, budgets, and post-action verification.

## Workspace map

| Path | Purpose | Status |
|---|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Components, flows, state model, and deployment paths | Proposed |
| [`docs/mvp-scope.md`](docs/mvp-scope.md) | MVP boundaries, scenarios, and acceptance criteria | Proposed |
| [`docs/security-and-governance.md`](docs/security-and-governance.md) | Authorization, approvals, audit, data handling, and safety controls | Proposed |
| [`docs/decision-log/0001-platform-strategy.md`](docs/decision-log/0001-platform-strategy.md) | Self-hosted `microsoft/azure-skills` versus Azure SRE Agent strategy | Proposed decision |
| [`skills/mi-manage/SKILL.md`](skills/mi-manage/SKILL.md) | Status, start, stop, and scheduling contract | Proposed skill |
| [`skills/mi-capacity/SKILL.md`](skills/mi-capacity/SKILL.md) | Capacity evidence and resize recommendations | Proposed skill |
| [`skills/mi-troubleshoot/SKILL.md`](skills/mi-troubleshoot/SKILL.md) | Read-only incident investigation | Proposed skill |
| [`skills/mi-escalate/SKILL.md`](skills/mi-escalate/SKILL.md) | Support request drafting and authorized creation | Proposed skill |

## Platform paths

The design keeps domain skills portable between two execution paths:

1. **Self-hosted agent using free `microsoft/azure-skills` building blocks** for maximum control over hosting, identity, state, approvals, and integrations.
2. **Azure SRE Agent** for a managed reliability-agent experience, subject to product availability, supported integrations, governance fit, and tenant validation.

The proposed MVP starts with a self-hosted reference implementation while preserving skill boundaries that can be adapted to Azure SRE Agent. See [decision 0001](docs/decision-log/0001-platform-strategy.md).

## Capability legend

- **Proposed:** documented design; not implemented in this repository.
- **Implemented:** code exists and has repository-level tests.
- **Tenant validated:** exercised with approved identities and representative resources in a real Azure tenant.

All current capabilities are **Proposed**. Nothing in this repository should be interpreted as tenant validation or operational readiness.
