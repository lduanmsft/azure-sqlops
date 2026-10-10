# GitHub Copilot CLI project skills

This repository exposes Azure inventory and SQL Managed Instance operations as project-scoped Copilot Skills under `.github/skills`. The skills invoke the deterministic PowerShell runtime at the Git repository root.

## Use from a clone

Clone or pull the repository, enter any directory inside the checkout, and start Copilot CLI:

```powershell
git clone https://github.com/lduanmsft/azure-sqlops.git
Set-Location .\azure-sqlops
copilot
```

Copilot CLI discovers `.github/skills` from the Git repository root, including when it starts in a nested directory. No `--plugin-dir`, marketplace installation, user-level plugin, or copied runtime is required.

These skills are available only while Copilot is running inside this repository. Starting Copilot from another repository or an unrelated directory does not load them. If an older user-installed `azure-sqlops` plugin is still enabled, uninstall or disable it separately to avoid duplicate same-name skills; this repository never changes global Copilot configuration.

## Start a conversation

Start `copilot` anywhere inside the repository. Example Chinese prompts:

```text
登录 fdpo tenant，列出 MI，启动选中的实例
列出所有资源
列出所有 VM
列出所有虚拟机
列出所有 MI
调查这个 MI 最近 24 小时的异常
根据现有证据判断是否需要扩容
基于最新证据生成支持工单草稿
```

`fdpo.onmicrosoft.com` is only an example tenant domain.

Inventory prompt routing:

- `列出所有资源` / `list all resources` lists resources with the fixed `all` selector.
- `列出所有 VM` / `列出所有虚拟机` / `list all VMs` lists only `Microsoft.Compute/virtualMachines`.
- `列出所有 MI` / `list all Managed Instances` reuses Azure SQL MI enumeration.

These are read-only listing requests. They do not configure an MI and never add a listed resource to the lifecycle allowlist.

## Initial setup

For the first prompt, the agent runs the repository setup command. Azure CLI opens a browser or device-code flow locally. The agent must never ask for a password, token, refresh token, client secret, or other credential.

Setup:

1. Signs in through Azure CLI.
2. Selects an accessible enabled subscription.
3. Lists Azure SQL Managed Instances in that subscription.
4. Shows the exact selected resource ID.
5. Requires `CONFIGURE <mi-name>` before writing the local allowlist.

Local files remain under the repository root regardless of which repository subdirectory launched Copilot:

```text
config/miops.local.json
.miops/
  operations/
  evidence/
  support/
  audit.jsonl
```

These files can contain operational metadata. Keep the directory private, review evidence before sharing it, and move audit records to an approved durable store for production use.

## Safety and capability boundaries

The agent can list minimal metadata for Azure resources, VMs, or MIs in the validated selected/current subscription. It can also inspect one allowlisted existing MI, collect bounded Azure control-plane evidence, produce capacity guidance, start or stop an eligible MI, inspect or delete an existing start/stop schedule, poll durable operation records, and create a redacted local Support draft.

The inventory selector is closed to `all`, `vm`, and `mi`. The agent cannot accept arbitrary Azure CLI fragments, JMESPath, resource type strings, URLs, or shell arguments. It cannot provision or delete resources, resize or fail over an MI, perform VM actions, create or update automatic schedules, execute T-SQL, kill sessions, submit a Microsoft Support request, or claim Azure MCP MI lifecycle support. SQL DMV and Query Store diagnostics are not implemented.

When onboarding config exists, inventory verifies that the active Azure CLI tenant and subscription match it. Without config, the result explicitly states that the current active subscription was used. Missing login, mismatches, permission failures, and empty results are reported explicitly. Inventory writes a redacted local audit event.

Mutations remain deterministic:

- The backend defaults to dry-run.
- The resource must exactly match `allowedResourceIds`.
- Apply requires `-Apply`, the exact `-ApproveResourceId`, and an exact typed confirmation.
- Lifecycle apply requires `START <mi-name>` or `STOP <mi-name>` after the backend shows the current state and exact resource. Schedule deletion requires `DELETE SCHEDULE <mi-name>`.
- A conversational "yes" or Copilot tool approval cannot bypass those checks.
- Submission is recorded locally and is not called verified until polling observes the desired Azure state.

## Runtime resolution

The router skill resolves the repository root with `git rev-parse --show-toplevel`, requires both `miops.ps1` and `src/MiOps.psm1`, and uses that validated root as `-DataRoot`. Skills never accept an alternate runtime path from a prompt and never search for or execute arbitrary scripts.

`.github/skills` is Copilot CLI's project discovery directory. `.github/plugins` is not auto-loaded and is intentionally not used by this repository.

## Direct PowerShell compatibility

Existing repository users can continue to run:

```powershell
pwsh .\miops.ps1 setup
pwsh .\miops.ps1 interactive
pwsh .\miops.ps1 inventory -ResourceKind all
pwsh .\miops.ps1 inventory -ResourceKind vm
pwsh .\miops.ps1 inventory -ResourceKind mi
pwsh .\miops.ps1 status
```

The project skills pass the validated repository root through `-DataRoot`. Direct repository commands can omit it because `miops.ps1` already defaults to its own directory.
