# Security and Governance

> **Status:** Proposed controls. They are requirements for an implementation, not evidence that this repository or any tenant currently enforces them.

## Security principles

1. **Least privilege:** grant only the control-plane, data-plane, and support permissions required for each bounded capability.
2. **Separate authority:** reading evidence, changing lifecycle state, querying SQL, and creating support requests should use separable identities.
3. **Explicit intent:** consequential actions require an exact, reviewable proposal and valid authorization.
4. **Defense in depth:** Azure RBAC, SQL permissions, application allowlists, policy, approvals, budgets, and audit all apply.
5. **No silent success:** unknown, partial, denied, and failed outcomes are visible.
6. **Minimize data:** collect and retain only evidence required for the operational purpose.

## Authorization model

### Azure control plane

Define custom roles where practical. Scope lifecycle permissions to approved MI resources or tightly controlled resource groups. The application must still enforce an explicit resource allowlist.

Azure RBAC does not grant SQL permissions. A principal that can read or manage an MI resource cannot automatically query databases or DMVs.

### SQL data plane

Use a dedicated read-only diagnostic identity. Grant only access required for the approved catalog views and DMVs. Avoid broad roles such as `db_owner` or `sysadmin`. Document any server-level permission required by a DMV and its exposure risk.

The SQL collector must reject arbitrary query generation. It executes versioned, reviewed query templates with parameter validation, row limits, timeouts, and result redaction.

### Azure Support

Support request creation requires appropriate Azure authorization and tenant/subscription entitlement. The implementation must verify provider/API prerequisites, support plan eligibility, and caller authority. A failure to establish entitlement must degrade to a draft, not a success-shaped ticket result.

## Resource allowlists

Allowlist entries should use canonical Azure resource IDs and may constrain:

- Tenant and management group.
- Subscription and resource group.
- MI resource ID.
- Environment classification.
- Permitted actions.
- Schedule windows and timezone.
- Required approval role.
- Maximum action frequency.

Aliases and display names are resolved to resource IDs before policy evaluation. A resource mismatch or ambiguous resolution is denied.

## Approval controls

### Interactive lifecycle actions

Approval is bound to:

- Request and correlation ID.
- Canonical resource ID.
- Action (`start` or `stop`).
- Material parameters.
- Evidence snapshot or state precondition.
- Approver identity and role.
- Creation and expiration time.

Changing the target, action, or material parameters invalidates the approval.

### Scheduled actions

A schedule is a pre-authorization document, not a blanket permission. It includes action, resource, timezone, recurrence, active dates, exception calendar, execution window, budget, owner, and expiration. Each run still reevaluates resource state, eligibility, policy, and conflicts.

### Support requests

Ticket creation requires per-ticket approval after the final redacted payload is shown. Authorization to troubleshoot or draft does not authorize ticket creation. Material edits after approval require renewed approval.

## Audit

Audit events should be append-only and exported to a protected sink. Record:

- Authenticated actor and workload identity.
- Trigger source.
- Requested and resolved resource.
- Evidence sources and collection timestamps.
- Policy input, version, outcome, and reason codes.
- Approval artifact.
- Idempotency key.
- Tool/API operation and sanitized parameters.
- Azure request and operation identifiers.
- State transitions, retries, and terminal result.
- Verification result.
- Redaction actions and support payload hash.

Do not log credentials, access tokens, connection strings, full query text, sensitive result rows, or unredacted support attachments.

## Deduplication and concurrency

- Derive an idempotency key from action, canonical resource ID, schedule occurrence or request ID, and material parameters.
- Store the key before external execution.
- Use a per-resource lease or optimistic concurrency record.
- Return the existing operation when an equivalent request is already active or completed within the deduplication window.
- Reject incompatible concurrent operations.
- Reconcile ambiguous submissions before retrying.

## Redaction and data handling

Classify evidence fields before collection. Redact or omit:

- Secrets, tokens, credentials, and connection strings.
- Customer data and query result values.
- Personal information.
- Query text and object names when not required for the purpose.
- Internal hostnames, IP addresses, and identifiers unless operationally necessary and approved.

Support drafts use structured summaries rather than raw dumps. The operator previews all content that will leave the operational boundary.

Define retention separately for operation journals, audit events, diagnostic evidence, chat transcripts, and support artifacts. Evidence expiration must not delete the audit proof that an action occurred.

## Budgets and rate controls

Policy should support:

- Maximum mutable operations per resource per day.
- Minimum interval between lifecycle changes.
- Maximum concurrent operations globally and per subscription.
- Diagnostic query runtime and row limits.
- Azure API retry and polling budgets.
- Support request count and severity limits.
- Token/model spending limits.
- Evidence storage and retention limits.

Budget exhaustion is an explicit denied or deferred outcome.

## Verification and failure handling

An accepted API request is not completion. Verify through an independent resource read after Azure reports a terminal operation. Record observed state and timestamp.

If Azure operation status is unavailable:

1. Mark the operation `Unknown`, not failed or succeeded.
2. Reconcile using request IDs, activity records, and current resource state.
3. Avoid resubmission until duplicate risk is resolved.
4. Escalate to an operator after a bounded deadline.

## Threats and required mitigations

| Threat | Required mitigation |
|---|---|
| Prompt injection requests arbitrary commands | Typed tool catalog; no general shell; policy enforcement outside the model |
| Wrong-resource action | Canonical resource IDs, allowlist, confirmation showing full target |
| Replay or duplicate scheduler delivery | Durable idempotency key and operation journal |
| Approval reuse | Bind approval to exact action, resource, parameters, and expiration |
| Privilege aggregation | Separate identities and role assignments |
| Sensitive evidence leakage | Data minimization, template queries, redaction, preview |
| False success after asynchronous submission | Durable reconciliation and independent verification |
| Cost or action runaway | Per-resource/global budgets and circuit breakers |
| Unsupported MI lifecycle request | Runtime eligibility check and explicit denial |
| Fabricated support creation | Persist and return verified support request identifier only |

## Governance lifecycle

- Version policy, query templates, tool schemas, and skill definitions.
- Require review for new mutable tools or expanded permissions.
- Test policy changes against allow/deny regression cases.
- Periodically review role assignments, allowlists, schedules, and dormant identities.
- Reapprove schedules after ownership, target, or policy changes.
- Conduct incident review for duplicate, unauthorized, unknown, or incorrectly verified actions.

## Production readiness evidence

An implementation should not be labeled production-ready until it has:

- Documented permission inventories for every identity.
- Completed threat modeling and security review.
- Demonstrated denial outside allowlists.
- Demonstrated approval expiration and binding.
- Demonstrated restart recovery and duplicate suppression.
- Demonstrated redaction with representative evidence.
- Exercised rollback/containment procedures.
- Passed approved non-production tenant tests.

Tenant-specific testing must be reported as such and must not be implied by this design repository.
