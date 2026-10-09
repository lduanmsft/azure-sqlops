# Azure SQLOps Copilot CLI plugin

This plugin packages the repository's agent skills and deterministic PowerShell runtime. It operates one explicitly allowlisted existing Azure SQL Managed Instance and keeps authentication in the local Azure CLI.

The plugin does not provision, delete, resize, fail over, run T-SQL, submit Support cases, or provide Azure MCP lifecycle operations. Start, stop, and schedule deletion remain dry-run by default and require the backend's exact approval parameters. Conversational approval alone is never sufficient.

See the [plugin user guide](../../../docs/copilot-cli-plugin.md) in the source repository.
