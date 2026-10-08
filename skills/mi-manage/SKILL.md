---
name: mi-manage
description: Use the local PowerShell toolkit to inspect and safely start, stop, poll, or inspect schedules for one allowlisted Azure SQL Managed Instance.
metadata:
  status: implemented-locally-not-tenant-validated
---

# MI Manage

Use repository-root commands only. The runtime is local Copilot CLI + PowerShell 7 + Azure CLI; Azure SRE Agent is not required.

## Read-only commands

```powershell
pwsh .\miops.ps1 preflight
pwsh .\miops.ps1 status
pwsh .\miops.ps1 schedule-show
pwsh .\miops.ps1 schedule-plan
pwsh .\miops.ps1 operation-poll -OperationId '<local-operation-id>'
```

Report provider, permission, configuration, or evidence gaps exactly. Do not infer that preflight proves lifecycle write access.

## Mutating commands

`start`, `stop`, and `schedule-delete` are dry-run by default:

```powershell
pwsh .\miops.ps1 start
pwsh .\miops.ps1 stop
pwsh .\miops.ps1 schedule-delete
```

Only execute after the operator approves the exact canonical resource ID:

```powershell
$mi = '/subscriptions/<subscription>/resourceGroups/<rg>/providers/Microsoft.Sql/managedInstances/<mi>'
pwsh .\miops.ps1 start -Apply -ApproveResourceId $mi
pwsh .\miops.ps1 stop -Apply -ApproveResourceId $mi
pwsh .\miops.ps1 schedule-delete -Apply -ApproveResourceId $mi
```

Never add `-Apply` or fill the approval ID without explicit operator authorization in the current context. Schedule deletion disables automation; phase 1 does not create/update schedules or implement automatic stop.

## Long-running operations

Return the local operation ID and instruct polling. Use **Submitted** for CLI acceptance and **Verified** only after `operation-poll` observes the desired MI state. If Azure returns no operation ID, explain that the local operation record plus resource-state polling is the recovery mechanism.

## Prohibited

- No provisioning, deletion, resize, failover, arbitrary `az` commands, or T-SQL.
- No resource outside `allowedResourceIds`.
- No claim of tenant validation.
