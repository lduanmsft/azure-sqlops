---
name: mi-manage
description: Safely inspect and coordinate Azure SQL Managed Instance status, start, stop, and approved schedules.
metadata:
  status: proposed
---

# Skill: MI Manage

> **Status:** Proposed specification. Not implemented or tenant validated.

## Purpose

Read the state of an existing Azure SQL Managed Instance and safely coordinate approved start, stop, and start/stop schedule operations.

## Allowed outcomes

- Return current MI status and relevant operation context.
- Explain why start/stop is not currently actionable.
- Produce an approval request for a lifecycle action.
- Submit an approved `start` or `stop` using a typed `az sql mi`/ARM adapter.
- Create, update, pause, or remove an approved schedule through the scheduler adapter.
- Reconcile and verify a previously submitted operation.

## Prohibited outcomes

- Provision, delete, resize, reconfigure, restore, or fail over MI.
- Execute arbitrary Azure CLI or shell commands.
- Act on a resource outside the allowlist.
- Infer lifecycle eligibility without a current Azure check.
- Treat API acceptance as successful completion.
- Retry an ambiguous submission without reconciliation.

## Required inputs

- Authenticated caller and roles.
- Canonical MI resource ID or resolvable allowlisted alias.
- Requested intent: `status`, `start`, `stop`, or `schedule`.
- For schedules: action, timezone, recurrence, validity window, owner, and exception policy.
- Correlation/request ID.

## Preconditions for mutable actions

1. Resolve the exact Azure resource ID.
2. Verify allowlist membership and caller authorization.
3. Read current resource and provisioning/lifecycle state.
4. Check current stop/start eligibility and unsupported conditions.
5. Check maintenance, locks, policy, operation conflicts, and budgets.
6. Generate an exact proposal including expected impact.
7. Obtain explicit approval or validate an active pre-approved schedule.
8. Persist request, approval, and idempotency key before submission.

## Tool contract

Use only versioned operations such as:

- `get_managed_instance(resource_id)`
- `get_lifecycle_eligibility(resource_id, action)`
- `start_managed_instance(resource_id, idempotency_key)`
- `stop_managed_instance(resource_id, idempotency_key)`
- `get_azure_operation(operation_reference)`
- `put_schedule(schedule_document)`

The adapter may implement these with `az sql mi` or ARM. Azure SQL MCP is not the lifecycle mechanism because it does not currently expose MI start/stop.

## Durable workflow

1. Persist `Proposed`.
2. Persist policy result and approval.
3. Acquire per-resource lease.
4. Persist `Ready` and idempotency key.
5. Submit once and persist Azure request/operation reference immediately.
6. Reconcile until terminal or bounded `Unknown`.
7. Read the MI independently and compare with desired state.
8. Persist `Verified` or explicit failure.
9. Release lease and report evidence.

Start operations may be long-running; process or chat lifetime must not bound tracking.

## Schedule rules

- Never use server-local time; store timezone explicitly.
- Define behavior for daylight-saving transitions.
- Do not run outside the allowed execution window.
- Do not automatically catch up an old missed stop/start after the window.
- Recheck all policy and eligibility conditions at execution time.
- Apply per-resource action frequency budgets.
- Expire schedules and require ownership review.

## Output

Return a structured result with:

- Resource ID and display name.
- Requested action and resolved current state.
- Eligibility result and source timestamp.
- Policy/approval result.
- Operation state and Azure reference when submitted.
- Verification state and timestamp.
- Warnings, denial reasons, or next required authorization.

Use the words **proposed**, **submitted**, **in progress**, **verified**, **failed**, and **unknown** precisely.
