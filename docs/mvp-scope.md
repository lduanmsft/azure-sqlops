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
- User database inventory with normalized state and restore metadata.
- ARM backup health checks for database state, STR, LTR, LTR record age, deleted database evidence, and restore boundaries.
- Exact-database LTR policy show, current-versus-requested plan, guarded synchronous apply, and independent read-back verification.
- Strict dimension-specific retention normalization, all-disabled prevention, no-weakening default, and stronger reduction confirmation.
- Optional disabled-by-default fixed SQL backup-history adapter.
- Independent exact restore-target configuration.
- Same-instance and cross-instance PITR plan/apply to a new database.
- Strict UTC/name/boundary/destination checks, dual approvals, and exact field-bound confirmation.
- Restore operation persistence and destination database polling.
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
- Arbitrary SQL DMV, Query Store, or T-SQL collection beyond the fixed backup-history template.
- SQL remediation, T-SQL execution, session termination, or configuration changes.
- Microsoft Support REST API submission.
- Distributed locks, multi-host state, immutable audit export, or hosted availability.
- Tenant-specific permission provisioning.
- Deleted-database PITR submission and LTR restore submission. Deleted database evidence is read-only in this scope.
- LTR policy deletion, clearing all dimensions, or LTR backup deletion.

## Lifecycle safety

`start`, `stop`, and `schedule-delete` are dry-run unless both conditions are present:

1. `-Apply`
2. `-ApproveResourceId` exactly equals the configured allowlisted resource ID

Before lifecycle submission, the tool reads current MI state and applies conservative local eligibility rules. Azure remains authoritative and may reject operations due to configuration, platform limitations, locks, ongoing operations, maintenance, policy, or permissions.

Start operations can be long-running. The tool persists intent before submission, records the Azure response when available, and requires later polling. A submitted operation is not a verified success.

Restore is plan-only unless all of these are present:

1. Source MI is exactly source-allowlisted.
2. Target MI is independently and exactly target-allowlisted.
3. `-ApproveSourceResourceId` and `-ApproveTargetResourceId` exactly match.
4. Typed phrase exactly binds source database, target MI/database, and strict UTC timestamp.

The tool persists the operation before calling `az sql midb restore --no-wait`. `Submitted` means accepted only. `Verified` requires later polling to observe the destination database `Online`.

LTR apply is plan-only unless `-Apply`, exact `-ApproveResourceId`, and a full policy-bound typed confirmation are present. Retention weakening additionally requires `-AllowRetentionReduction` and a phrase beginning with `REDUCE LTR`. The operation is persisted before `az sql midb ltr-policy set`, and `Verified` requires an independent exact normalized read-back. CLI exit 0 is never sufficient.

## Evidence and recommendations

The evidence bundle is read-only and bounded to 1-168 hours. It records unavailable sources rather than inventing results. Capacity interpretation is guided by the skill but remains a human/Copilot analysis of available evidence; no resize action exists.

Azure Monitor metric names vary by resource and configuration. Operators should adjust the configured metric list after inspecting what Azure advertises.

## SQL-engine diagnostics

SQL backup history is optional and disabled. The implemented adapter uses `sqlcmd -G`, one fixed reviewed read-only query, timeout/row limits, and the minimum permissions required; `sysadmin` is not a prerequisite. Missing private network reachability, tooling, authentication, or permission is an evidence gap.

ARM remains the durable evidence source and does not expose every individual STR full/differential/log record. SQL `msdb` history is recent transparency only.

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
- Restore state transitions preserve Submitted/InProgress/Verified/Failed semantics.
- LTR parsing, limits, all-disabled rejection, no-weakening, reduction approval, fixed arguments, persistence, redaction, and read-back mismatch behavior.
- sensitive keys and bearer tokens are redacted.

Requires tenant/MI validation:

- Login and provider results in the target tenant.
- MI read and lifecycle permissions.
- Stop/start eligibility for the chosen MI.
- Azure CLI response shape and lifecycle timing.
- Schedule availability.
- Resource Health, Activity Log, and metric access/retention.
- Any future SQL or Support API adapter.
- Actual tenant PITR behavior, including cross-subscription type, primary-region, BYOK, service endpoint policy, capacity, and permission constraints.
