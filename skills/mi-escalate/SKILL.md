---
name: mi-escalate
description: Draft and explicitly authorize redacted Microsoft Azure Support requests for Managed Instance incidents.
metadata:
  status: proposed
---

# Skill: MI Escalate

> **Status:** Proposed specification. Not implemented or tenant validated. Ticket drafting and ticket creation are distinct authorization steps.

## Purpose

Create a high-quality, redacted Microsoft Azure Support request draft from operational evidence and, when all prerequisites and explicit authorization are satisfied, submit it through the Azure Support API.

## Allowed outcomes

- Assess whether support ticket creation prerequisites are available.
- Draft a structured support request.
- Redact and preview the exact outbound payload.
- Request explicit per-ticket authorization.
- Create one authorized support request and return its verified identifier.

## Prohibited outcomes

- Create a ticket based only on permission to troubleshoot or draft.
- Select unsupported entitlement/severity values.
- Submit secrets, credentials, raw customer data, or unrestricted diagnostic dumps.
- Fabricate a ticket number when API submission or verification fails.
- Repeatedly create tickets for the same incident.

## Preconditions

- Canonical subscription and MI resource ID.
- Authenticated caller with the support-requester role.
- Incident summary, business impact, timeline, and troubleshooting evidence.
- Support provider/API readiness and eligible support plan established.
- Required Azure authorization established.
- Duplicate search/idempotency check completed.

If prerequisites cannot be established, produce a draft and clearly state why creation is unavailable.

## Draft contents

- A concise title.
- Affected subscription, resource ID, region, and service.
- UTC incident timeline.
- Current and peak impact.
- Observed facts and evidence sources.
- Troubleshooting already performed.
- Material recent changes.
- Requested assistance.
- Contact information from an approved profile.
- Proposed severity within policy.
- Attachments or summaries after redaction.

Separate facts from hypotheses. Avoid asserting root cause unless confirmed.

## Authorization ceremony

Before creation, show:

- Exact destination and subscription.
- Exact title, description, severity, contact, and attachment list.
- Redactions performed.
- Entitlement/prerequisite result.
- Duplicate check result.

Obtain authorization bound to the payload hash, subscription, resource, and expiration. Any material payload change invalidates approval.

## Submission workflow

1. Persist draft, payload hash, and idempotency key.
2. Persist prerequisite and policy decisions.
3. Obtain and persist exact authorization.
4. Submit through a typed Azure Support adapter.
5. Persist API request/correlation identifiers.
6. Verify the support request exists and retrieve its identifier/state.
7. Record a redacted audit event.
8. Return the verified ticket identifier or explicit failure/unknown state.

## Deduplication

Deduplicate on incident ID, affected resource, symptom class, and active time window. If a matching open request exists, present it and require a deliberate decision before any new request. API ambiguity must be reconciled before retry.

## Output states

- `Drafted`: payload prepared but not authorized.
- `Blocked`: entitlement, permission, policy, or required data missing.
- `AwaitingApproval`: final payload displayed.
- `Submitted`: API accepted; verification pending.
- `Created`: ticket identifier independently verified.
- `Failed`: terminal failure with sanitized reason.
- `Unknown`: submission outcome cannot yet be reconciled.

Only `Created` may be described as a created support ticket.
