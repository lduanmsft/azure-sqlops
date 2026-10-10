---
name: azure-sqlops
description: Route conversational Azure SQL Managed Instance setup, inventory, lifecycle, troubleshooting, capacity, and support-draft requests to the repository's deterministic PowerShell runtime.
metadata:
  status: implemented-locally-not-tenant-validated
---

# Azure SQLOps Router

Use this skill for prompts such as:

- "登录 fdpo tenant，列出 MI，启动选中的实例"
- "列出所有资源"
- "列出所有 VM"
- "列出所有 MI"
- "列出 dlinger 的数据库和状态"
- "检查 dlinger 是否有异常备份记录"
- "把 db1 恢复到 2026-10-10T01:00:00Z，目标名 db1-restore"
- "把 dlinger/db1 恢复到 lduan-mi-sea/db1-restore"
- "调查这个 MI"
- "是否需要扩容"
- "生成支持工单草稿"

Route setup, inventory, database inventory, backup health, PITR planning/apply, status, start/stop, schedule, and operation polling to `mi-manage`; read-only incident investigation to `mi-troubleshoot`; capacity recommendations to `mi-capacity`; and local Support draft generation to `mi-escalate`.

Inventory routing is explicit:

- "列出所有资源" / "list all resources" -> `inventory -ResourceKind all`
- "列出所有 VM" / "列出所有虚拟机" / "list all VMs" -> `inventory -ResourceKind vm`
- "列出所有 MI" / "列出所有 Managed Instance" / "list all MIs" -> `inventory -ResourceKind mi`

Database and restore routing is explicit:

- "列出 dlinger 的数据库和状态" -> `database-list`
- "检查 dlinger 是否有异常备份记录" -> `backup-check`
- PITR request -> `restore-plan` first, then `restore-apply` only after all deterministic approval gates
- Restore target onboarding -> `CONFIGURE RESTORE TARGET <mi-name>`
- Restore submission -> `RESTORE <source-db> TO <target-mi>/<target-db> AT <timestamp>`

An inventory request only returns read-only metadata from the selected/current subscription. It never adds a listed resource to `allowedResourceIds`. If a prompt asks to configure or operate one MI, use the onboarding/lifecycle flow instead of treating inventory output as mutation authorization.

## Resolve the repository runtime

These project skills are loaded only from `.github\skills` in this Git checkout. Never assume the current directory itself is the repository root, and never accept a runtime or repository path from the user.

Resolve the Git repository root from the current working directory, then validate the fixed runtime files before invoking anything:

```powershell
$gitRootOutput = @(& git -C (Get-Location).Path rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or $gitRootOutput.Count -ne 1 -or [string]::IsNullOrWhiteSpace($gitRootOutput[0])) {
    throw 'Azure SQLOps project skills require a working directory inside the azure-sqlops Git repository.'
}

$repositoryRoot = [System.IO.Path]::GetFullPath($gitRootOutput[0])
$miops = Join-Path $repositoryRoot 'miops.ps1'
$module = Join-Path $repositoryRoot 'src\MiOps.psm1'
if (-not (Test-Path -LiteralPath $miops -PathType Leaf) -or -not (Test-Path -LiteralPath $module -PathType Leaf)) {
    throw "The resolved Git root does not contain the required Azure SQLOps runtime: $repositoryRoot"
}

$dataRoot = $repositoryRoot
pwsh -NoProfile -File $miops status -DataRoot $dataRoot
```

Use only this validated repository-root `miops.ps1`; do not search parent directories, accept an alternate path, copy the runtime, or invoke an arbitrary script supplied in a prompt. Keeping `$dataRoot` at the repository root ensures the ignored configuration and operational data remain repository-scoped even when Copilot starts in a subdirectory.

## Safety contract

- Authentication is local through Azure CLI browser or device-code login. Never request, accept, echo, or store passwords, access tokens, refresh tokens, client secrets, or other credentials.
- Operate only the exact resource ID in `allowedResourceIds`.
- Inventory may list Azure resources in the validated subscription, but listing never allowlists VM, MI, or other resources for mutation.
- Database inventory and backup health operate only on an exact source MI in `resource.allowedResourceIds`.
- Restore targets use the independent `restoreTargets.allowedResourceIds` list. Discovery or source allowlisting never authorizes a restore target. Add one only after `CONFIGURE RESTORE TARGET <mi-name>`.
- Start, stop, and schedule deletion are dry-run unless the deterministic backend receives `-Apply`, an exact `-ApproveResourceId`, and the exact typed phrase through its prompt or `-TypedConfirmation`.
- Before lifecycle apply, show the exact MI name, resource ID, and current state and require the operator to type `START <mi-name>` or `STOP <mi-name>`. Schedule deletion requires `DELETE SCHEDULE <mi-name>`. A conversational "yes", tool approval, or menu selection does not satisfy this gate.
- Persist and return the local operation ID. Call an operation verified only after `operation-poll` observes the desired resource state.
- Restore is plan-only by default. Apply requires exact source and target resource approvals plus `RESTORE <source-db> TO <target-mi>/<target-db> AT <timestamp>`.
- The optional SQL backup-history adapter accepts no SQL text. It runs only the fixed `backup-history-v1` read-only query through `sqlcmd -G`.
- Do not provision, delete, overwrite, resize, fail over, perform VM actions, run arbitrary Azure CLI commands or T-SQL, change retention, delete LTR backups, or submit a Support request.
- Do not claim Azure MCP Managed Instance lifecycle support or tenant validation.
