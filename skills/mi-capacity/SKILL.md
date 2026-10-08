---
name: mi-capacity
description: Analyze Azure SQL Managed Instance capacity evidence and produce non-executable resize recommendations.
metadata:
  status: proposed
---

# Skill: MI Capacity

> **Status:** Proposed specification. Not implemented or tenant validated. This skill recommends but never resizes in the MVP.

## Purpose

Produce an evidence-based Azure SQL Managed Instance capacity assessment and candidate resize recommendation for human review.

## Allowed outcomes

- Summarize current configuration and available utilization evidence.
- Identify sustained pressure, growth risk, imbalance, or overprovisioning.
- Recommend no change, further observation, or a candidate resize.
- Estimate expected benefit and list tradeoffs, assumptions, and risks.
- Define a post-change verification plan.

## Prohibited outcomes

- Submit or schedule a resize.
- Guarantee performance, availability, or cost.
- Infer SQL DMV evidence from Azure RBAC.
- Recommend from a single transient spike without clearly labeling low confidence.
- Hide missing evidence or unsupported metric interpretations.

## Evidence inputs

Use available, approved sources for a defined analysis window:

- Current MI service tier, hardware generation, vCores, storage, zone/HA configuration, and relevant limits.
- Azure Monitor CPU, storage, I/O, and other supported MI metrics.
- Workload trend, peak duration, seasonality, and incident windows.
- Approved SQL DMV/catalog evidence through a separate read-only SQL identity.
- Storage growth and forecast.
- Recent configuration or deployment changes.
- Cost information only when an approved source is configured.

Metric names and availability may vary. The collector must record the actual source, aggregation, and time range rather than assume a universal metric set.

## Analysis procedure

1. Validate resource allowlist and evidence window.
2. Capture current configuration and limits.
3. Assess data completeness and freshness.
4. Separate sustained utilization from spikes and incident anomalies.
5. Correlate Azure and SQL evidence where both are available.
6. Identify the constrained dimension: compute, memory, data I/O, log I/O, storage, concurrency, or unknown.
7. Consider non-capacity explanations before recommending resize.
8. Compare candidate configurations and operational constraints.
9. Assign confidence based on evidence coverage and consistency.
10. Produce a recommendation for human review only.

## Recommendation format

- **Observed facts:** sourced evidence with timestamps.
- **Interpretation:** causal or capacity hypothesis.
- **Evidence gaps:** missing metrics, SQL access, or workload context.
- **Recommendation:** no change, observe, optimize, scale up/down, or investigate further.
- **Candidate target:** exact configuration only when supported by current Azure inventory/validation.
- **Expected benefit:** dimension expected to improve.
- **Risks and tradeoffs:** cost, downtime/operation duration, limits, and rollback considerations.
- **Confidence:** low, medium, or high with rationale.
- **Review/approval:** required roles and change process.
- **Verification plan:** metrics and time window after a human-executed change.

## Safety checks

- Suppress resize targets not verified as valid for the specific MI.
- Flag recommendations that conflict with redundancy, licensing, storage, or policy constraints.
- State that resize is a long-running operation requiring durable tracking if later automated.
- Redact query text, object names, and result values unless specifically approved.
- Apply evidence-age and analysis-cost budgets.

## MVP terminal behavior

The skill ends after producing a reviewable recommendation artifact. If the operator requests execution, respond that automatic resize is outside MVP scope and route the request to the established human change process.
