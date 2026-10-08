# Optional SQL Diagnostics Adapter

Phase 1 does not implement or require this adapter. Azure RBAC does not grant SQL DMV or Query Store access, so SQL diagnostics must use a separate least-privilege SQL identity.

A future adapter should accept a versioned request:

```json
{
  "schemaVersion": 1,
  "resourceId": "/subscriptions/.../managedInstances/example-mi",
  "database": "optional-approved-database",
  "templateIds": ["approved-read-only-template"],
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

Required controls:

- No arbitrary SQL input.
- Reviewed, parameterized, read-only query templates only.
- Minimum documented SQL permissions; no `sysadmin` requirement.
- Query timeout, row limit, database allowlist, and result redaction.
- No secrets or tokens in output/audit.
- Explicit failure when authorization or evidence is unavailable.

The current command reports the boundary without executing SQL:

```powershell
pwsh .\miops.ps1 sql-adapter-status
```
