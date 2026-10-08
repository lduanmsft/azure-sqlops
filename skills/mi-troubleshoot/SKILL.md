---
name: mi-troubleshoot
description: Collect and interpret read-only Azure control-plane, Activity Log, Resource Health, and Monitor evidence for one allowlisted Managed Instance.
metadata:
  status: implemented-evidence-not-tenant-validated
---

# MI Troubleshoot

Run:

```powershell
pwsh .\miops.ps1 preflight
pwsh .\miops.ps1 status
pwsh .\miops.ps1 evidence -LookbackHours 24
```

Use another window only between 1 and 168 hours. Build a UTC timeline from the returned bundle. For each hypothesis provide supporting evidence, contradicting evidence, missing evidence, confidence, and a safe next diagnostic step.

This skill is read-only. Do not start/stop the MI, resize, modify configuration, execute T-SQL, kill sessions, or claim resolution.

SQL DMVs and Query Store are an optional future adapter. Check the boundary with:

```powershell
pwsh .\miops.ps1 sql-adapter-status
```

Never fabricate SQL evidence or treat its absence as proof of health. Explicitly report access, retention, provider, unsupported-configuration, and metric gaps.
