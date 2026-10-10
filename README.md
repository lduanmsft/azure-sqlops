# Azure Resource Inventory and SQL Managed Instance Operations

Executable toolkit for read-only Azure resource/database inventory, backup health, controlled point-in-time database restore, and lifecycle operations for explicitly allowlisted existing Azure SQL Managed Instances (MI). The chosen runtime is local GitHub Copilot CLI, public/open-source skill definitions, PowerShell 7, and Azure CLI/ARM.

> **Validation status:** The PowerShell safety, configuration, persistence, and redaction logic is implemented and locally tested. Azure commands have not been executed against a tenant or MI by this repository. Run preflight and approved non-production validation before operational use.

Azure SRE Agent is not an MVP dependency or prerequisite. It is only a possible future migration target.

## Use as project-scoped GitHub Copilot Skills

Clone or pull the repository, enter any directory inside the checkout, and start GitHub Copilot CLI:

```powershell
git clone https://github.com/lduanmsft/azure-sqlops.git
Set-Location .\azure-sqlops
copilot
```

Copilot automatically discovers all five skills from `.github/skills` at the Git repository root, even when it starts in a nested directory. No marketplace installation, user-level plugin, `--plugin-dir`, or runtime copy is required.

Ask naturally, for example:

```text
登录 fdpo tenant，列出 MI，启动选中的实例
列出所有资源
列出所有 VM
列出所有 MI
列出 dlinger 的数据库和状态
检查 dlinger 是否有异常备份记录
把 db1 恢复到 2026-10-10T01:00:00Z，目标名 db1-restore
把 dlinger/db1 恢复到 lduan-mi-sea/db1-restore
调查这个 MI
是否需要扩容
生成支持工单草稿
```

The skills resolve the repository root with Git, validate `miops.ps1` and `src/MiOps.psm1`, and keep ignored configuration and state under that root. They never accept an arbitrary runtime path from a prompt.

Project skills load only when Copilot starts inside this repository. Starting Copilot elsewhere does not load Azure SQLOps. If an older user-installed `azure-sqlops` plugin is enabled, uninstall or disable it separately to avoid duplicate same-name skills; this repository does not modify global Copilot configuration. See [GitHub Copilot CLI project skills](docs/copilot-cli-project-skills.md) for discovery, setup, local file locations, and capability boundaries.

## Implemented phase-1 capabilities

- List all Azure resources, all virtual machines, or all Azure SQL Managed Instances in the validated selected/current subscription using fixed read-only queries.
- Return minimal inventory metadata; MI inventory additionally includes state, provisioning state, and tier when available.
- Validate local configuration, Azure CLI login, active subscription, provider registration, and observable MI read access.
- Interactively sign in to a tenant, choose an enabled subscription, discover MIs, and write one exact ignored local allowlist.
- Offer a safe interactive operations menu that reuses the same deterministic functions as direct commands.
- Show MI state and conservative local lifecycle eligibility.
- List user databases and minimal ARM state/restore metadata for an exact source MI allowlist entry.
- Check backup health with conservative per-database warning versus insufficient-evidence findings.
- Inspect STR/LTR policies, latest LTR records where expected, and restorable deleted databases without claiming ARM exposes every STR backup event.
- Optionally query recent `msdb` backup history through a disabled-by-default, fixed, read-only `sqlcmd -G` adapter.
- Independently configure exact restore targets; source/discovered MIs never become restore targets automatically.
- Plan or submit same-instance and cross-instance PITR to a new database using the current `az sql midb restore` command shape.
- Require dual source/target allowlists, dual exact resource approvals, and confirmation bound to source DB, target MI/DB, and UTC timestamp.
- Persist restore intent before submission and poll until destination ARM state is authoritatively `Online`.
- Submit controlled `start` and `stop` operations through `az sql mi --no-wait`.
- Default every mutation to dry-run; require `-Apply` plus the exact allowlisted resource ID.
- Persist local operation state and later poll the MI until the desired state is independently observed.
- Inspect an Azure-native start/stop schedule, create a review plan, and explicitly delete an existing schedule.
- Collect read-only Azure Resource Manager, Activity Log, Resource Health, and Azure Monitor evidence.
- Generate a redacted Microsoft Support case draft/evidence summary.
- Record redacted local JSONL audit events.
- Expose SQL DMV/Query Store diagnostics as a disabled optional adapter boundary.

Inventory never allowlists resources or grants mutation capability. Phase 1 does **not** perform VM actions, automatically resize, create/update automatic stop schedules, overwrite/delete databases, create native backups, mutate retention, delete LTR backups, run arbitrary SQL, remediate incidents, or submit Microsoft Support cases.

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
# Browser-based Azure CLI login, subscription selection, and MI discovery:
pwsh .\miops.ps1 setup -TenantId 'fdpo.onmicrosoft.com'

# Omit -TenantId to choose from the tenants returned by Azure CLI:
pwsh .\miops.ps1 setup

# Use this instead when browser launch is unavailable:
pwsh .\miops.ps1 setup -TenantId '<tenant-domain-or-guid>' -UseDeviceCode

pwsh .\miops.ps1 interactive

pwsh .\miops.ps1 inventory -ResourceKind all
pwsh .\miops.ps1 inventory -ResourceKind vm
pwsh .\miops.ps1 inventory -ResourceKind mi
pwsh .\miops.ps1 preflight
pwsh .\miops.ps1 status
pwsh .\miops.ps1 database-list
pwsh .\miops.ps1 backup-check
pwsh .\miops.ps1 evidence -LookbackHours 24
```

`fdpo.onmicrosoft.com` is an example tenant domain only. Azure CLI performs authentication and the operator completes it locally in the browser or device-code flow. The toolkit never accepts or stores passwords, tokens, or client secrets. Subscription IDs are resource identifiers, not credentials.

Browser and device-code login are authentication interfaces, not Conditional Access bypasses. If the tenant requires device compliance or another organization policy, use an organization-approved managed device or contact the tenant administrator.

Inventory uses the ignored onboarding config when it exists and refuses to query unless the active Azure CLI tenant/subscription matches it. Without config, it explicitly scopes to the active Azure CLI subscription. `-ResourceKind` is closed to `all`, `vm`, or `mi`; arbitrary Azure CLI fragments, JMESPath, resource type strings, URLs, and shell arguments are not accepted.

For automation or repeatable setup, provide known identifiers while retaining exact selection approval:

```powershell
pwsh .\miops.ps1 setup `
  -TenantId '<tenant-guid>' `
  -SubscriptionId '<subscription-guid>' `
  -ManagedInstanceId '/subscriptions/<subscription-guid>/resourceGroups/<rg>/providers/Microsoft.Sql/managedInstances/<mi>' `
  -ApproveManagedInstanceId '/subscriptions/<subscription-guid>/resourceGroups/<rg>/providers/Microsoft.Sql/managedInstances/<mi>'
```

Start and stop are dry-run by default:

```powershell
pwsh .\miops.ps1 start

$mi = '/subscriptions/<subscription>/resourceGroups/<rg>/providers/Microsoft.Sql/managedInstances/<mi>'
pwsh .\miops.ps1 start -Apply -ApproveResourceId $mi
pwsh .\miops.ps1 operation-poll -OperationId '<local-operation-id>'
```

Backup health and PITR examples:

```powershell
pwsh .\miops.ps1 database-list
pwsh .\miops.ps1 backup-check
# Optional SQL recent-history evidence; requires config enablement, sqlcmd -G, network, and SQL read permission.
pwsh .\miops.ps1 backup-check -UseSqlHistory

$source = '/subscriptions/<source-sub>/resourceGroups/<source-rg>/providers/Microsoft.Sql/managedInstances/<source-mi>'
$target = '/subscriptions/<target-sub>/resourceGroups/<target-rg>/providers/Microsoft.Sql/managedInstances/<target-mi>'

pwsh .\miops.ps1 configure-restore-target `
  -TargetManagedInstanceId $target `
  -TypedConfirmation 'CONFIGURE RESTORE TARGET <target-mi>'

pwsh .\miops.ps1 restore-plan `
  -SourceManagedInstanceId $source `
  -SourceDatabase 'db1' `
  -TargetManagedInstanceId $target `
  -TargetDatabase 'db1-restore' `
  -RestoreTimeUtc '2026-10-10T01:00:00Z'

pwsh .\miops.ps1 restore-apply `
  -SourceManagedInstanceId $source `
  -SourceDatabase 'db1' `
  -TargetManagedInstanceId $target `
  -TargetDatabase 'db1-restore' `
  -RestoreTimeUtc '2026-10-10T01:00:00Z' `
  -ApproveSourceResourceId $source `
  -ApproveTargetResourceId $target `
  -TypedConfirmation 'RESTORE db1 TO <target-mi>/db1-restore AT 2026-10-10T01:00:00Z'

pwsh .\miops.ps1 operation-poll -OperationId '<local-restore-operation-id>'
```

Restore defaults to plan-only. Even same-instance restore requires the MI in both the source and independent restore-target allowlists. The destination must not exist, system databases are rejected, the timestamp must be strict UTC and in the past, and Azure-exposed `earliestRestoreDate` is enforced. Cross-instance PITR requires the same region; cross-subscription PITR additionally requires the same Microsoft Entra tenant and Azure-supported subscription types. Azure remains authoritative for primary-instance/primary-region, service endpoint policy, BYOK, storage capacity, permissions, and backup availability constraints.

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
| `setup` | Azure CLI interactive login, enabled subscription selection, MI discovery, and exact local allowlist generation |
| `interactive` | Menu for supported read-only, dry-run, explicitly confirmed lifecycle, polling, and support-draft guidance |
| `inventory -ResourceKind all\|vm\|mi` | Read-only metadata inventory in the validated subscription; never changes the MI allowlist |
| `preflight` | Read-only checks; cannot prove all write permissions or feature eligibility |
| `status` | Read-only MI state |
| `database-list` | Read-only user database state and minimal restore metadata for an exact source MI |
| `backup-check` | Read-only ARM backup policy/eligibility findings; optional fixed SQL history adapter |
| `configure-restore-target` | Adds one exact independently approved target MI to ignored local config |
| `restore-plan` | Validates and displays a PITR plan; never mutates Azure |
| `restore-apply` | Non-blocking PITR submission after dual approvals and exact field-bound phrase |
| `start`, `stop` | Dry-run unless exact explicit approval is provided |
| `operation-poll` | Read-only reconciliation of a persisted operation |
| `schedule-show` | Read-only inspection |
| `schedule-plan` | Local plan only; does not enable automation |
| `schedule-delete` | Dry-run by default; applying only disables an existing Azure schedule |
| `evidence` | Read-only Azure evidence bundle |
| `support-draft` | Local redacted draft only; no API submission |
| `sql-adapter-status` | Reports the disabled-by-default fixed `backup-history-v1` SQL adapter boundary |

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

Tests do not require Azure. They cover inventory selector validation, database state/schema shaping, anomaly rules and evidence gaps, threshold validation, strict UTC timestamps, system database rejection, exact source/target allowlisting, destination collision rejection, dual approval and typed confirmation, restore persistence/poll transitions, fixed SQL adapter/redaction behavior, all five project skill definitions, repository-root runtime resolution guidance, and removal of obsolete plugin packaging.

## Azure SQL Managed Instance backup and restore references

- [Azure CLI `az sql midb restore`](https://learn.microsoft.com/cli/azure/sql/midb#az-sql-midb-restore) documents `--dest-name`, `--time`, `--deleted-time`, `--dest-mi`, `--dest-resource-group`, `--source-sub`, `--subscription`, and `--no-wait`.
- [Point-in-time restore for Azure SQL Managed Instance](https://learn.microsoft.com/azure/azure-sql/managed-instance/point-in-time-restore) documents same/different instance and cross-subscription scenarios plus tenant, region, permission, primary-region, BYOK, service endpoint policy, and storage limitations.
- [Automatic backups for Azure SQL Managed Instance](https://learn.microsoft.com/azure/azure-sql/managed-instance/automated-backups-overview) documents weekly full, 12/24-hour differential, and approximately 10-minute log backup cadence and 7-35 day PITR retention.
- [Long-term retention for Azure SQL Managed Instance](https://learn.microsoft.com/azure/azure-sql/managed-instance/long-term-backup-retention-configure) documents LTR policy visibility, permissions, up-to-10-year retention, and that the first backup can take up to seven days to appear.
- [Azure CLI STR policy](https://learn.microsoft.com/cli/azure/sql/midb/short-term-retention-policy) and [LTR backup](https://learn.microsoft.com/cli/azure/sql/midb/ltr-backup) references define the fixed read-only command shapes used by `backup-check`.

## Documentation

- [Architecture](docs/architecture.md)
- [MVP scope and limitations](docs/mvp-scope.md)
- [Security and governance](docs/security-and-governance.md)
- [GitHub Copilot CLI project skills](docs/copilot-cli-project-skills.md)
- [Platform decision](docs/decision-log/0001-platform-strategy.md)
- [Optional SQL diagnostics adapter contract](adapters/sql/README.md)

The canonical [`.github/skills/`](.github/skills) definitions give Copilot CLI exact command guidance while preserving inventory, MI read-only, and MI mutation boundaries.
