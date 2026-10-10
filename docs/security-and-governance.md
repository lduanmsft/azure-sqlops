# Security and Governance

> **Status:** Core local safeguards are implemented and tested. Azure RBAC design, tenant behavior, workstation hardening, and enterprise audit controls require deployment-specific validation.

## Enforced locally

- Exact MI resource-ID allowlist.
- Independent exact restore-target resource-ID allowlist.
- Default read-only/dry-run behavior.
- `-Apply` plus exact `-ApproveResourceId` for mutations.
- Fixed Azure CLI command shapes rather than arbitrary shell input.
- Local persistence before and after lifecycle submission.
- Local persistence before PITR submission plus destination-state verification.
- Local persistence before LTR submission plus exact normalized policy read-back.
- Default LTR no-weakening policy with a separate switch and stronger `REDUCE LTR` confirmation.
- Explicit `Submitted`, `InProgress`, `Verified`, and `Failed` distinctions.
- Structured redaction for sensitive property names and bearer/token-like text.
- Local JSONL audit records.
- Optional fixed read-only `backup-history-v1` SQL execution only; disabled by default.
- No Support API submission.

These controls supplement rather than replace Azure RBAC, policy, locks, and operational change management.

## Azure identity

Use a dedicated operator identity with the narrowest practical scope. Read-only evidence requires Azure resource and monitoring permissions. Start/stop and schedule deletion require additional control-plane actions. Preflight proves only what it can observe; lifecycle write permission is conclusively tested only by an approved operation.

`miops.ps1 setup` uses Azure CLI interactive browser login or explicit device-code login for a tenant domain/GUID. The operator completes authentication locally. Do not store Azure tokens, client secrets, connection strings, passwords, or other credentials in config. Subscription IDs and tenant IDs are identifiers, not credentials. The ignored local config may retain those identifiers as onboarding metadata.

Neither browser nor device-code login bypasses Conditional Access or device-compliance policy. Operators must use an organization-approved managed device or contact the tenant administrator when policy blocks Azure CLI authentication.

## SQL authorization

Azure RBAC does not grant SQL data-plane access. The optional adapter uses `sqlcmd -G`, one fixed reviewed `msdb` query, timeout, and row limit. Use a separate least-privilege Microsoft Entra SQL identity with only the required metadata/history read permission. Avoid `sysadmin`, `db_owner`, passwords/tokens in config, arbitrary SQL, and unrestricted result sets.

## Resource allowlist and confirmation

The checked-in example contains a placeholder resource. Operators create ignored `config/miops.local.json` with one exact MI resource ID in both `resource.id` and `allowedResourceIds`.

Restore targets are separate in `restoreTargets.allowedResourceIds`. A listed, discovered, or source-allowlisted MI never becomes a target automatically. Adding one requires an exact Azure-read resource ID plus `CONFIGURE RESTORE TARGET <mi-name>`.

Mutating commands reject:

- Resources outside the allowlist.
- Prefix/partial resource matches.
- Missing `-Apply`.
- Missing or non-exact `-ApproveResourceId`.
- Locally unsupported lifecycle tier/configuration.

Restore apply additionally rejects:

- Source outside `resource.allowedResourceIds`.
- Target outside `restoreTargets.allowedResourceIds`.
- Missing or mismatched source/target resource approvals.
- A phrase other than `RESTORE <source-db> TO <target-mi>/<target-db> AT <timestamp>`.
- System or unsafe database names, future/non-UTC timestamps, pre-earliest restore points, existing destinations, unavailable instances, region mismatch, or verifiable tenant mismatch.

Azure still enforces supported cross-subscription types, primary-instance/primary-region rules, source backup availability, BYOK, service endpoint policies, capacity, locks, and permissions.

LTR apply additionally rejects:

- A source MI outside `resource.allowedResourceIds`.
- A missing, system, unsafe, or non-exact database inventory match.
- Bare numbers, arbitrary/compound ISO-8601 durations, shell/JMESPath fragments, time components, fractions, zero/negative values, values below 7 days, or values above 10 years.
- Yearly retention without week 1-52, or a nonzero week while yearly retention is disabled.
- An all-disabled policy.
- Missing `-Apply`, mismatched `-ApproveResourceId`, or a phrase other than the full normalized `SET LTR ...`.
- Retention reduction or dimension removal without both `-AllowRetentionReduction` and the full `REDUCE LTR ...` phrase.

The runtime calls only the reviewed `az sql midb ltr-policy set` shape, explicitly supplies all three retention dimensions, persists a redacted record before submission, and independently reads the policy afterward. No delete/reset/clear command exists, and a successful CLI exit is not labeled verified without an exact match.

The interactive menu additionally requires a case-sensitive `START <mi-name>` or `STOP <mi-name>` phrase after showing the exact name, resource ID, and observed state. Selecting a menu number never adds `-Apply`.

## Audit and state

`.miops/audit.jsonl` records timestamps, event names, resource/action context, state transitions, and sanitized errors. `.miops/operations` stores operation progress.

The redactor removes values under common secret property names and token-like strings, but it is not a substitute for data classification. Review bundles before sharing. Local files are mutable and should be exported to an approved immutable sink for production governance.

## Evidence minimization

Phase 1 collects control-plane configuration, database/retention metadata, restorable-deleted evidence, LTR records where applicable, Activity Log, Resource Health, and configured metrics. Optional SQL backup history collects database names and latest backup timestamps only. It does not collect customer rows or arbitrary query text. Missing sources are listed explicitly.

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

Longer LTR retention can increase backup storage charges. Policy changes apply to future retained backups, while existing backups retain their assigned expiration and are not necessarily deleted immediately. Operators remain responsible for compliance validation, recovery drills, failover policy parity, and the current Managed Instance limitation that LTR backups cannot be configured as immutable.

## Known limitations

- One workstation/local state store; no distributed lock.
- No protection against two independent hosts applying actions simultaneously.
- No cryptographic audit signing.
- No background reconciliation service.
- Redaction is rule-based and requires human review for outbound sharing.
- Conservative eligibility rules can block newly supported configurations until config/policy is reviewed.
- Cross-subscription subscription-type eligibility is reported as an Azure-side constraint because Azure CLI account metadata does not provide a stable authoritative type field for all clouds.
- No tenant execution evidence is included.
