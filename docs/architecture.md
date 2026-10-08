# Architecture

> **Status:** The local PowerShell runtime, safeguards, state, audit, evidence collection, and support drafting are implemented and locally tested. Azure tenant/MI behavior remains unvalidated.

## Chosen phase-1 architecture

```mermaid
flowchart LR
    Operator[Operator] --> Copilot[Local GitHub Copilot CLI]
    Copilot --> Skills[Public SKILL.md guidance]
    Skills --> Script[miops.ps1]
    Script --> Module[MiOps PowerShell module]
    Module --> Policy[Config, allowlist, dry-run, exact approval]
    Module --> Az[Azure CLI]
    Az --> ARM[Azure SQL MI and ARM]
    Az --> Monitor[Monitor, Activity Log, Resource Health]
    Module --> State[(Local .miops state)]
    Module --> Audit[(Redacted audit.jsonl)]
    Module --> Draft[Support draft]
    SQL[Optional SQL adapter] -. not implemented .-> Module
```

The MVP is intentionally a local, inspectable tool rather than a hosted service. Copilot CLI selects and explains operations; deterministic PowerShell enforces the safety boundary and invokes only fixed Azure CLI command shapes.

Azure SRE Agent is not shown in the runtime because it is not required. A future migration may map these skills and safeguards to it after capability, governance, availability, and cost validation.

## Repository components

| Component | Responsibility | Status |
|---|---|---|
| `miops.ps1` | Stable CLI command dispatcher | Implemented, locally tested |
| `src/MiOps.psm1` | Config, policy, Azure adapters, state, audit, evidence, support draft | Implemented, locally tested without Azure |
| `config/miops.example.json` | Checked-in schema/example for one MI | Implemented |
| `config/miops.local.json` | Operator-owned local configuration | Ignored |
| `.miops/operations` | Durable local operation records | Implemented |
| `.miops/audit.jsonl` | Redacted local audit log | Implemented |
| SQL adapter | Separate least-privilege DMV/Query Store integration | Interface only |
| Support API submission | Entitlement-aware ticket creation | Not implemented |

## Lifecycle flow

```mermaid
sequenceDiagram
    actor O as Operator
    participant C as Copilot/CLI
    participant P as PowerShell policy
    participant S as Local state
    participant A as Azure CLI/ARM

    O->>C: start or stop
    C->>P: fixed command and config
    P->>A: read MI status
    A-->>P: state/configuration
    P->>P: allowlist and conservative eligibility
    alt no -Apply or exact resource approval
        P->>S: persist DryRun record
        P-->>O: no mutation executed
    else explicitly approved
        P->>S: persist Ready/Submitting
        P->>A: az sql mi start|stop --no-wait
        A-->>P: accepted response when available
        P->>S: persist Submitted
        O->>C: operation-poll
        C->>A: az sql mi show
        A-->>C: observed state
        C->>S: persist InProgress/Verified/Failed
    end
```

The local GUID is always captured. An Azure operation identifier is also stored if Azure CLI returns one. Because `az sql mi ... --no-wait` may return no body, later polling uses the authoritative resource state. API acceptance is never labeled verified completion.

## Schedule boundary

Azure CLI exposes `az sql mi start-stop-schedule`. Phase 1:

- Inspects the default schedule.
- Produces a local review plan.
- Can explicitly delete an existing schedule, guarded like other mutations.

It does not create or update schedules because that would enable automatic stop, which is outside this phase.

## Evidence architecture

`evidence` collects, where available:

- Current MI ARM properties.
- Activity Log for a bounded window.
- Current Resource Health.
- Configured Azure Monitor metrics that are advertised by the resource.

Unavailable permissions, metrics, providers, or features become `evidenceGaps`; no synthetic data is substituted. The bundle states that SQL evidence is absent.

## SQL diagnostics boundary

Azure RBAC and SQL data-plane authorization are independent. The interface requires a future adapter to:

- Authenticate with a separate least-privilege SQL identity.
- Execute only reviewed, parameterized, read-only queries.
- Apply timeout, row limit, and redaction.
- Avoid requiring `sysadmin`.

No DMV or Query Store data is generated, inferred, or faked in phase 1.

## Support escalation boundary

The implemented command produces a local redacted case draft from an evidence bundle. REST submission is disabled and absent. A future adapter must prove support-plan entitlement, provider/API readiness, authorization, duplicate handling, exact payload approval, and verified ticket creation.

## Cost and runtime ownership

The repository and public skill definitions may be used as open-source code, but runtime costs remain environment-specific. Copilot/model access, Azure resources, Azure Monitor/Log Analytics, storage/networking, and Microsoft Support can incur charges. The operator owns workstation security, Azure identity, state backup, audit export, and operational validation.

## Reliability limitations

Local JSON files provide restart persistence on one workstation, not distributed coordination or high availability. Phase 1 does not implement leases across hosts, immutable audit storage, background polling, or scheduler execution. Only one operator/process should mutate a given MI at a time until a shared state backend is added.
