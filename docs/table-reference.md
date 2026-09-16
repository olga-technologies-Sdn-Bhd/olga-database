# OLGA Connect Table Reference

This document provides a concise description of the 66 application tables in the OLGA Connect PostgreSQL database. Tables are grouped by their owning schema.

## Core

- `core.community` — Top-level OLGA network or tenant boundary. Members, organizations, events, files, and analytics belong to a community.
- `core.organization` — A company or professional organization that appears in member profiles.
- `core.organization_member` — Connects members to organizations and stores job title, department, primary affiliation, and employment dates.
- `core.member_profile` — The member's professional profile, including display name, headline, summary, visibility, and completion status.
- `core.sector` — Controlled industry or sector catalogue. Supports parent-child sector hierarchies.
- `core.member_sector` — Many-to-many association between members and sectors, including the member's primary sector.
- `core.member_geography` — Countries, regions, and cities where a member professionally operates; it is not live-location data.
- `core.profile_field_visibility` — Controls who can see individual profile fields, such as members or connected users.
- `core.member_verification` — Tracks email, phone, organization, or manual verification reviews and their evidence.

## Identity and access management

- `iam.member` — Authoritative member account and lifecycle status, such as pending, active, suspended, anonymized, or deleted.
- `iam.member_identity` — Maps a member to an encrypted login identity such as email, phone, or Microsoft Entra ID.
- `iam.auth_session` — Tracks application sessions, authentication strength, expiration, activity, and revocation.
- `iam.member_device` — Records a member's registered mobile devices or application installations.
- `iam.role` — Catalogue of application roles such as member, administrator, moderator, or support.
- `iam.permission` — Catalogue of allowed actions against resources, such as reading a profile or configuring an event.
- `iam.role_permission` — Many-to-many mapping that assigns permissions to roles.
- `iam.member_role` — Many-to-many mapping that assigns roles to members, with optional expiry or revocation.

## Consent and privacy

- `consent.consent_policy` — A versioned consent document for purposes such as terms, Live Mode, notifications, or analytics.
- `consent.member_consent` — Evidence that a member granted, denied, or withdrew consent for a particular policy.
- `consent.privacy_request` — A member request for data access, export, correction, deletion, or consent support.
- `consent.privacy_request_task` — Individual domain-level work items required to complete a privacy request.

## Events and Live Mode

- `event.venue` — An administrator-managed event venue with city, timezone, and optional coarse location cell.
- `event.event` — An event within a community, including its venue, time window, status, and Live Mode availability.
- `event.event_matching_policy` — Versioned rules controlling event matching eligibility, proximity, thresholds, and alert limits.
- `event.event_registration` — Connects members to events and tracks invitation, registration, and check-in status.
- `event.live_mode_session` — A temporary and revocable matching session for one member at one event.
- `event.event_presence` — Short-lived coarse presence information associated with a Live Mode session.

## Social relationships

- `social.connection_request` — A request from one member to another, optionally originating from an NLP match.
- `social.connection` — The canonical relationship created when a connection request is accepted.
- `social.member_block` — Records a member blocking another member and suppresses discovery and communication.
- `social.member_report` — A safety report submitted by one member about another member or resource.

## Chat

- `chat.conversation` — A one-to-one chat container created for an accepted connection.
- `chat.conversation_participant` — Stores the two conversation members and their read, mute, and leave state.
- `chat.message` — A durable ordered message sent inside a conversation.
- `chat.message_receipt` — Records when the non-sending participant received or read a message.

## File storage

- `storage.file_asset` — Metadata and security state for a private Azure Blob object; the file content itself is not stored in PostgreSQL.
- `storage.file_asset_link` — Links a file to a message, verification, privacy request, or NLP evaluation run.

## Notifications

- `notification.notification_policy` — Versioned rules for notification channels, frequency limits, quiet hours, retries, and expiration.
- `notification.notification_preference` — A member's push, email, and quiet-hour preferences for each notification purpose.
- `notification.push_token` — Encrypted APNS or FCM push token associated with a registered device.
- `notification.notification` — A notification delivery request resolved against policy, preferences, deduplication, and rate limits.
- `notification.notification_delivery_attempt` — Append-only record of each provider delivery attempt and its outcome.

## NLP matching

- `nlp.nlp_intent` — A member's current `WANT` or `OFFER`, containing original text, normalized text, categories, and expiry.
- `nlp.nlp_embedding` — The versioned 1,536-dimension vector generated from an intent.
- `nlp.nlp_model_version` — Defines an embedding provider, deployment, dimensions, and compatible preprocessing version.
- `nlp.nlp_ranking_config` — Versioned matching weights and thresholds used to calculate final match scores.
- `nlp.nlp_processing_job` — Worker job for embedding or re-embedding an NLP intent.
- `nlp.match_request` — One idempotent matching execution, including requester, intent, model, ranking version, and candidate count.
- `nlp.nlp_match_result` — A ranked candidate recommendation with scores, explanations, and model/configuration versions.
- `nlp.nlp_feedback` — Member feedback indicating whether a match was useful, not useful, or inappropriate.
- `nlp.match_suppression` — Prevents a member, intent, or context from participating in matching for a specified period.
- `nlp.evaluation_dataset` — Metadata for a versioned and de-identified NLP quality-testing dataset.
- `nlp.evaluation_pair` — One labelled requester-and-candidate example within an evaluation dataset.
- `nlp.evaluation_run` — Results and metrics from testing a model and ranking configuration against a dataset.

## Moderation

- `moderation.moderation_case` — A restricted review case created from a report, automated scan, or administrator review.
- `moderation.moderation_action` — Append-only record of an action taken within a moderation case.
- `moderation.content_rule` — Versioned rules for prohibited terms, file types, rate limits, or moderation policies.
- `moderation.content_scan` — Result of scanning a file, profile, intent, or message for harmful or malicious content.

## Operations

- `ops.sync_change` — Ordered change feed used by mobile clients to synchronize resources and deletions.
- `ops.retention_policy` — Versioned rules specifying how long a data class is retained and how it is disposed.
- `ops.retention_execution` — Evidence and counts from applying a specific retention-policy version.
- `ops.outbox_event` — Transactional event waiting to be reliably published to another service or message broker.
- `ops.idempotency_record` — Prevents duplicate API mutations and stores the result of the original request.
- `ops.background_job` — Retry and processing state for asynchronous work such as scanning files or sending notifications.
- `ops.audit_event` — Append-only security and administrative audit evidence with actor, action, resource, and outcome.

## Analytics

- `analytics.product_event` — Privacy-safe product usage event using a pseudonymous member value rather than the real member ID.

## System-maintained history tables

The `history` schema contains automatically maintained copies of selected configuration tables, including roles, permissions, sectors, consent policies, venues, event policies, notification policies, NLP configuration, moderation rules, and retention policies.

Application code must not insert directly into these tables. Database triggers archive the previous row whenever tracked configuration changes.
