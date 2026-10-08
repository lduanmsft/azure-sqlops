# MVP Scope

> **Status:** Proposed scope and acceptance criteria. No scenario is implemented or tenant validated in this repository.

## Objective

Provide a safe operator assistant for a bounded set of Azure SQL Managed Instance operations, diagnostics, capacity decisions, and support escalation. The MVP prioritizes control and evidence over autonomous remediation.

## In scope

### MI status and lifecycle

- Resolve an existing MI only from an allowlisted subscription/resource group/resource ID.
- Read provisioning and lifecycle state.
- Explain whether the current request is actionable.
- Start or stop an eligible MI through `az sql mi` or ARM.
- Execute approved start/stop schedules.
- Track long-running operations durably and verify the terminal resource state.
- Detect duplicate, stale, or conflicting requests.

Stop/start eligibility varies by configuration and current Azure limitations. The agent must perform a current eligibility and state check rather than encode a universal claim of support.

### Read-only troubleshooting

- Gather Azure resource configuration, Activity Log, Resource Health, platform metrics, and alert context.
- Gather approved SQL metadata and DMV evidence when a separate SQL identity has been configured.
- Correlate evidence for a defined time window.
- Identify likely causes, competing hypotheses, confidence, and evidence gaps.
- Recommend operator actions without making SQL, configuration, or data changes.

### Capacity and resize recommendation

- Summarize compute, memory, storage, I/O, and workload evidence available to the configured collectors.
- Distinguish transient spikes from sustained pressure.
- Estimate growth and identify headroom or overprovisioning.
- Recommend a candidate resize direction and target with assumptions, risks, and a verification plan.
- Produce a reviewable recommendation artifact.

The MVP does **not** submit a resize operation.

### Azure Support escalation

- Check whether required support-plan/API prerequisites appear to be present.
- Draft a redacted support request with resource context, impact, timeline, troubleshooting performed, and requested assistance.
- Display the exact payload for review.
- Create a support request only after explicit authorization for that ticket.
- Persist the request identifier and audit evidence.

Support API behavior and entitlement are tenant-specific prerequisites. Drafting can remain available when creation is unavailable.

## Out of scope

- Provisioning, deleting, restoring, failing over, patching, or reconfiguring MI.
- Automatic compute or storage resize.
- Executing T-SQL remediation, killing sessions, changing indexes, or changing database settings.
- Access to arbitrary subscriptions or resources not on the allowlist.
- Autonomous incident declaration or closure.
- Support severity selection beyond policy-approved bounds.
- Uploading raw query text, result sets, credentials, secrets, or unredacted personal/customer data to support.
- Cost guarantees, SLA guarantees, or claims of root cause without sufficient evidence.
- Replacing Azure Service Health, Azure Monitor, a DBA, or Microsoft Support.

## Actors

| Actor | Allowed MVP behavior |
|---|---|
| Viewer | Read status and redacted troubleshooting/capacity results |
| Operator | Request lifecycle actions and prepare schedules |
| Approver | Approve bounded lifecycle actions within policy |
| Support requester | Approve creation of a reviewed support ticket |
| Platform administrator | Configure identities, allowlists, policies, budgets, and integrations |
| Scheduler | Trigger only pre-approved schedules within their validity window |

One person may hold multiple roles, but production policy should support separation of duties for high-impact environments.

## Functional scenarios

### 1. Get status

**Given** an allowlisted MI, **when** an authorized user asks for status, **then** the agent returns observed state, evidence timestamp, relevant pending operation, and data source.

### 2. Start an MI

**Given** an allowlisted, eligible, stopped MI and valid authorization, **when** the user approves start, **then** the agent persists the request before submission, invokes the typed lifecycle operation once, reconciles the long-running operation, and reports independently verified state.

### 3. Stop an MI

**Given** an allowlisted, eligible, running MI and valid authorization, **when** the user approves stop, **then** the agent warns about expected impact, records approval, executes once, tracks completion, and verifies stopped state.

### 4. Scheduled lifecycle action

**Given** a pre-approved schedule with resource, action, timezone, validity window, and budget, **when** a trigger fires, **then** the agent rechecks policy, eligibility, state, and conflicts before executing. Missed or ambiguous windows do not cause an unbounded catch-up action.

### 5. Troubleshoot degraded performance

**Given** a resource and incident window, **when** diagnostics are requested, **then** the agent collects only approved read-only evidence, labels unavailable SQL evidence explicitly, correlates sources, and returns ranked hypotheses without remediation side effects.

### 6. Recommend capacity

**Given** sufficient historical evidence, **when** a capacity review is requested, **then** the agent returns observations, assumptions, confidence, candidate configuration, expected benefit, tradeoffs, cost-data caveats, and post-change measurements. It does not resize.

### 7. Draft and create a support request

**Given** unresolved impact, **when** escalation is requested, **then** the agent drafts a redacted payload. It creates the ticket only after prerequisite checks and explicit authorization of the displayed payload.

## Cross-cutting acceptance criteria

Every mutable workflow must:

- Reject targets outside the allowlist.
- Bind approval to the exact resource, action, parameters, and expiration.
- Persist intent and idempotency key before invoking Azure.
- Record the Azure operation/request reference.
- Prevent duplicate execution.
- Enforce per-resource operation serialization.
- Respect action and spend budgets.
- Produce an audit record without secrets.
- Verify final state independently.
- Report failures and unknown states explicitly.

Every evidence workflow must:

- State source and collection time.
- Distinguish observed facts from inference.
- Mark missing data and permission failures.
- Apply data minimization and redaction.
- Avoid presenting stale evidence as current.
- Avoid claiming tenant validation.

## Non-functional targets for an implementation

These are initial engineering targets, not measured results:

| Area | Proposed target |
|---|---|
| Duplicate side effects | Zero in retry/replay tests |
| Operation recovery | Resume reconciliation after process restart |
| Audit coverage | 100% of policy decisions and mutable action transitions |
| Approval binding | Exact action/resource/parameters with expiration |
| Redaction | Automated rules plus human preview for support payloads |
| Observability | Correlation ID across trigger, policy, executor, Azure, and audit |
| Availability | Defined by chosen hosting path and documented separately |

## Delivery increments

1. Read-only status and policy/evidence envelopes.
2. Durable operation journal and simulated lifecycle executor.
3. Approved start/stop against an eligible non-production MI.
4. Scheduling with budgets and missed-window behavior.
5. Read-only troubleshooting with separate Azure and SQL identities.
6. Capacity recommendation artifact.
7. Support draft, prerequisite checks, and authorized creation.
8. Platform comparison validation and production-readiness review.
