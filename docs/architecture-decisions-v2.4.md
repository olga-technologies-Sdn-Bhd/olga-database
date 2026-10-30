# OLGA Connect Database v2.4 Auditability Decisions

## Actor attribution

Every table that exposes `row_version` now has database-managed `created_by` and `updated_by`
columns. The API must start a transaction and set the trusted request actor before executing DML:

```sql
-- Execute with parameterized Npgsql values inside the mutation transaction.
SELECT ops.set_audit_context($1); -- member, administrator, service, or system ID
```

The trigger ignores audit identities supplied in insert/update payloads. When no actor context is
set, the database login is captured. Existing rows upgraded from an earlier schema use
`legacy_unknown`; this avoids inventing historical attribution.

Actor columns are polymorphic and deliberately do not reference `iam.member`: background services
and system maintenance must be representable without fake member rows. Domain-specific evidence
such as `granted_by`, `approved_by`, `sender_member_id`, and `actor_member_id` remains unchanged.

## Lifecycle controls

`iam.member_identity`, `iam.role`, and `event.venue` now have explicit active/retired or
active/revoked states because these reusable records previously could not be disabled safely.
Existing lifecycle mechanisms (`status`, `retired_at`, `revoked_at`, `removed_at`, `ended_on`,
`deleted_at`, and effective date ranges) remain authoritative elsewhere; a redundant generic
`is_enabled` flag is not added.

The prior member/profile checks were also aligned with their documented `ANONYMIZED` and
`PENDING_REVIEW` states.

## System-period history

Version 2.4 uses an OLGA-owned system-period trigger for these low-volume, audit-sensitive
reference and policy tables:

- `iam.permission`, `iam.role`, `core.sector`
- `consent.consent_policy`
- `event.venue`, `event.event_matching_policy`
- `notification.notification_policy`
- `nlp.nlp_model_version`, `nlp.nlp_ranking_config`
- `moderation.content_rule`, `ops.retention_policy`

Each current row has a `sys_period tstzrange`; previous versions are written to a matching table in
the `history` schema. The `_all` views union current and historical versions. Point-in-time reads use
the range operator, for example:

```sql
SELECT *
FROM history.iam_role_all
WHERE role_code = 'MODERATOR'
  AND sys_period @> TIMESTAMPTZ '2026-09-01 00:00:00+00';
```

PostgreSQL does not provide Azure SQL's `FOR SYSTEM_TIME` query syntax. The
`ops.archive_row_version` trigger implements the required system-period behavior and runs with the
migration owner, while only the admin reader receives history access. Using an owned trigger avoids
altering Azure-managed extension functions and avoids granting runtime roles direct history-table
writes. Its timestamp comes only from `transaction_timestamp()`, so callers cannot spoof it.

Full-row temporal history is intentionally not enabled for profiles, messages, identity ciphertext,
files, presence, or transient processing tables. Copying that data would increase breach impact and
could conflict with deletion, anonymization, and retention requirements. Sensitive actions continue
to emit append-only `ops.audit_event` records without content.

Production must define reviewed retention periods for history tables and include them in privacy
deletion/anonymization workflows before accumulating long-lived data.

## Matching and Live Mode boundary hardening

The eligibility projection carries `community_id`, and candidate retrieval requires the requester
and candidate to share that authoritative boundary. The requester must independently pass the same
active-state, visibility, consent, context, and Live Mode checks as every candidate.

Active match suppressions use conjunctive optional dimensions: each populated member, intent, and
context target must match, while an omitted dimension acts as a wildcard. Intent-only suppressions
apply to both the requester intent and candidate intent. Combined suppression targets are rejected
when the referenced intent belongs to a different member or context.

An active Live Mode session is accepted only for an active same-community event and must expire no
later than that event. Its consent record must be the same member's latest effective, unwithdrawn
`LIVE_MODE` grant. Eligibility re-evaluates this consent on every read so a newer denial or
withdrawal removes discovery capability immediately.

Matching functions accept embeddings only when their normalized hash, dimensions, active model,
and preprocessing version still agree with the current intent.

## Atomic chat mutations and participant integrity

Connection acceptance, message creation, and receipt updates require an `Idempotency-Key`, a
canonical request hash, and policy-derived expiry timestamps. Each controlled function claims the
key within the same transaction as its business rows, transactional outbox event, member-scoped
`ops.sync_change` rows, and cached result. The idempotency primary key includes operation scope,
authenticated actor, and client key; a replay with the same hash returns the existing result while
a different hash fails with a uniqueness conflict.

Direct runtime mutation of connections, conversations, participants, messages, and receipts is
revoked where a controlled workflow owns creation. Deferred constraint triggers verify at commit
that every conversation contains exactly the two members of its accepted connection. Immediate
triggers reject foreign-conversation read cursors, backward cursor movement, sender receipts,
nonparticipant receipts, and changes to established delivery/read timestamps.

The API must calculate request hashes from canonical versioned payloads, pass retention-approved
idempotency and sync expiry timestamps, and map SQLSTATE `23505` to an idempotency conflict and
`55P03` to a retryable operation-in-progress response.
