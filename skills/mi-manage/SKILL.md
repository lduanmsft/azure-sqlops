---
name: mi-manage
description: Use the local PowerShell toolkit to inspect and safely start, stop, poll, or inspect schedules for one allowlisted Azure SQL Managed Instance.
metadata:
  status: implemented-locally-not-tenant-validated
---

# MI Manage

Use repository-root commands only. The runtime is local Copilot CLI + PowerShell 7 + Azure CLI; Azure SRE Agent is not required.

## Tenant onboarding

Use Azure CLI interactive authentication through the setup command:

```powershell
# Browser login:
pwsh .\miops.ps1 setup -TenantId 'fdpo.onmicrosoft.com'

# Browser login followed by a numbered tenant menu:
pwsh .\miops.ps1 setup

# Device-code login when a browser cannot be opened:
pwsh .\miops.ps1 setup -TenantId '<tenant-domain-or-guid>' -UseDeviceCode
```

`fdpo.onmicrosoft.com` is an example only. The operator completes authentication locally using Azure CLI. Never request, accept, echo, or store passwords, access tokens, refresh tokens, or client secrets. Subscription IDs are identifiers, not credentials.

If `-TenantId` is omitted, setup presents the tenants returned by Azure CLI as a numbered menu. If `-SubscriptionId` is omitted, setup lists accessible enabled subscriptions in the chosen tenant and asks for a numbered selection. It then confirms the active tenant/subscription, discovers all MIs with `az sql mi list --subscription ...`, shows name, resource group, location, state, tier, and full resource ID, and requires `CONFIGURE <mi-name>` before writing ignored `config/miops.local.json`.

Known identifiers can be supplied for repeatable setup, but exact MI approval remains mandatory:

```powershell
$mi = '/subscriptions/<subscription-guid>/resourceGroups/<rg>/providers/Microsoft.Sql/managedInstances/<mi>'
pwsh .\miops.ps1 setup `
  -TenantId '<tenant-guid>' `
  -SubscriptionId '<subscription-guid>' `
  -ManagedInstanceId $mi `
  -ApproveManagedInstanceId $mi
```

After setup:

```powershell
pwsh .\miops.ps1 interactive
```

The interactive menu supports status, evidence, start/stop dry-runs, explicitly confirmed start/stop apply, schedule inspection, operation polling, and local support-draft guidance. Apply requires typing `START <mi-name>` or `STOP <mi-name>` after the exact resource, name, and current state are shown. A menu number alone never authorizes a mutation.

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
