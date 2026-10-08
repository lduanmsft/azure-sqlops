# Security and Governance

> **Status:** Core local safeguards are implemented and tested. Azure RBAC design, tenant behavior, workstation hardening, and enterprise audit controls require deployment-specific validation.

## Enforced locally

- Exact MI resource-ID allowlist.
- Default read-only/dry-run behavior.
- `-Apply` plus exact `-ApproveResourceId` for mutations.
- Fixed Azure CLI command shapes rather than arbitrary shell input.
- Local persistence before and after lifecycle submission.
- Explicit `Submitted`, `InProgress`, `Verified`, and `Failed` distinctions.
- Structured redaction for sensitive property names and bearer/token-like text.
- Local JSONL audit records.
- No SQL command execution.
- No Support API submission.

These controls supplement rather than replace Azure RBAC, policy, locks, and operational change management.

## Azure identity

Use a dedicated operator identity with the narrowest practical scope. Read-only evidence requires Azure resource and monitoring permissions. Start/stop and schedule deletion require additional control-plane actions. Preflight proves only what it can observe; lifecycle write permission is conclusively tested only by an approved operation.

`miops.ps1 setup` uses Azure CLI interactive browser login or explicit device-code login for a tenant domain/GUID. The operator completes authentication locally. Do not store Azure tokens, client secrets, connection strings, passwords, or other credentials in config. Subscription IDs and tenant IDs are identifiers, not credentials. The ignored local config may retain those identifiers as onboarding metadata.

Neither browser nor device-code login bypasses Conditional Access or device-compliance policy. Operators must use an organization-approved managed device or contact the tenant administrator when policy blocks Azure CLI authentication.

## SQL authorization

Azure RBAC does not grant SQL DMV/Query Store access. A future adapter must use a separate least-privilege SQL identity and reviewed read-only queries. Avoid `sysadmin`, `db_owner`, arbitrary generated SQL, and unrestricted result sets.

## Resource allowlist and confirmation

The checked-in example contains a placeholder resource. Operators create ignored `config/miops.local.json` with one exact MI resource ID in both `resource.id` and `allowedResourceIds`.

Mutating commands reject:

- Resources outside the allowlist.
- Prefix/partial resource matches.
- Missing `-Apply`.
- Missing or non-exact `-ApproveResourceId`.
- Locally unsupported lifecycle tier/configuration.

The interactive menu additionally requires a case-sensitive `START <mi-name>` or `STOP <mi-name>` phrase after showing the exact name, resource ID, and observed state. Selecting a menu number never adds `-Apply`.

## Audit and state

`.miops/audit.jsonl` records timestamps, event names, resource/action context, state transitions, and sanitized errors. `.miops/operations` stores operation progress.

The redactor removes values under common secret property names and token-like strings, but it is not a substitute for data classification. Review bundles before sharing. Local files are mutable and should be exported to an approved immutable sink for production governance.

## Evidence minimization

Phase 1 collects control-plane configuration, Activity Log, Resource Health, and configured metrics. It does not collect SQL query text or customer data. Missing sources are listed explicitly.

Evidence and drafts may still contain resource names, subscription IDs, actor identifiers, and operational metadata. Apply organization retention, access, and sharing policies.

## Schedule governance

The tool does not create/update automatic stop schedules. It can inspect them and, after exact confirmation, delete an existing schedule to disable automation. Any future schedule-enabling feature must add timezone, exception, missed-window, owner, expiration, approval, and budget controls.

## Support governance

Support drafting is local only. Before any future REST submission:

- Validate support plan and tenant entitlement.
- Validate `Microsoft.Support` registration/API availability.
- Validate caller authorization and severity constraints.
- Show the final redacted payload.
- Bind approval to a payload hash and expiration.
- Deduplicate against open cases.
- Verify the returned case identifier.

Not all Microsoft Support plans or tenants permit the same API operations.

## Cost and budget governance

Open-source code does not eliminate service cost. Establish budgets for Copilot/model use, MI uptime, metrics/log retention and queries, storage/networking, and Support. Phase 1 has no automatic cost enforcement; Azure Cost Management and organizational controls remain necessary.

## Known limitations

- One workstation/local state store; no distributed lock.
- No protection against two independent hosts applying actions simultaneously.
- No cryptographic audit signing.
- No background reconciliation service.
- Redaction is rule-based and requires human review for outbound sharing.
- Conservative eligibility rules can block newly supported configurations until config/policy is reviewed.
- No tenant execution evidence is included.
