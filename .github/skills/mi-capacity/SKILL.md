---
name: mi-capacity
description: Collect Azure monitoring evidence and produce a human-reviewed Azure SQL Managed Instance capacity recommendation without resizing.
metadata:
  status: implemented-evidence-not-tenant-validated
---

# MI Capacity

Use the repository-root runtime resolution procedure in `../azure-sqlops/SKILL.md`. Set validated absolute `$miops` and `$dataRoot` paths; never assume the current directory is the repository root.

Collect a bounded read-only bundle:

```powershell
pwsh -NoProfile -File $miops evidence -DataRoot $dataRoot -LookbackHours 24
```

The result path is under `.miops\evidence`. Analyze only evidence present in the bundle. Treat `evidenceGaps` as material limitations and state when configured metrics are not advertised or accessible.

Separate:

- Observed Azure configuration/metrics/events.
- Interpretation and competing explanations.
- Missing SQL-engine evidence.
- Recommendation and confidence.

Do not claim DMV, memory, wait, query, or Query Store findings. The only implemented SQL adapter is the fixed backup-history query for `backup-check`; it provides no capacity evidence, and Azure RBAC does not grant SQL data-plane access.

Allowed recommendation outcomes are `no change`, `observe longer`, `investigate SQL adapter evidence`, `consider scale up/down`, or `insufficient evidence`. Include assumptions, risks, cost caveats, and a human change/verification plan.

There is no resize command. Never invoke `az sql mi update`, change storage/vCores, or imply a recommendation was applied.
