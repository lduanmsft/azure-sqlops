# Optional SQL Diagnostics Adapter

The optional backup-history adapter is implemented but disabled by default. Azure RBAC does not grant SQL data-plane access, so it requires a separate least-privilege Microsoft Entra SQL identity and network connectivity to the Managed Instance.

The runtime exposes only one reviewed template:

```json
{
  "schemaVersion": 1,
  "resourceId": "/subscriptions/.../managedInstances/example-mi",
  "templateIds": ["backup-history-v1"],
  "timeoutSeconds": 30,
  "maxRows": 100
}
```

It should return:

```json
{
  "schemaVersion": 1,
  "collectedAtUtc": "2026-10-08T00:00:00Z",
  "results": [],
  "evidenceGaps": [],
  "redactions": []
}
```

Enforced controls:

- No arbitrary SQL input.
- One fixed, reviewed, read-only query against `msdb.dbo.backupset` and `sys.databases`.
- Minimum documented SQL permissions; no `sysadmin` requirement.
- Query timeout, row limit, database allowlist, and result redaction.
- No secrets or tokens in output/audit.
- Explicit failure when authorization or evidence is unavailable.

Status and optional collection:

```powershell
pwsh .\miops.ps1 sql-adapter-status
pwsh .\miops.ps1 backup-check -UseSqlHistory
```

The adapter calls `sqlcmd -G`; it never accepts passwords, tokens, connection strings, server overrides, or SQL text from the command line/config. The audit records the template ID, authentication mode, server name, timeout, and row limit but not query text or credentials. Missing `sqlcmd`, private network reachability, Microsoft Entra login, or `msdb` read permission becomes an explicit evidence gap.

`msdb` is useful for recent backup transparency. It is not the durable control-plane record and can be incomplete; system database backups are not all logged there. ARM/CLI also does not expose every individual STR full/differential/log backup event.
