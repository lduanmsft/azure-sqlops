# 0001: Use Local Copilot CLI and Azure CLI for Phase 1

- **Status:** Accepted and implemented
- **Date:** 2026-10-08
- **Tenant validation:** Not performed

## Decision

Implement phase 1 as a lightweight local toolkit using:

- GitHub Copilot CLI for operator interaction and skill guidance.
- Public/open-source `SKILL.md` definitions.
- PowerShell 7 for deterministic safety and workflow logic.
- Azure CLI and ARM-backed command groups for MI and monitoring access.
- Local JSON configuration, operation state, evidence, support drafts, and audit.

Azure SRE Agent is not an MVP architecture component, dependency, procurement prerequisite, or validation requirement. It remains an optional future migration path.

## Why

- MI lifecycle management is available through `az sql mi`/ARM and is not currently exposed by Azure SQL MCP.
- A small PowerShell surface is inspectable, cross-platform, and compatible with Azure CLI.
- Local durable files are sufficient for phase-1 restart recovery without introducing a heavy service framework.
- Safety logic remains outside model-generated prose.
- The approach can be validated incrementally against one approved MI.

## Cost clarification

The repository and public skill code can be free/open source. The whole solution is not guaranteed to be free: GitHub Copilot/model access, Azure SQL MI, Azure Monitor/Log Analytics, storage/networking, and Microsoft Support plans may incur charges.

## Consequences

### Positive

- No paid Azure SRE Agent dependency.
- Minimal bootstrap and no application server.
- Exact control over allowlists, confirmation, state, audit, and redaction.
- Easy local inspection and modification.

### Negative

- The operator owns workstation security, availability, upgrades, and state backup.
- Local JSON is not distributed or highly available.
- Tenant identity and permissions are not provisioned automatically.
- Copilot and Azure service charges remain possible.
- SQL and Support integrations require separate future adapters.

## Azure SRE Agent migration path

Reconsider a migration only if the managed platform demonstrates:

- Required MI lifecycle and monitoring integrations.
- Exact approval/allowlist semantics.
- Durable long-running operation recovery.
- Separate SQL authorization.
- Support entitlement controls.
- Audit/redaction/data-boundary compliance.
- Acceptable availability, region support, and cost.

Migration should preserve the command intent, skill boundaries, evidence shape, and safety tests rather than making Azure SRE Agent a prerequisite.
