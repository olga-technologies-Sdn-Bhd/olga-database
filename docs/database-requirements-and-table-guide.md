# OLGA Connect Database Requirements and Table Guide

## Purpose and source of truth

This guide explains why the OLGA Connect database exists, how the product requirements are represented, and how the tables work together. It is written for application, NLP, mobile, administration, QA, and operations developers.

The current PostgreSQL schema is the implementation source of truth. The older architecture documents provide product intent, but they do not override the SQL modules in this repository. Developers should change the numbered SQL modules first, rebuild the full setup script, and update this guide in the same change.

Current baseline:

- PostgreSQL 17 on Azure Database for PostgreSQL Flexible Server
- One database per environment
- Schema version 2.7: the generated v2.4 baseline plus the ordered v2.5 profile-image, v2.6
  Core outbox-leasing, and v2.7 chat outbox-contract migrations
- 67 product tables across 12 bounded schemas
- 4 controlled read views and 9 controlled workflow functions
- 11 low-volume configuration and reference tables with system-period history
- API-only access from mobile and admin clients

The generated file OLGA_Connect_PostgreSQL_Full_Setup.sql is a deployment artifact. Do not edit it directly.

## Architecture rules that apply everywhere

| Rule | Database implementation | Developer responsibility |
|---|---|---|
| Physical naming | Schemas, tables, columns, functions, constraints, and indexes use lower_snake_case without quoted mixed-case names. | Use the physical names in migrations and SQL. Map to .NET naming in code only. |
| Identifiers | Stable API resources use opaque varchar(64) IDs. Internal-only keys use bigint GENERATED AS IDENTITY. | Never expose sequential internal keys through the API. |
| Time | Business timestamps use timestamptz and database defaults use CURRENT_TIMESTAMP. | Normalize API timestamps to UTC and enforce expiry on every read and write. |
| Concurrency | Mutable API resources use bigint row_version, default 1, incremented by a shared BEFORE UPDATE trigger. | Return row_version as an ETag and require If-Match when lost updates matter. |
| Mutation replay | ops.idempotency_record protects retryable commands. Atomic functions cover connection acceptance, chat writes, match persistence, and notifications. | Require Idempotency-Key on every mutation. The same key with a different request body is a conflict. |
| Reliable integration | Business changes, ops.outbox_event, and ops.sync_change are committed in one transaction where applicable. Outbox rows use expiring leases, bounded retries, and explicit exhausted state. | Publish only committed events while holding the matching lease. Never acknowledge, retry, or exhaust an event after lease ownership is lost. Clients treat sync payloads as projections, not authority. |
| Sensitive data | Ciphertext uses bytea. Passwords, OTP values, bearer tokens, refresh tokens, raw location, and encryption keys are not stored here. | Keep keys in Key Vault and authentication credentials in the approved CIAM platform. |
| JSON | jsonb is limited to bounded, validated metadata, snapshots, and reason-code collections. | Keep relationships, permissions, states, and query predicates in typed columns. |
| Deletion | Foreign keys default to NO ACTION. Privacy and retention workflows perform controlled deletion or anonymization. | Do not add cascading deletes without an approved lifecycle review. |
| Vector matching | Embeddings use vector(1536) for text-embedding-3-small. Eligibility is filtered first, then exact cosine distance <=> runs over at most 50 to 200 candidates. | Use parameterized Npgsql for PostgreSQL and pgvector-specific queries. Do not add HNSW or IVFFlat indexes yet. |
| Data access | The required path is API endpoint to application service to repository to EF Core or parameterized Npgsql to PostgreSQL. | Keep SQL out of endpoints, controllers, mobile code, and ranking classes. |
| Pagination | Feeds, matches, chat, notifications, and sync use opaque cursors. | Do not implement unbounded list endpoints or offset pagination for these feeds. |

## Product relationship overview

The member account is the central identity. A profile and consent determine what the member may do and what others may see. An event registration plus a valid Live Mode session establishes a temporary matching context. NLP produces a recommendation, but it never grants access. A connection request and mutual acceptance create the relationship that permits chat.

~~~mermaid
flowchart LR
    M[iam.member] --> P[core.member_profile]
    M --> C[consent.member_consent]
    M --> R[event.event_registration]
    R --> E[event.event]
    C --> L[event.live_mode_session]
    E --> L
    L --> EP[event.event_presence]
    M --> I[nlp.nlp_intent]
    I --> V[nlp.nlp_embedding]
    I --> MR[nlp.match_request]
    MR --> RES[nlp.nlp_match_result]
    RES --> CR[social.connection_request]
    CR --> CN[social.connection]
    CN --> CV[chat.conversation]
    CV --> MSG[chat.message]
~~~

This sequence is intentional:

1. Identity, account state, consent, visibility, context, expiry, blocks, existing connections, moderation, and suppression determine eligibility.
2. Exact vector similarity and versioned ranking operate only on the bounded eligible set.
3. A recommendation may lead to a connection request.
4. Only accepted connections create a conversation.
5. Every message is authorized again against the current connection and block state.

## Requirements matched to the database

The status column describes what the database currently supports. Application code, CIAM, Blob Storage, Service Bus, and worker processes still have responsibilities outside PostgreSQL.

| Requirement | Primary database objects | Match and boundary |
|---|---|---|
| FR-01 Registration, verification, sign-in, and recovery | iam.member, iam.member_identity, iam.auth_session, iam.member_device, core.member_verification | Matched for application identity binding, verification state, sessions, devices, and revocation. The managed CIAM provider owns credentials, OTP validation, MFA, recovery, and token issuance. |
| FR-02 Profile, role, organization, sectors, geography, offers, needs, and visibility | core.member_profile, core.organization, core.organization_member, core.member_sector, core.member_geography, core.profile_field_visibility, nlp.nlp_intent | Matched. Business geography is profile data and must not be used as live proximity. |
| FR-03 Administrator approval, suspension, anonymization, and audit | iam.member, core.member_verification, iam.member_role, ops.audit_event, admin.vw_member_review | Matched at the data boundary. Privileged API operations also require MFA or step-up authentication and object-level authorization. |
| FR-04 Field-level profile visibility | core.profile_field_visibility, core.member_profile | Matched. The API must apply the audience rule to every profile response. |
| FR-05 Original and normalized wants and offers | nlp.nlp_intent, nlp.nlp_embedding, nlp.nlp_model_version, nlp.nlp_processing_job | Matched. Original text is preserved separately from normalized text and versioned embeddings. |
| FR-06 Vector candidates and configurable ranking | nlp.match_request, nlp.nlp_match_result, nlp.nlp_ranking_config, nlp.get_eligible_candidates, nlp.save_match_results | Matched. Eligibility precedes exact cosine comparison over a maximum of 50 to 200 candidates. |
| FR-07 Explainable recommendations and feedback | nlp.nlp_match_result, nlp.nlp_feedback | Matched. Results store approved reason codes, deterministic reason text, model version, preprocessing version, and ranking version. |
| FR-08 Remove self, blocked, connected, and ineligible candidates | social.member_block, social.connection, nlp.match_suppression, nlp.vw_member_context_eligibility, nlp.vw_member_relationship | Matched. These are hard filters and cannot be overridden by a high semantic score. |
| FR-09 Ranking thresholds, event scope, and suppressions | nlp.nlp_ranking_config, event.event_matching_policy, nlp.match_suppression | Matched with versioned configuration and effective dates. |
| FR-10 Revocable Live Mode for a defined event | consent.member_consent, event.event, event.event_registration, event.live_mode_session | Matched. A session must use the member's latest valid LIVE_MODE grant and cannot outlive the event. |
| FR-11 Coarse event presence without exposing precise location | event.venue, event.event, event.event_registration, event.event_presence | Matched. Presence is short-lived and linked through a Live Mode session. Raw member coordinates are not stored. |
| FR-12 Nearby alerts only for eligible high-confidence matches | event.event_matching_policy, nlp.nlp_match_result, notification.notification, notification.try_enqueue | Matched. Event and notification policy are both applied before delivery. |
| FR-13 Alert rate limits, preferences, deduplication, and quiet hours | notification.notification_policy, notification.notification_preference, notification.notification, notification.notification_delivery_attempt | Matched. notification.try_enqueue resolves policy and applies controls atomically. |
| FR-14 Send, accept, decline, withdraw, block, and report | social.connection_request, social.connection, social.member_block, social.member_report | Matched. State checks and unique pair constraints prevent invalid duplicate relationships. |
| FR-15 Chat only after mutual acceptance | social.accept_connection_request, social.connection, chat.conversation, chat.conversation_participant | Matched. Connection and conversation creation occur in one controlled transaction. |
| FR-16 Messages and controlled private files | chat.message, chat.message_receipt, storage.file_asset, storage.file_asset_link, moderation.content_scan | Matched in the current schema. Files remain unavailable until verified and scanned clean. Raw blob paths and access URLs are never exposed as persistent API data. |
| FR-17 Restricted moderation review | social.member_report, moderation.moderation_case, moderation.moderation_action, moderation.content_scan, ops.audit_event | Matched. Case notes and moderation details are restricted to authorized roles. |
| FR-18 Event, verification, report, content-rule, and consent administration | event schema, core.member_verification, moderation schema, consent.privacy_request, admin.vw_member_review | Matched at the database boundary. The admin web application must use /v1/admin APIs and never connect directly to PostgreSQL. |
| FR-19 Privacy-safe product analytics | analytics.product_event | Matched. Events use pseudonymous member identifiers and allowlisted, content-free properties. |
| FR-20 De-identified NLP evaluation | nlp.evaluation_dataset, nlp.evaluation_pair, nlp.evaluation_run, storage.file_asset | Matched. Evaluation data is versioned, de-identified, and separated from live member records. |

## Schema ownership and table relationships

### Core

The core schema owns the professional profile and organization model. It does not own authentication, consent, live location, or NLP output.

| Table | Intended use | Main relationships |
|---|---|---|
| core.community | Top-level network boundary. Release 1 has one OLGA community, but the boundary remains explicit. | Parent of members, organizations, events, files, sync changes, notifications, and analytics. |
| core.organization | Canonical professional organization used in member profiles. | Belongs to a community; parent of core.organization_member. |
| core.organization_member | Member affiliation, title, department, and effective dates. | Joins core.organization to iam.member. |
| core.member_profile | One searchable professional profile and publication state per member. | One-to-one with iam.member; source for sectors, geography, and visibility. |
| core.member_profile_image | Object-storage paths, content metadata, processing status, and concurrency state for a member profile image. Image bytes are never stored in PostgreSQL. | Belongs to iam.member; the approved active image is referenced by core.member_profile.profile_image_id. |
| core.sector | Controlled sector taxonomy with an optional parent sector. | Self-referencing hierarchy; joined to members through core.member_sector. |
| core.sector_questionnaire | Current published questionnaire definition and version for a sector. | Belongs to core.sector; responses retain the submitted definition version. |
| core.profile_question | Versioned generic or sector-specific question with structured answer configuration. | Generic rows apply to every questionnaire; sector rows apply only to their sector. |
| core.sector_questionnaire_question | Immutable membership of question versions in a questionnaire definition version. | Makes historical responses reproducible after a question is revised or retired. |
| core.member_questionnaire_response | Draft, completed, or superseded member response to a questionnaire version. | Belongs to a member and core.sector_questionnaire; owns individual answers. |
| core.member_question_answer | Validated JSON answer to the exact question version shown. | Belongs to a member questionnaire response and core.profile_question. |
| core.member_sector | Many-to-many member sector assignment, including one optional primary sector. | Joins iam.member to core.sector. |
| core.member_geography | Operating markets such as country, region, and city. | Belongs to iam.member; never used as live location. |
| core.profile_field_visibility | Per-field audience rule such as private, matched, connected, or members. | Belongs to iam.member; enforced by profile APIs. |
| core.member_verification | Review case for email, phone, organization, or manual verification. | Belongs to a member; may reference private evidence in storage.file_asset and a reviewing administrator. |

### Identity and access management

The iam schema maps managed identities to application members and records authorization assignments. It does not store authentication secrets.

| Table | Intended use | Main relationships |
|---|---|---|
| iam.member | Authoritative member lifecycle state. Suspended, anonymized, or deleted members cannot act or appear. | Belongs to core.community; parent for most member-owned data. |
| iam.member_identity | Encrypted and hashed mapping from a CIAM subject to a member. | Many identities may belong to one member. |
| iam.role | Application role catalog such as member, administrator, moderator, and NLP evaluator. | Connected to permissions and members through mapping tables. |
| iam.permission | Resource and action catalog used by API authorization policies. | Connected to roles through iam.role_permission. |
| iam.role_permission | Effective and revocable role-to-permission grant. | Joins iam.role to iam.permission; may record the granting administrator. |
| iam.member_role | Effective and revocable member-to-role assignment. | Joins iam.member to iam.role; may expire. |
| iam.member_device | Registered mobile installation, version, and revocation state. | Belongs to a member; parent of push tokens and optional session binding. |
| iam.auth_session | Application session binding, authentication strength, expiry, and revocation. | Belongs to a member and optionally a device. No bearer or refresh token is stored. |

### Consent and privacy

The consent schema records the legal and product permissions that other domains must check. Consent rows are evidence; they are not overwritten to simulate current state.

| Table | Intended use | Main relationships |
|---|---|---|
| consent.consent_policy | Immutable version of terms or a purpose-specific consent policy. | Parent of member decisions; selected by purpose, locale, and effective time. |
| consent.member_consent | Append-oriented grant or denial evidence, including withdrawal. | Joins a member to a policy; referenced by Live Mode sessions. |
| consent.privacy_request | Member request for access, correction, deletion, export, or consent support. | Belongs to a member; may reference an export storage.file_asset. |
| consent.privacy_request_task | Per-domain work and evidence required to complete a privacy request. | Child of consent.privacy_request; all required tasks must finish or be explicitly exempted. |

### Events and Live Mode

The event schema creates a temporary, consent-based context for discovery. Event registration and check-in do not by themselves enable Live Mode.

| Table | Intended use | Main relationships |
|---|---|---|
| event.venue | Admin-managed venue and optional venue-level coarse cell. | Parent of events; contains no member location history. |
| event.event | Event and matching context with a fixed time window. | Belongs to a community and optionally a venue. |
| event.event_matching_policy | Versioned event-specific eligibility, threshold, proximity, and alert caps. | Belongs to an event; referenced by notifications. |
| event.event_registration | Member registration or check-in relationship to an event. | Joins an event to a member. |
| event.live_mode_session | Revocable discovery window for one member at one event. | Belongs to an event and member; references the valid consent record. |
| event.event_presence | Short-lived coarse observation used for proximity filtering. | Belongs to a Live Mode session and expires quickly. |

### Social relationships

The social schema owns the consent gate between a recommendation and communication.

| Table | Intended use | Main relationships |
|---|---|---|
| social.connection_request | Pending or completed request from one member to another. | Links sender and recipient; may reference the originating NLP match. |
| social.connection | Canonical mutually accepted member pair. | Created from one accepted request; parent of one conversation. |
| social.member_block | Directional safety action that suppresses discovery and communication in both directions. | Links blocker and blocked member without revealing the actor to product clients. |
| social.member_report | Member-submitted report that starts or links a moderation case. | Links reporter, reported member, and optional resource. |

### Chat

The chat schema stores durable one-to-one communication. The connection remains the authority for access.

| Table | Intended use | Main relationships |
|---|---|---|
| chat.conversation | Chat container created for one accepted connection. | One-to-one with social.connection. |
| chat.conversation_participant | Participant membership and per-member read state. | Joins a conversation to exactly the two connected members. |
| chat.message | Durable ordered message. | Belongs to a conversation and sender; saved through chat.save_message. |
| chat.message_receipt | Monotonic delivered and read evidence. | Joins a message to a conversation participant. |

### Storage

The storage schema stores metadata for private Blob Storage objects. It does not store file content or long-lived access URLs.

| Table | Intended use | Main relationships |
|---|---|---|
| storage.file_asset | Upload, validation, scan, availability, expiry, and deletion lifecycle for one private object. | Belongs to a community and optional owner; referenced by verification and privacy export workflows. |
| storage.file_asset_link | Authorized link from an asset to a message, verification, privacy request, or evaluation resource. | Belongs to storage.file_asset; the owning domain validates the target resource. |

### Notifications

The notification schema separates member preferences and policy from provider delivery attempts.

| Table | Intended use | Main relationships |
|---|---|---|
| notification.notification_policy | Versioned rules for channel, quiet hours, deduplication, caps, retry, and expiry. | Optional community scope; referenced by each notification. |
| notification.notification_preference | Member choice by notification purpose, channel, and quiet-hour window. | Belongs to a member. |
| notification.push_token | Provider push token mapped to one registered device. | Belongs to iam.member_device and is restricted to the notification service. |
| notification.notification | Policy-resolved delivery intent and aggregate status. | Belongs to a member and policy; may reference an event matching policy. |
| notification.notification_delivery_attempt | Append-only provider attempt and acknowledgement history. | Belongs to a notification and optional push token. |

### NLP matching and evaluation

The nlp schema stores intent processing, versioned embeddings, match executions, explanations, feedback, and evaluation evidence. It consumes approved product projections and cannot authorize visibility or communication.

| Table | Intended use | Main relationships |
|---|---|---|
| nlp.nlp_intent | Current expiring WANT or OFFER text and structured matching metadata. | Belongs to a member and context; parent of embeddings and processing jobs. |
| nlp.nlp_embedding | Versioned vector(1536) for one normalized intent. | Belongs to an intent and model version. |
| nlp.nlp_model_version | Provider, deployment, dimensions, and preprocessing compatibility metadata. | Referenced by embeddings, match requests, results, and evaluation runs. |
| nlp.nlp_ranking_config | Versioned weights, threshold, and bounded ranking configuration. | Referenced by match requests, results, and evaluation runs. |
| nlp.nlp_processing_job | Retry and lease state for embedding or re-embedding an intent. | Belongs to an intent. |
| nlp.match_request | Idempotent execution envelope and immutable configuration snapshot for one search. | Belongs to requester and intent; parent of match results. |
| nlp.nlp_match_result | Ranked candidate, scores, approved reasons, and exact versions used. | Belongs to a match request and references requester and candidate members. |
| nlp.nlp_feedback | Append-oriented useful, not useful, or inappropriate label. | References a match result and may supersede an earlier feedback row. |
| nlp.match_suppression | Time-bounded administrative or safety exclusion by member, intent, context, or combination. | Optionally references a member and intent. |
| nlp.evaluation_dataset | Versioned metadata and approval state for a de-identified labelled dataset. | Parent of evaluation pairs and runs. |
| nlp.evaluation_pair | One de-identified labelled requester and candidate example. | Belongs to an evaluation dataset. |
| nlp.evaluation_run | Reproducible metrics and error-report reference for a model and ranking version. | Belongs to a dataset and references model and ranking versions. |

### Moderation

The moderation schema separates restricted review evidence from member-facing content.

| Table | Intended use | Main relationships |
|---|---|---|
| moderation.moderation_case | Unified review case from a member report, automated scan, or administrator review. | May reference a subject member and assigned moderator. |
| moderation.moderation_action | Append-only action and reason within a case. | Belongs to a moderation case and acting moderator. |
| moderation.content_rule | Versioned configuration for file, text, rate, or policy rules. | Used by scan and moderation workflows. |
| moderation.content_scan | Scanner result for a file or text resource. | References the target through controlled resource type and ID fields. |

### Operations

The ops schema provides reliability, audit, synchronization, and lifecycle controls shared across domains.

| Table | Intended use | Main relationships |
|---|---|---|
| ops.outbox_event | Transactional event waiting for reliable publication, including lease ownership, retry scheduling, sanitized failure state, and explicit exhaustion. | Written in the same transaction as the business change; claimed and transitioned only by the lease-owning worker. |
| ops.idempotency_record | Actor-scoped replay protection and stable result reference. | Keyed by operation scope, actor, and idempotency key. |
| ops.background_job | Retry, lease, and terminal state for non-NLP work. | May target a product resource through controlled type and ID fields. |
| ops.sync_change | Ordered, authorization-safe mobile delta and tombstone feed. | Scoped to a community and optionally one member. |
| ops.retention_policy | Versioned retention duration and delete, anonymize, or archive action. | Parent of retention execution evidence. |
| ops.retention_execution | Counts, legal-hold skips, status, and evidence for one retention run. | Belongs to the exact policy version applied. |
| ops.audit_event | Append-only, content-free evidence of sensitive and security actions. | Uses polymorphic resource references and correlation IDs. |

### Analytics

| Table | Intended use | Main relationships |
|---|---|---|
| analytics.product_event | Privacy-safe funnel, adoption, and match-quality event. | Belongs to a community and uses a salted member pseudonym rather than member_id. |

## Controlled database interfaces

Application services should use repositories and these narrow interfaces instead of reproducing critical rules in ad hoc SQL.

| Interface | Intended use |
|---|---|
| nlp.vw_member_context_eligibility | Minimum product-owned facts required to decide whether a member may participate in matching. |
| nlp.vw_member_relationship | Product-owned connection and block projection used by candidate filtering. |
| chat.vw_authorized_conversation | Authorized conversation projection for the chat service. |
| admin.vw_member_review | Redacted member review data for authorized administration. |
| nlp.get_requester_intent | Resolve the requester's active, unexpired intent in the stated context. |
| nlp.get_eligible_candidates | Apply product eligibility first and return at most 50 to 200 candidates for exact vector comparison. |
| nlp.save_match_results | Persist an idempotent match execution and its ranked, explained results atomically. |
| nlp.save_feedback | Validate and append recommendation feedback. |
| social.accept_connection_request | Accept a request and create the connection, two participants, conversation, outbox event, and sync changes atomically. |
| chat.save_message | Recheck authorization, allocate sequence, save the message, and write outbox and sync records atomically. |
| chat.save_message_receipt | Apply monotonic receipt changes and publish synchronization records. |
| event.purge_expired_presence | Delete expired presence rows in bounded, lock-safe batches. |
| notification.try_enqueue | Apply active policy, preference, confidence, quiet hours, deduplication, and rate limits before enqueueing. |

## History and audit are different

System-period history retains full previous rows only for selected low-volume configuration and reference tables:

- iam.permission
- iam.role
- core.sector
- consent.consent_policy
- event.venue
- event.event_matching_policy
- notification.notification_policy
- nlp.nlp_model_version
- nlp.nlp_ranking_config
- moderation.content_rule
- ops.retention_policy

The history tables and all-version views live in the history schema. They are not part of the 66-table product inventory and are readable only by the approved admin reader.

ops.audit_event serves a different purpose. It records who performed a sensitive action, what resource was affected, the result, and the correlation ID. It deliberately excludes sensitive content. Profiles, messages, identity ciphertext, files, and presence do not receive full-row history because doing so would increase exposure and conflict with deletion and retention obligations.

## Main workflows developers must preserve

### Member onboarding

1. CIAM verifies the external identity.
2. The API creates iam.member and iam.member_identity and captures mandatory consent.member_consent evidence.
3. The member completes core.member_profile and related organization, sector, geography, and visibility rows.
4. Account activation occurs only when the approved verification, profile, and consent rules pass.

### Intent and matching

1. Save nlp.nlp_intent with original and normalized text, context, status, and expiry.
2. Queue nlp.nlp_processing_job; the worker stores nlp.nlp_embedding with model, preprocessing, dimensions, and normalized hash.
3. Create an idempotent nlp.match_request.
4. Filter eligibility using product-owned views, current consent, context, presence, relationships, moderation, and suppression.
5. Apply exact cosine distance to the bounded candidates, then versioned business ranking.
6. Save nlp.nlp_match_result with deterministic explanations and version evidence.

### Event Live Mode

1. event.event_registration establishes participation or check-in.
2. A separate valid LIVE_MODE consent record is required.
3. event.live_mode_session creates the revocable discovery window and cannot outlive the event.
4. event.event_presence stores only coarse, short-lived observations.
5. Disabling Live Mode or withdrawing consent removes eligibility immediately; delayed cleanup cannot make the member visible again.

### Connection and chat

1. The sender creates social.connection_request with an idempotency key after current eligibility checks.
2. social.accept_connection_request rechecks state and creates social.connection, chat.conversation, and two participant rows in one transaction.
3. Each message call rechecks the active connection, participants, and both block directions.
4. The durable message, outbox event, and member-scoped sync changes commit before realtime fan-out.

### Private file

1. Create storage.file_asset in UPLOADING state after validating purpose, type, and size policy.
2. Upload to a private Blob Storage path using a short-lived write URL that is never persisted.
3. Finalize verified type, size, and SHA-256 metadata and queue scanning.
4. Record the result in moderation.content_scan; only CLEAN content becomes available.
5. Add storage.file_asset_link only after the owning domain validates the target resource.
6. Recheck current authorization, link, scan, and lifecycle status before issuing a short-lived download URL.

### Privacy and retention

1. Verify consent.privacy_request and create a task for every affected domain.
2. Workers process tasks with bounded retries and evidence codes.
3. A privacy request completes only when every required task is completed or explicitly exempted.
4. Retention workers apply an approved ops.retention_policy and record counts, legal holds, result, and evidence in ops.retention_execution.

## Statements intentionally excluded from this baseline

The following older statements are not part of the current database contract because they conflict with the implemented architecture or add unnecessary alternatives:

- A separate vector database or Azure AI Search for Release 1
- HNSW, IVFFlat, or approximate vector search before measured evidence supports it
- Dapper as a standard data-access layer
- Direct mobile or admin access to PostgreSQL, Blob Storage, or messaging infrastructure
- Authentication credentials, OTP values, access tokens, or refresh tokens in PostgreSQL
- Continuous or precise member location history
- An NLP score granting visibility, connection, chat, file, or notification rights
- LLM-generated match explanations in Release 1
- Automatic cascade deletion of product data
- Full-row history for profiles, messages, identity ciphertext, files, presence, or processing tables
- Deferring the storage model for private files; the current schema includes the governed file lifecycle required by verification, privacy exports, evaluations, and future connected-member sharing

## Implementation checklist

Before merging a database or repository change, confirm:

- The owning schema is correct and cross-domain writes use an approved service or function boundary.
- Physical names remain lower_snake_case.
- New mutable API resources have row_version and audit actor triggers where required.
- New public resources use opaque IDs; internal numeric keys use identity columns.
- Every foreign key has an intentional delete rule.
- Every mutation supports idempotency and optimistic concurrency where applicable.
- Authorization, community, context, expiry, consent, block, moderation, and resource state are evaluated at the API boundary.
- Any jsonb field is bounded and validated.
- Sensitive values use the approved encryption and telemetry rules.
- Vector queries filter eligibility first and compare no more than 50 to 200 candidates exactly.
- Background work has bounded retries, leases or timeouts, sanitized errors, and a terminal failure path.
- Retention, privacy deletion, sync tombstones, audit, and history impact have been reviewed.
- The numbered SQL modules, generated setup, static validator, integration tests, and this guide agree.

## Maintained references

Use these repository files with this guide:

- 010_tables.sql for the 66-table physical model and column comments
- 015_audit_history.sql for audit actor and system-period history behavior
- 020_constraints_indexes.sql for foreign keys, checks, uniqueness, and query indexes
- 025_invariants.sql for cross-table rules and lifecycle triggers
- 030_views.sql for controlled read boundaries
- 040_procedures.sql for atomic workflows
- 060_security.sql for runtime roles and grants
- 090_verify.sql and tests/validate_static.py for deployment verification
- docs/architecture-decisions-v2.4.md for decisions that are not self-evident from DDL

The reviewed Word documents remain background material. This guide removes their duplicated alternatives and uses the implemented PostgreSQL model as the final decision.
