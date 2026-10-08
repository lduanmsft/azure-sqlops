# 0001: Platform Strategy for the MI Operations Agent

- **Status:** Proposed
- **Date:** 2026-10-08
- **Decision owners:** To be assigned
- **Tenant validation:** Not performed

## Context

The MVP needs controlled MI lifecycle operations, durable tracking for long-running work, read-only Azure and SQL evidence, capacity recommendations, support escalation, approvals, audit, and policy enforcement.

Two platform paths are relevant:

1. A self-hosted agent assembled with free, open-source `microsoft/azure-skills` capabilities and organization-owned services.
2. Azure SRE Agent as a managed reliability-agent platform.

The domain design should not depend unnecessarily on either execution environment.

## Decision

Build the first reference implementation as a **self-hosted, portable agent using `microsoft/azure-skills` patterns and reusable Azure skills**, while maintaining adapters and contracts that can later be mapped to **Azure SRE Agent**.

This is a proposed strategy, not an implemented choice. Before production adoption, run a tenant-specific proof of capability for both paths using the same acceptance criteria.

## Rationale

The self-hosted path provides direct control over:

- Exact Azure CLI/ARM operations required for MI lifecycle management.
- Durable operation storage and reconciliation.
- Approval semantics and schedule authorization.
- Separate Azure, SQL, and Support identities.
- Resource allowlists, custom policy, budgets, and audit destinations.
- Evidence redaction and retention.

It also makes platform-neutral skill contracts concrete before evaluating managed-platform mappings.

Azure SRE Agent may reduce hosting and orchestration ownership and may provide integrated SRE workflows. However, the MVP cannot assume that every required control or MI-specific operation is available. Validation must cover lifecycle actions, durable long-running operation behavior, SQL evidence access, approval binding, support request creation, audit export, data boundaries, and regional/tenant availability.

## Comparison

| Dimension | Self-hosted with `microsoft/azure-skills` | Azure SRE Agent |
|---|---|---|
| Software/license entry cost | Free skills; hosting and operations still incur cost | Product/service pricing and consumption require validation |
| MI lifecycle integration | Direct adapter using `az sql mi`/ARM | Must validate supported actions or custom integration path |
| Azure SQL MCP dependency | Optional; not sufficient for MI lifecycle | Must not assume MCP exposes start/stop |
| Durable operation tracking | Organization designs and operates it | Validate native durability and extension points |
| Scheduling | Organization-owned scheduler and state | Validate scheduling and missed-run semantics |
| Approval model | Fully customizable | Validate exact binding, expiration, and separation of duties |
| SQL DMV access | Separate SQL identity and template-query service | Still requires SQL data-plane permissions and connector support |
| Support API | Custom prerequisite check and typed adapter | Validate native action or custom tool support |
| Governance | Maximum customization; maximum ownership | Potentially integrated; validate policy and audit requirements |
| Availability/operations | Organization owns HA, patching, scaling, and incident response | Managed platform may reduce ownership |
| Portability | High if contracts remain platform-neutral | Risk of platform coupling |
| Time to prototype | More engineering work | Potentially faster if all required capabilities are supported |

## Required proof-of-capability matrix

Both paths must demonstrate:

1. Resolve and deny non-allowlisted resources.
2. Read MI state.
3. Detect unsupported stop/start requests.
4. Submit an approved lifecycle action exactly once.
5. Recover operation tracking after executor restart.
6. Prevent conflicting per-resource operations.
7. Use separate Azure RBAC and SQL permissions.
8. Run only reviewed read-only SQL templates.
9. Generate a capacity recommendation without resizing.
10. Draft a redacted support request.
11. Check support entitlement and create only after exact approval.
12. Export complete, secret-free audit evidence.
13. Enforce action, API, evidence, and model budgets.

## Consequences

### Positive

- Safety controls are designed explicitly rather than inferred from a platform.
- MI lifecycle gaps can be handled directly through Azure CLI/ARM.
- Skills can be reused or adapted as platform capabilities evolve.
- The team obtains a common acceptance suite for evaluating Azure SRE Agent.

### Negative

- The team initially owns hosting, identity integration, durable state, scheduler, observability, upgrades, and on-call responsibilities.
- Custom integrations increase engineering and maintenance cost.
- Portability requires discipline around schemas and adapters.

## Revisit triggers

Reevaluate this decision when:

- Azure SRE Agent demonstrates the full proof-of-capability matrix.
- Azure SQL MCP adds supported MI lifecycle operations with required control semantics.
- Self-hosted operational cost exceeds managed-platform benefit.
- Governance or data-boundary requirements favor one platform.
- Product availability, pricing, or support changes materially.

## Follow-up decisions

- Durable state technology and deployment topology.
- Identity and custom-role definitions.
- Approval and scheduler user experience.
- SQL diagnostic query catalog and permissions.
- Audit sink and retention.
- Evidence classification/redaction policy.
- Azure Support API integration contract.
