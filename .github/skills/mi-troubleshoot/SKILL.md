---
name: mi-troubleshoot
description: Collect and interpret read-only Azure control-plane, Activity Log, Resource Health, and Monitor evidence for one allowlisted Managed Instance.
metadata:
  status: implemented-evidence-not-tenant-validated
---

# MI Troubleshoot

Use the repository-root runtime resolution procedure in `../azure-sqlops/SKILL.md`. Set validated absolute `$miops` and `$dataRoot` paths; never assume the current directory is the repository root.

Run:

```powershell
pwsh -NoProfile -File $miops preflight -DataRoot $dataRoot
pwsh -NoProfile -File $miops status -DataRoot $dataRoot
pwsh -NoProfile -File $miops evidence -DataRoot $dataRoot -LookbackHours 24
```

Use another window only between 1 and 168 hours. Build a UTC timeline from the returned bundle. For each hypothesis provide supporting evidence, contradicting evidence, missing evidence, confidence, and a safe next diagnostic step.

This skill is read-only. Do not start/stop the MI, resize, modify configuration, execute T-SQL, kill sessions, or claim resolution.

General SQL DMVs and Query Store remain outside this skill. The implemented optional SQL adapter is limited to the fixed backup-history query used by `backup-check`. Check the boundary with:

```powershell
pwsh -NoProfile -File $miops sql-adapter-status -DataRoot $dataRoot
```

Never generalize backup-history timestamps into query, wait, capacity, or incident evidence, fabricate SQL evidence, or treat its absence as proof of health. Explicitly report access, retention, provider, unsupported-configuration, and metric gaps.
