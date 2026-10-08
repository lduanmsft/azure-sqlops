---
name: mi-troubleshoot
description: Perform bounded read-only troubleshooting for Azure SQL Managed Instance incidents.
metadata:
  status: proposed
---

# Skill: MI Troubleshoot

> **Status:** Proposed specification. Not implemented or tenant validated. All tool activity is read-only.

## Purpose

Investigate Azure SQL Managed Instance availability or performance symptoms by collecting bounded Azure and SQL evidence and producing ranked, evidence-linked hypotheses.

## Allowed outcomes

- Establish incident scope and timeline.
- Collect approved Azure configuration, activity, health, metric, and alert evidence.
- Execute reviewed read-only SQL diagnostic templates when separately authorized.
- Correlate evidence and identify likely causes or next diagnostic steps.
- Recommend reversible operator actions or escalation.

## Prohibited outcomes

- Execute arbitrary SQL.
- Modify data, schema, configuration, sessions, jobs, or indexes.
- Start, stop, resize, fail over, or otherwise remediate the MI.
- Claim root cause without supporting evidence.
- Treat unavailable DMV access as evidence that the database is healthy.

## Required inputs

- Canonical allowlisted MI resource ID.
- Symptom and user-visible impact.
- Incident start/end or investigation window.
- Correlation/request ID.
- Optional database scope, sanitized identifiers, and known changes.

## Evidence collection order

1. Confirm resource identity and current Azure state.
2. Read recent resource configuration changes and Azure Activity Log.
3. Read Resource Health and relevant service/maintenance context.
4. Read supported Azure Monitor metrics for the incident and baseline windows.
5. Read alert history and configured thresholds when available.
6. If SQL access is configured, run only applicable reviewed query templates.
7. Normalize timestamps and compare incident evidence with baseline.

## SQL access boundary

Azure RBAC does not provide SQL DMV access. The SQL collector must authenticate separately and:

- Use a dedicated least-privilege principal.
- Execute only versioned template IDs.
- Parameterize database/time filters.
- Enforce timeout and row limits.
- Reject DDL, DML, dynamic arbitrary SQL, and multi-statement input.
- Redact sensitive columns before results reach the model.

## Diagnostic method

For each hypothesis, return:

- Statement of the hypothesis.
- Supporting evidence and source timestamps.
- Contradicting evidence.
- Missing evidence.
- Confidence level.
- Safe next validation step.

Examples of hypothesis categories include control-plane operation, service health, resource saturation, blocking/concurrency, query regression, storage pressure, connectivity, authentication, or insufficient evidence. Category presence does not imply a finding.

## Output

- Incident summary and evidence window.
- Current observed state.
- Timeline of material events.
- Ranked hypotheses with confidence.
- Confirmed facts versus inference.
- Evidence gaps and permission limitations.
- Recommended next steps.
- Escalation package inputs when unresolved.

Never say an incident is resolved based only on metric recovery; resolution confirmation belongs to the operator or monitoring process.
