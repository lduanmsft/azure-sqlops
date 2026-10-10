---
name: mi-manage
description: Use the local PowerShell toolkit to inspect and safely start, stop, poll, or inspect schedules for one allowlisted Azure SQL Managed Instance.
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

Report provider, permission, configuration, or evidence gaps exactly. Do not infer that preflight proves lifecycle write access.

## Mutating commands

`start`, `stop`, and `schedule-delete` are dry-run by default:

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
- No resource outside `allowedResourceIds`.
- Inventory output never changes `allowedResourceIds`.
- No claim of tenant validation.
