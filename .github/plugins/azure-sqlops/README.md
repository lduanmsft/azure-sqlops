# Azure SQLOps Copilot CLI plugin

This plugin packages the repository's agent skills and deterministic PowerShell runtime. It lists read-only Azure resource metadata in the validated selected/current subscription and operates one explicitly allowlisted existing Azure SQL Managed Instance. Authentication remains in the local Azure CLI.

Examples: `列出所有资源`, `列出所有 VM`, and `列出所有 MI`. Inventory uses only the closed selectors `all`, `vm`, and `mi`; listing never allowlists a resource for mutation.

The plugin does not provision, delete, resize, fail over, perform VM actions, run arbitrary Azure CLI commands, run T-SQL, submit Support cases, or provide Azure MCP lifecycle operations. Start, stop, and schedule deletion remain dry-run by default and require the backend's exact approval parameters. Conversational approval alone is never sufficient.

See the [plugin user guide](../../../docs/copilot-cli-plugin.md) in the source repository.
