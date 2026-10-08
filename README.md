# Azure SQL Managed Instance Operations MVP

Executable phase-1 operations toolkit for **one allowlisted existing Azure SQL Managed Instance (MI)**. The chosen runtime is local GitHub Copilot CLI, public/open-source skill definitions, PowerShell 7, and Azure CLI/ARM.

> **Validation status:** The PowerShell safety, configuration, persistence, and redaction logic is implemented and locally tested. Azure commands have not been executed against a tenant or MI by this repository. Run preflight and approved non-production validation before operational use.

Azure SRE Agent is not an MVP dependency or prerequisite. It is only a possible future migration target.

## Implemented phase-1 capabilities

- Validate local configuration, Azure CLI login, active subscription, provider registration, and observable MI read access.
- Show MI state and conservative local lifecycle eligibility.
- Submit controlled `start` and `stop` operations through `az sql mi --no-wait`.
- Default every mutation to dry-run; require `-Apply` plus the exact allowlisted resource ID.
- Persist local operation state and later poll the MI until the desired state is independently observed.
- Inspect an Azure-native start/stop schedule, create a review plan, and explicitly delete an existing schedule.
- Collect read-only Azure Resource Manager, Activity Log, Resource Health, and Azure Monitor evidence.
- Generate a redacted Microsoft Support case draft/evidence summary.
- Record redacted local JSONL audit events.
- Expose SQL DMV/Query Store diagnostics as a disabled optional adapter boundary.

Phase 1 does **not** automatically resize, create/update automatic stop schedules, execute SQL diagnostics, remediate incidents, or submit Microsoft Support cases.

## Cost statement

The skill definitions and repository code are free/open source. The complete solution is **not universally zero-cost**: GitHub Copilot/model access, Azure SQL MI and other Azure resources, Azure Monitor/Log Analytics retention or queries, storage, networking, and Microsoft Support plans can incur charges. Confirm licensing, subscription pricing, quotas, and support entitlement for your environment.

## Prerequisites

- PowerShell 7.4 or later.
- Azure CLI 2.89 or later.
- `az login` access to the configured subscription.
- Azure read permissions for status/evidence and separate lifecycle permissions for approved start/stop.
- An existing MI that is eligible for the requested Azure feature.

Azure RBAC does not grant SQL DMV or Query Store access. SQL diagnostics require a separate least-privilege SQL identity and adapter; `sysadmin` is neither required nor recommended.

## Quickstart

```powershell
pwsh .\bootstrap.ps1
# Edit resource.id and resource.allowedResourceIds to the same existing MI resource ID.

pwsh .\miops.ps1 preflight
pwsh .\miops.ps1 status
pwsh .\miops.ps1 evidence -LookbackHours 24
```

Start and stop are dry-run by default:

```powershell
pwsh .\miops.ps1 start

$mi = '/subscriptions/<subscription>/resourceGroups/<rg>/providers/Microsoft.Sql/managedInstances/<mi>'
pwsh .\miops.ps1 start -Apply -ApproveResourceId $mi
pwsh .\miops.ps1 operation-poll -OperationId '<local-operation-id>'
```

Schedule and escalation examples:

```powershell
pwsh .\miops.ps1 schedule-show
pwsh .\miops.ps1 schedule-plan
pwsh .\miops.ps1 schedule-delete
# Applying deletion requires the same -Apply -ApproveResourceId safeguard.

pwsh .\miops.ps1 support-draft `
  -EvidencePath '.miops\evidence\evidence-<timestamp>.json' `
  -Title 'MI connectivity degradation' `
  -Impact 'Applications experienced elevated connection failures.'
```

Use another config with `-ConfigPath`. Local configuration and runtime state are ignored by Git:

```powershell
pwsh .\miops.ps1 status -ConfigPath 'C:\secure-config\miops.json'
```

## Command reference

| Command | Boundary |
|---|---|
| `preflight` | Read-only checks; cannot prove all write permissions or feature eligibility |
| `status` | Read-only MI state |
| `start`, `stop` | Dry-run unless exact explicit approval is provided |
| `operation-poll` | Read-only reconciliation of a persisted operation |
| `schedule-show` | Read-only inspection |
| `schedule-plan` | Local plan only; does not enable automation |
| `schedule-delete` | Dry-run by default; applying only disables an existing Azure schedule |
| `evidence` | Read-only Azure evidence bundle |
| `support-draft` | Local redacted draft only; no API submission |
| `sql-adapter-status` | Reports optional adapter boundary; no SQL query execution |

## Local data

By default `.miops/` contains:

- `operations/*.json`: durable local lifecycle records.
- `evidence/*.json`: redacted Azure evidence bundles.
- `support/*.json`: redacted Support case drafts.
- `audit.jsonl`: append-only local audit events.

Local files are not an immutable enterprise audit sink. Protect the workstation and move records to an approved backend before production use.

## Tests

```powershell
pwsh -NoProfile -File .\tests\run-tests.ps1
```

Tests do not require Azure. They cover configuration validation, exact allowlisting, dry-run/approval safeguards, operation persistence, and redaction.

## Documentation

- [Architecture](docs/architecture.md)
- [MVP scope and limitations](docs/mvp-scope.md)
- [Security and governance](docs/security-and-governance.md)
- [Platform decision](docs/decision-log/0001-platform-strategy.md)
- [Optional SQL diagnostics adapter contract](adapters/sql/README.md)

The four [`skills/`](skills) definitions give Copilot CLI exact command guidance while preserving read-only and mutating boundaries.
