---
name: mi-escalate
description: Generate a redacted local Microsoft Support case draft from an Azure evidence bundle without submitting a ticket.
metadata:
  status: implemented-draft-only-not-tenant-validated
---

# MI Escalate

Use the runtime resolution procedure in `../azure-sqlops/SKILL.md`. Set absolute `$miops` and `$dataRoot` paths; never assume the current directory is the repository.

First collect evidence, then generate a draft:

```powershell
pwsh -NoProfile -File $miops evidence -DataRoot $dataRoot -LookbackHours 24

pwsh -NoProfile -File $miops support-draft -DataRoot $dataRoot `
  -EvidencePath '.miops\evidence\evidence-<timestamp>.json' `
  -Title 'Azure SQL MI incident' `
  -Impact 'Describe verified business impact without secrets or customer data.'
```

Review the JSON under `.miops\support` before sharing. The command redacts common secret fields and token patterns, but human review remains required.

Phase 1 does not submit Microsoft Support requests. Do not call Support REST APIs, fabricate a ticket ID, or imply entitlement. Not all support plans/tenants permit API case creation.

A future submission adapter must validate support-plan and tenant entitlement, `Microsoft.Support` readiness, authorization, severity policy, duplicate cases, and exact final payload approval before it can return a verified case ID.
