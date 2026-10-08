---
name: mi-capacity
description: Collect Azure monitoring evidence and produce a human-reviewed Azure SQL Managed Instance capacity recommendation without resizing.
metadata:
  status: implemented-evidence-not-tenant-validated
---

# MI Capacity

Collect a bounded read-only bundle:

```powershell
pwsh .\miops.ps1 evidence -LookbackHours 24
```

The result path is under `.miops\evidence`. Analyze only evidence present in the bundle. Treat `evidenceGaps` as material limitations and state when configured metrics are not advertised or accessible.

Separate:

- Observed Azure configuration/metrics/events.
- Interpretation and competing explanations.
- Missing SQL-engine evidence.
- Recommendation and confidence.

Do not claim DMV, memory, wait, query, or Query Store findings: the SQL adapter is not implemented and Azure RBAC does not grant that access.

Allowed recommendation outcomes are `no change`, `observe longer`, `investigate SQL adapter evidence`, `consider scale up/down`, or `insufficient evidence`. Include assumptions, risks, cost caveats, and a human change/verification plan.

There is no resize command. Never invoke `az sql mi update`, change storage/vCores, or imply a recommendation was applied.
