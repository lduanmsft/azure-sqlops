---
name: mi-manage
description: Use the local PowerShell toolkit to inspect databases and backup health, safely plan or submit PITR restores, and manage lifecycle operations for explicitly allowlisted Azure SQL Managed Instances.
metadata:
  status: implemented-locally-not-tenant-validated
---

# MI Manage and Inventory

Use the repository-root runtime resolution procedure in `../azure-sqlops/SKILL.md`. Never assume the current directory is the repository root. Set validated absolute `$miops` and `$dataRoot` paths before running commands. The runtime is local Copilot CLI + PowerShell 7 + Azure CLI; Azure SRE Agent is not required.

## Tenant onboarding

Use Azure CLI interactive authentication through the setup command:

```powershell
# Browser login:
pwsh -NoProfile -File $miops setup -DataRoot $dataRoot -TenantId 'fdpo.onmicrosoft.com'

# Browser login followed by a numbered tenant menu:
pwsh -NoProfile -File $miops setup -DataRoot $dataRoot

# Device-code login when a browser cannot be opened:
pwsh -NoProfile -File $miops setup -DataRoot $dataRoot -TenantId '<tenant-domain-or-guid>' -UseDeviceCode
```

`fdpo.onmicrosoft.com` is an example only. The operator completes authentication locally using Azure CLI. Never request, accept, echo, or store passwords, access tokens, refresh tokens, or client secrets. Subscription IDs are identifiers, not credentials.

Browser and device-code flows cannot bypass Conditional Access, device compliance, or tenant policy. If Azure rejects login for those reasons, use an organization-approved managed device or contact the tenant administrator.

If `-TenantId` is omitted, setup presents the tenants returned by Azure CLI as a numbered menu. If `-SubscriptionId` is omitted, setup lists accessible enabled subscriptions in the chosen tenant and asks for a numbered selection. It then confirms the active tenant/subscription, discovers all MIs with `az sql mi list --subscription ...`, shows name, resource group, location, state, tier, and full resource ID, and requires `CONFIGURE <mi-name>` before writing ignored `config/miops.local.json`.

Known identifiers can be supplied for repeatable setup, but exact MI approval remains mandatory:

```powershell
$mi = '/subscriptions/<subscription-guid>/resourceGroups/<rg>/providers/Microsoft.Sql/managedInstances/<mi>'
pwsh -NoProfile -File $miops setup -DataRoot $dataRoot `
  -TenantId '<tenant-guid>' `
  -SubscriptionId '<subscription-guid>' `
  -ManagedInstanceId $mi `
  -ApproveManagedInstanceId $mi
```

After setup:

```powershell
pwsh -NoProfile -File $miops interactive -DataRoot $dataRoot
```

The interactive menu supports status, evidence, start/stop dry-runs, explicitly confirmed start/stop apply, schedule inspection, operation polling, and local support-draft guidance. Apply requires typing `START <mi-name>` or `STOP <mi-name>` after the exact resource, name, and current state are shown. A menu number alone never authorizes a mutation.

## Read-only commands

```powershell
pwsh -NoProfile -File $miops inventory -DataRoot $dataRoot -ResourceKind all
pwsh -NoProfile -File $miops inventory -DataRoot $dataRoot -ResourceKind vm
pwsh -NoProfile -File $miops inventory -DataRoot $dataRoot -ResourceKind mi
pwsh -NoProfile -File $miops preflight -DataRoot $dataRoot
pwsh -NoProfile -File $miops status -DataRoot $dataRoot
pwsh -NoProfile -File $miops database-list -DataRoot $dataRoot
pwsh -NoProfile -File $miops backup-check -DataRoot $dataRoot
pwsh -NoProfile -File $miops ltr-policy-show -DataRoot $dataRoot -Database 'test02'
pwsh -NoProfile -File $miops ltr-policy-plan -DataRoot $dataRoot -Database 'test02' -WeeklyRetention 'P12W' -MonthlyRetention 'P12M' -YearlyRetention 'P5Y' -WeekOfYear 1
pwsh -NoProfile -File $miops schedule-show -DataRoot $dataRoot
pwsh -NoProfile -File $miops schedule-plan -DataRoot $dataRoot
pwsh -NoProfile -File $miops operation-poll -DataRoot $dataRoot -OperationId '<local-operation-id>'
```

Use the closed selector exactly as routed:

- "列出所有资源" / "list all resources" -> `all`
- "列出所有 VM" / "列出所有虚拟机" / "list all VMs" -> `vm`
- "列出所有 MI" / "列出所有 Managed Instance" / "list all MIs" -> `mi`

Never pass arbitrary Azure CLI fragments, JMESPath, resource type strings, URLs, or shell arguments. Inventory uses the ignored onboarding config when present and requires the active Azure CLI tenant/subscription to match it. Without config, it explicitly uses the current active subscription. An optional `-SubscriptionId` must be a GUID and must match the active/configured subscription.

Inventory returns minimal metadata only: name, resource group, type, location, and resource ID. MI inventory also includes state, provisioning state, and tier when Azure returns them. Empty results, missing config, missing login, subscription mismatch, and permission failures must be reported explicitly. Listing any resource is read-only and never adds it to the MI mutation allowlist.

Route these prompts deterministically:

- `列出 dlinger 的数据库和状态` -> `database-list` for the exact allowlisted `dlinger` MI.
- `检查 dlinger 是否有异常备份记录` -> `backup-check` for the exact allowlisted `dlinger` MI.
- `把 db1 恢复到 2026-10-10T01:00:00Z，目标名 db1-restore` -> `restore-plan` with the source MI also explicitly configured as a restore target.
- `把 dlinger/db1 恢复到 lduan-mi-sea/db1-restore` -> resolve the requested strict UTC time, then `restore-plan` with `lduan-mi-sea` independently configured as a restore target.

`database-list` excludes system databases and returns minimal name, status, creation date, earliest restore date, source/restore metadata when Azure exposes it, and resource ID. Null means the current CLI/API schema did not expose that field. Stopped/unavailable instances, empty results, permissions, and schema failures are explicit.

`backup-check` evaluates database state, STR policy, LTR policy and latest LTR record when expected, restorable deleted database evidence, and restore boundaries where exposed. ARM does **not** expose every STR full/differential/log backup record. Optional SQL history is recent `msdb` transparency only and never replaces Azure durable backup evidence:

```powershell
pwsh -NoProfile -File $miops backup-check -DataRoot $dataRoot -UseSqlHistory
```

SQL history is disabled by default. When enabled in config it uses `sqlcmd` Microsoft Entra authentication, the fixed `backup-history-v1` read-only query, bounded timeout/rows, and no password/token configuration. Private networking, missing `sqlcmd`, and SQL permission failures are reported as evidence gaps.

## LTR policy view, plan, and guarded apply

Route these prompts deterministically:

- `查看 dlinger/test02 的 LTR 策略` -> `ltr-policy-show -Database test02` for the exact allowlisted `dlinger` MI.
- `计划为 test02 配置每周 12 周、每月 12 个月、每年 5 年，第 1 周` -> `ltr-policy-plan -Database test02 -WeeklyRetention P12W -MonthlyRetention P12M -YearlyRetention P5Y -WeekOfYear 1`.
- `应用这个 LTR 策略` -> apply only the previously displayed exact normalized policy through `ltr-policy-apply`.

The source MI must be an exact `resource.allowedResourceIds` member, and the database must exist exactly once in the reused non-system database inventory. Never infer an MI, database, subscription, or resource group from loose names.

Accepted requested retention values are deliberately stricter than the Azure CLI's permissive parser:

- One single-unit normalized duration: `P<n>D`, `P<n>W`, `P<n>M`, or `P<n>Y`.
- Minimum 7 days. Deterministic maxima are `P3650D`, `P521W`, `P120M`, or `P10Y`.
- Units are not restricted by policy dimension; the official MI REST example uses a monthly unit for weekly retention.
- `PT0S` disables one dimension only. At least one dimension must remain enabled.
- `WeekOfYear` must be 1-52 when yearly retention is enabled and 0 when yearly retention is `PT0S`.

Reject bare numbers, mixed/compound units, time components, fractions, lowercase/whitespace variants, zero/negative quantities, shell fragments, JMESPath, and arbitrary ISO-8601 strings. Azure CLI itself accepts a bare number as days, but this runtime does not because the confirmation and audit policy must be unambiguous.

Plan always reads and displays the current policy first. It returns the current and requested normalized values, exact MI/database/subscription, required confirmation, reduction classification, fixed CLI arguments, and cost/compliance/platform warnings. Planning never calls `set`.

Apply requires:

```powershell
$mi = '/subscriptions/<subscription>/resourceGroups/<rg>/providers/Microsoft.Sql/managedInstances/<mi>'
pwsh -NoProfile -File $miops ltr-policy-apply -DataRoot $dataRoot `
  -Database 'test02' `
  -WeeklyRetention 'P12W' `
  -MonthlyRetention 'P12M' `
  -YearlyRetention 'P5Y' `
  -WeekOfYear 1 `
  -Apply `
  -ApproveResourceId $mi `
  -TypedConfirmation 'SET LTR test02 WEEKLY P12W MONTHLY P12M YEARLY P5Y WEEK 1'
```

A conversational yes, tool approval, or menu number never satisfies the gate. The runtime submits only the fixed `az sql midb ltr-policy set` shape and explicitly includes all three retention dimensions; it does not rely on omitted CLI values. When yearly retention is disabled, `--week-of-year` is omitted and normalized to 0 for comparison.

By default, apply blocks reducing a nonzero duration or changing an enabled dimension to `PT0S`. A reviewed exception requires both `-AllowRetentionReduction` and the stronger exact phrase:

```text
REDUCE LTR test02 WEEKLY P6W MONTHLY PT0S YEARLY P5Y WEEK 1
```

The reduction switch never permits all dimensions to be disabled. No delete, clear, reset, or disable-policy command exists.

The runtime persists a redacted local operation and audit record before submission. Because `az sql midb ltr-policy set` is synchronous, it independently calls `show` afterward and uses **Verified** only when all normalized values exactly match. CLI exit 0 alone is not success.

Always report:

- Longer retention can increase Azure backup storage cost.
- Policy changes apply to future retained backups; existing backups keep the retention assigned when created and are not necessarily deleted immediately.
- The user must validate regulatory and organizational compliance requirements.
- First visible LTR backup can take up to seven days.
- SQL Managed Instance LTR backups cannot currently be configured as immutable.
- LTR depends on successful automated full backups; transaction-log pressure or features that delay log truncation can delay LTR creation.
- Azure remains authoritative for permissions, regional/platform availability, backup health, and failover behavior.

Official references:

- [Azure CLI `az sql midb ltr-policy`](https://learn.microsoft.com/cli/azure/sql/midb/ltr-policy)
- [Managed Instance LTR policy create-or-update REST operation](https://learn.microsoft.com/rest/api/sql/managed-instance-long-term-retention-policies/create-or-update)
- [Configure SQL Managed Instance LTR](https://learn.microsoft.com/azure/azure-sql/managed-instance/long-term-backup-retention-configure)
- [LTR concepts and policy-change semantics](https://learn.microsoft.com/azure/azure-sql/database/long-term-retention-overview)

The current Azure CLI reference marks both MI LTR policy commands as core GA, not preview. Microsoft documents no separate LTR-only region list; use is bounded by SQL Managed Instance availability and Azure-side backup/platform constraints in the selected region.

## Restore targets and PITR

A source MI is not automatically a restore target, even for same-instance restore. Configure the exact target after reviewing discovered inventory:

```powershell
$target = '/subscriptions/<subscription>/resourceGroups/<rg>/providers/Microsoft.Sql/managedInstances/<target-mi>'
pwsh -NoProfile -File $miops configure-restore-target -DataRoot $dataRoot `
  -TargetManagedInstanceId $target `
  -TypedConfirmation 'CONFIGURE RESTORE TARGET <target-mi>'
```

Plan first:

```powershell
pwsh -NoProfile -File $miops restore-plan -DataRoot $dataRoot `
  -SourceDatabase 'db1' `
  -TargetManagedInstanceId $target `
  -TargetDatabase 'db1-restore' `
  -RestoreTimeUtc '2026-10-10T01:00:00Z'
```

Apply only after reviewing the returned source/target IDs, database names, time, earliest restore boundary, region/tenant checks, and detected platform constraints:

```powershell
$source = '/subscriptions/<subscription>/resourceGroups/<rg>/providers/Microsoft.Sql/managedInstances/<source-mi>'
pwsh -NoProfile -File $miops restore-apply -DataRoot $dataRoot `
  -SourceManagedInstanceId $source `
  -SourceDatabase 'db1' `
  -TargetManagedInstanceId $target `
  -TargetDatabase 'db1-restore' `
  -RestoreTimeUtc '2026-10-10T01:00:00Z' `
  -ApproveSourceResourceId $source `
  -ApproveTargetResourceId $target `
  -TypedConfirmation 'RESTORE db1 TO <target-mi>/db1-restore AT 2026-10-10T01:00:00Z'
```

The timestamp must be strict ISO-8601 UTC and earlier than now. System databases and existing destination names are rejected. Both source and target must be exact allowlist members, Ready/Succeeded, in the same region, and for cross-subscription restore in the same tenant. Azure additionally enforces supported subscription types, primary-instance/primary-region rules, permissions, service endpoint policy behavior, BYOK availability, storage capacity, and backup availability.

The fixed CLI shape is `az sql midb restore --source-sub ... --resource-group ... --mi ... --name ... --dest-name ... --dest-mi ... --dest-resource-group ... --time ... --subscription ... --no-wait`. Poll the returned local operation ID with `operation-poll`. Only an `Online` destination with successful provisioning becomes `Verified`.

Report provider, permission, configuration, or evidence gaps exactly. Do not infer that preflight proves lifecycle write access.

## Mutating commands

`start`, `stop`, `schedule-delete`, restore, and LTR policy changes are dry-run/plan by default:

```powershell
pwsh -NoProfile -File $miops start -DataRoot $dataRoot
pwsh -NoProfile -File $miops stop -DataRoot $dataRoot
pwsh -NoProfile -File $miops schedule-delete -DataRoot $dataRoot
```

Only execute after the operator approves the exact canonical resource ID:

```powershell
$mi = '/subscriptions/<subscription>/resourceGroups/<rg>/providers/Microsoft.Sql/managedInstances/<mi>'
pwsh -NoProfile -File $miops start -DataRoot $dataRoot -Apply -ApproveResourceId $mi
pwsh -NoProfile -File $miops stop -DataRoot $dataRoot -Apply -ApproveResourceId $mi
pwsh -NoProfile -File $miops schedule-delete -DataRoot $dataRoot -Apply -ApproveResourceId $mi
```

On apply, the backend also prompts for the exact typed phrase. For non-interactive invocation, pass only the exact phrase the operator supplied in the current context:

```powershell
pwsh -NoProfile -File $miops start -DataRoot $dataRoot -Apply -ApproveResourceId $mi -TypedConfirmation "START $miName"
pwsh -NoProfile -File $miops stop -DataRoot $dataRoot -Apply -ApproveResourceId $mi -TypedConfirmation "STOP $miName"
pwsh -NoProfile -File $miops schedule-delete -DataRoot $dataRoot -Apply -ApproveResourceId $mi -TypedConfirmation "DELETE SCHEDULE $miName"
```

Never add `-Apply`, fill the approval ID, or synthesize `-TypedConfirmation` from a conversational "yes". Schedule deletion disables automation; phase 1 does not create/update schedules or implement automatic stop.

## Long-running operations

Return the local operation ID and instruct polling. Use **Submitted** for CLI acceptance and **Verified** only after `operation-poll` observes the desired MI state. If Azure returns no operation ID, explain that the local operation record plus resource-state polling is the recovery mechanism.

## Prohibited

- No provisioning, deletion, resize, failover, VM actions, arbitrary `az` commands, or T-SQL.
- No database overwrite, system database restore, LTR policy clearing/deletion, LTR backup deletion, native backup creation, or arbitrary SQL.
- No resource outside `allowedResourceIds`.
- No restore target outside `restoreTargets.allowedResourceIds`.
- Inventory output never changes `allowedResourceIds`.
- No claim of tenant validation.
