# GitHub Copilot CLI plugin

The `azure-sqlops` plugin turns the repository's four Azure SQL Managed Instance skills into an installable conversational experience. The installed package includes the deterministic PowerShell runtime, so Copilot CLI can use it from any working directory.

## Install from GitHub

Install or update GitHub Copilot CLI, then add this repository as a marketplace and install the plugin:

```text
copilot
/plugin marketplace add lduanmsft/azure-sqlops
/plugin install azure-sqlops@azure-sqlops
```

Restart Copilot CLI after installation if the skills do not appear in the current session. Check discovery with `/skills list`.

Later updates and removal:

```text
/plugin marketplace update azure-sqlops
/plugin update azure-sqlops@azure-sqlops
/plugin uninstall azure-sqlops
/plugin marketplace remove azure-sqlops
```

The equivalent non-interactive commands are `copilot plugin marketplace add`, `copilot plugin install`, `copilot plugin update`, and `copilot plugin uninstall`.

## Start a conversation

Start `copilot` in the directory where you want local Azure SQLOps configuration and state to live. Example Chinese prompts:

```text
登录 fdpo tenant，列出 MI，启动选中的实例
调查这个 MI 最近 24 小时的异常
根据现有证据判断是否需要扩容
基于最新证据生成支持工单草稿
```

`fdpo.onmicrosoft.com` is only an example tenant domain.

## Initial setup

For the first prompt, the agent runs the bundled setup command. Azure CLI opens a browser or device-code flow locally. The agent must never ask for a password, token, refresh token, client secret, or other credential.

Setup:

1. Signs in through Azure CLI.
2. Selects an accessible enabled subscription.
3. Lists Azure SQL Managed Instances in that subscription.
4. Shows the exact selected resource ID.
5. Requires `CONFIGURE <mi-name>` before writing the local allowlist.

When installed as a plugin, local files are placed under the directory where `copilot` was started:

```text
.azure-sqlops/
  config/miops.local.json
  .miops/
    operations/
    evidence/
    support/
    audit.jsonl
```

These files can contain operational metadata. Keep the directory private, review evidence before sharing it, and move audit records to an approved durable store for production use.

## Safety and capability boundaries

The agent can inspect one allowlisted existing MI, collect bounded Azure control-plane evidence, produce capacity guidance, start or stop an eligible MI, inspect or delete an existing start/stop schedule, poll durable operation records, and create a redacted local Support draft.

The agent cannot provision or delete an MI, resize it, fail it over, create or update automatic schedules, execute T-SQL, kill sessions, submit a Microsoft Support request, or claim Azure MCP MI lifecycle support. SQL DMV and Query Store diagnostics are not implemented.

Mutations remain deterministic:

- The backend defaults to dry-run.
- The resource must exactly match `allowedResourceIds`.
- Apply requires `-Apply`, the exact `-ApproveResourceId`, and an exact typed confirmation.
- Lifecycle apply requires `START <mi-name>` or `STOP <mi-name>` after the backend shows the current state and exact resource. Schedule deletion requires `DELETE SCHEDULE <mi-name>`.
- A conversational "yes" or Copilot tool approval cannot bypass those checks.
- Submission is recorded locally and is not called verified until polling observes the desired Azure state.

## Direct PowerShell compatibility

Existing repository users can continue to run:

```powershell
pwsh .\miops.ps1 setup
pwsh .\miops.ps1 interactive
pwsh .\miops.ps1 status
```

The optional `-DataRoot` parameter exists for packaged execution. Omitting it preserves the repository-root config and `.miops` behavior.
