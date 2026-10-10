# MVP Scope

> **Status:** Repository logic is implemented and locally validated. No Azure tenant, support entitlement, or Managed Instance lifecycle operation has been validated by this repository.

## Runtime decision

Phase 1 uses local GitHub Copilot CLI, project-scoped skill definitions in `.github/skills`, PowerShell 7, and Azure CLI/ARM. Azure SRE Agent is neither required nor included.

## Implemented

- One configured MI and an exact canonical resource allowlist.
- Interactive tenant login, enabled subscription selection, MI discovery, and ignored local allowlist generation.
- Interactive supported-operations menu with action-and-MI-bound typed lifecycle confirmation.
- JSON config validation and ignored local config.
- Azure CLI/login/subscription/provider/read-access preflight where observable.
- MI status/configuration read.
- Conservative lifecycle eligibility checks.
- Start/stop dry-run and explicit exact-resource confirmation.
- Non-blocking lifecycle submission and durable local operation records.
- Later resource-state polling and verified desired-state detection.
- Start/stop schedule inspection and guarded deletion.
- Plan-only schedule guidance; no creation/update.
- Azure Activity Log, Resource Health, ARM, and advertised metric evidence.
- Explicit evidence gaps.
- Redacted local audit, evidence, and Support draft files.
- Disabled optional SQL diagnostic interface.
- Local focused tests.

## Not implemented

- Automatic stop or background schedule execution.
- Azure-native schedule creation/update.
- Automatic resize or resize submission.
- SQL DMV or Query Store collection.
- SQL remediation, T-SQL execution, session termination, or configuration changes.
- Microsoft Support REST API submission.
- Distributed locks, multi-host state, immutable audit export, or hosted availability.
- Tenant-specific permission provisioning.

## Lifecycle safety

`start`, `stop`, and `schedule-delete` are dry-run unless both conditions are present:

1. `-Apply`
2. `-ApproveResourceId` exactly equals the configured allowlisted resource ID

Before lifecycle submission, the tool reads current MI state and applies conservative local eligibility rules. Azure remains authoritative and may reject operations due to configuration, platform limitations, locks, ongoing operations, maintenance, policy, or permissions.

Start operations can be long-running. The tool persists intent before submission, records the Azure response when available, and requires later polling. A submitted operation is not a verified success.

## Evidence and recommendations

The evidence bundle is read-only and bounded to 1-168 hours. It records unavailable sources rather than inventing results. Capacity interpretation is guided by the skill but remains a human/Copilot analysis of available evidence; no resize action exists.

Azure Monitor metric names vary by resource and configuration. Operators should adjust the configured metric list after inspecting what Azure advertises.

## SQL-engine diagnostics

SQL diagnostics are optional and disabled. A future adapter must use a separate SQL principal because Azure RBAC does not grant DMV or Query Store access. It should use reviewed read-only queries and the minimum permissions required; `sysadmin` must not be a prerequisite.

## Support escalation

The MVP creates a redacted draft only. It never implies that all Microsoft Support plans permit REST API creation. A future submission adapter must check plan/tenant entitlement, provider registration, authorization, severity rules, duplicate requests, and exact payload approval.

## Cost boundary

Repository code and public skills can be free/open source. Copilot/model access, MI compute/storage, Azure monitoring, data retention, network use, and Microsoft Support can incur costs. Pricing and entitlement are outside repository validation.

## Acceptance criteria

Locally validated:

- Tenant/subscription identifier and numbered-selection validation.
- Safe local config generation and cancellation.
- Typed lifecycle confirmation bound to action and MI name.
- Invalid or non-allowlisted configuration is rejected.
- Allowlisting is exact and case-insensitive.
- Mutations default to dry-run.
- Wrong or absent explicit confirmation is rejected.
- Operation state survives process exit through JSON persistence.
- sensitive keys and bearer tokens are redacted.

Requires tenant/MI validation:

- Login and provider results in the target tenant.
- MI read and lifecycle permissions.
- Stop/start eligibility for the chosen MI.
- Azure CLI response shape and lifecycle timing.
- Schedule availability.
- Resource Health, Activity Log, and metric access/retention.
- Any future SQL or Support API adapter.
