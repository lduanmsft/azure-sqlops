---
name: azure-sqlops
description: Route conversational Azure SQL Managed Instance setup, inventory, lifecycle, troubleshooting, capacity, and support-draft requests to the bundled deterministic PowerShell runtime.
metadata:
  status: implemented-locally-not-tenant-validated
---

# Azure SQLOps Router

Use this skill for prompts such as:

- "登录 fdpo tenant，列出 MI，启动选中的实例"
- "调查这个 MI"
- "是否需要扩容"
- "生成支持工单草稿"

Route setup, inventory, status, start/stop, schedule, and operation polling to `mi-manage`; read-only incident investigation to `mi-troubleshoot`; capacity recommendations to `mi-capacity`; and local Support draft generation to `mi-escalate`.

## Resolve the runtime

Never assume the current directory is the source repository.

1. Determine the absolute path of this loaded `SKILL.md`.
2. If it is under an installed plugin, the plugin root is two directories above its containing skill directory. Use `<plugin-root>\runtime\miops.ps1`.
3. If it is the source checkout and `miops.ps1` exists two directories above the skill directory, use that file.
4. For an installed plugin, store workspace-local data under `<current-working-directory>\.azure-sqlops`. For a source checkout, use the repository root to preserve direct-command compatibility.

In PowerShell, keep the resolved paths in variables and quote them:

```powershell
$miops = '<absolute-path-to-miops.ps1>'
$dataRoot = '<absolute-repository-root-or-current-directory\.azure-sqlops>'
pwsh -NoProfile -File $miops status -DataRoot $dataRoot
```

The bundled runtime contains its own module and example configuration, so it does not depend on the user's current working directory. Never copy or edit the installed runtime during normal use.

## Safety contract

- Authentication is local through Azure CLI browser or device-code login. Never request, accept, echo, or store passwords, access tokens, refresh tokens, client secrets, or other credentials.
- Operate only the exact resource ID in `allowedResourceIds`.
- Start, stop, and schedule deletion are dry-run unless the deterministic backend receives `-Apply`, an exact `-ApproveResourceId`, and the exact typed phrase through its prompt or `-TypedConfirmation`.
- Before lifecycle apply, show the exact MI name, resource ID, and current state and require the operator to type `START <mi-name>` or `STOP <mi-name>`. Schedule deletion requires `DELETE SCHEDULE <mi-name>`. A conversational "yes", tool approval, or menu selection does not satisfy this gate.
- Persist and return the local operation ID. Call an operation verified only after `operation-poll` observes the desired resource state.
- Do not provision, delete, resize, fail over, run arbitrary Azure CLI commands, execute T-SQL, or submit a Support request.
- Do not claim Azure MCP Managed Instance lifecycle support or tenant validation.
