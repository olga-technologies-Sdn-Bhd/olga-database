# Social Capital Index application integration context

## Database contract

Schema v2.9 adds the SCI domain without changing the existing service topology.

- Core owns `core.venture`, the imported-contact vault, invitations, connections/consent,
  meeting confirmations, SCI rollups, member-visible reads, and notifications.
- NLP owns versioned venture intent sets, calibration/configuration, scoring jobs, and
  per-link/per-venture scores.
- The NLP worker cannot read imported identifiers or encrypted labels. It receives eligible
  member/intent vectors only through `nlp.get_sci_scoring_candidates`.
- Core enqueues work transactionally through `nlp.enqueue_sci_scoring_job`.
- NLP persists a score through `nlp.apply_sci_link_score`, which applies qualification capping,
  the 10/7 two-strike hysteresis, encounter permanence, link history, and a
  `SciLinkScoreChanged.v1` outbox event atomically.
- `SCI_GLOBAL_V1` is installed as `DRAFT`. Do not score until a reviewed calibration exists and
  the config is explicitly activated.

## Core API changes

Use the existing Minimal API -> application service -> repository -> EF Core/Npgsql layering.

Implemented `/v1` resources in `Olga.Core`:

- `POST /v1/ventures`
- `POST /v1/contacts/imports` (1-500 contacts per request; raw identifiers are discarded)
- `POST /v1/invite-batches` (1-20 links)
- `POST /v1/invitations/{token}/accept` (reuses the existing connection acceptance function)
- `GET /v1/ventures/{ventureId}/sci` (owner-scoped opaque cursor)

Implemented in `Olga.Nlp`:

- `POST /v1/venture-intent-sets`, with the `IntentSetId` equal to `Idempotency-Key`
- the existing intent/embedding pipeline for the paired OFFER and WANT intents
- a PostgreSQL-polled SCI scoring worker using bounded exact-cosine candidates

Still follow-up API work, not required to start the pilot scoring loop: venture edit/list,
repository-before-SCI list, invite-open telemetry, two-sided meeting confirmation, and admin
calibration endpoints. Until the admin endpoints exist, calibration activation is a controlled
manual database release step.

Every mutation requires `Idempotency-Key`. Updates require `If-Match` based on `row_version`.
Do not expose identifier hashes, ciphertext, vectors, raw fit, calibration internals, scores below
10, or another owner's link state.

Core should call `nlp.enqueue_sci_scoring_job` in the same transaction as changes that affect SCI:

- venture intent activation
- invitation acceptance/connection consent
- contact intent activation
- new venture creation
- qualification or geography change
- account block/deletion or contact removal

Use a dedupe key composed from owner, venture, relevant intent versions, and scorer version. This
makes rapid wording edits collapse safely without relying on timing alone.

The Core worker includes a handler for `SciLinkScoreChanged.v1` that refreshes affected
`social.sci_rollup` rows, writes member sync changes, and applies the notification relevance gate.
Leaving the SCI is silent; role changes are digest-only; entry and Strong/Exact promotion follow
the approved notification policy.

## NLP changes

Venture intent sets and SCI jobs are separate from event/live matching; venture intents are not
routed through `nlp.get_eligible_candidates`.

The implemented repository/worker uses explicit typed Npgsql parameters to:

- enqueue/read active venture intent-set components
- lease `nlp.sci_scoring_job` with bounded batches and `FOR UPDATE SKIP LOCKED`
- call `nlp.get_sci_scoring_candidates(owner, venture, afterLinkPk, maxRows)` with `maxRows`
  between 50 and 200
- compute complementary Client/Supplier/Partner/Investor/Talent features using returned exact
  cosine distances plus taxonomy, geography, qualification, and recency features
- calibrate raw fit to 0-100 using the active reviewed calibration
- call `nlp.apply_sci_link_score` with a stable score ID and stable outbox event ID; retries must
  reuse both IDs

The worker should continue polling PostgreSQL like the current embedding worker. It should advance
`after_link_pk` until the bounded candidate function returns fewer than the requested batch size,
then mark the job `SUCCEEDED`. Do not add HNSW/IVFFlat or compare more than 200 eligible links in
one exact-vector query.

Expired contact intents must not be rescored. Call `nlp.mark_sci_scores_stale` with `CONTACT` for
inbound links or `OWNER` for an owner's venture intent. It retains the previous placement/score and
does not consume an exit strike or demote solely because of expiry.

## Infrastructure changes

No new API, worker, cache, database, or request queue is required for the pilot.

Reuse the existing Core API, Core worker, NLP API, NLP worker, PostgreSQL Flexible Server, and
`integration-events` Service Bus topic. Add only:

- extend the existing Core-worker integration subscription filter to include
  `event_type = 'SciLinkScoreChanged.v1'`; no additional subscription or permission is needed
- SCI worker telemetry/alerts for pending age, retry count, dead jobs, batch duration, links scored,
  promotions, exits, and stale-score count

Add a dedicated low-priority queue only if measured fan-out contention shows that large owner or
popular-contact rescoring delays normal jobs. Redis and database partitioning remain deferred until
read latency or row-count evidence requires them.

## Pilot analytics

Use the existing `analytics.product_event` for `CONTACT_IMPORTED`, `CONTACT_SHORTLISTED`,
`INVITE_BATCH_APPROVED`, `SHARE_SHEET_OPENED`, `INVITE_LINK_OPENED`, `MEMBER_JOINED`,
`CONTACT_CONNECTED`, `INTENT_COMPLETED`, and `REPOSITORY_PROMOTED_TO_SCI`.

`INVITATIONS_SENT` is not authoritative when the device share sheet performs delivery. Treat share
sheet telemetry as best-effort and invite-link opens as the first server-authoritative downstream
event.
