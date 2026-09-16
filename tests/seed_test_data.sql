-- Development/test fixture for the OLGA Connect PostgreSQL 17 schema.
-- Run only after the full database setup has completed. Do not run in production.
-- The fixed external IDs and guarded inserts make this script safe to rerun.

BEGIN;

SELECT ops.set_audit_context('seed:test-data');

-- Reference data required even when the baseline seed was deployed with QA policies disabled.
INSERT INTO iam.role(role_code, name, description, is_privileged)
VALUES ('TEST_ADMIN', 'Test administrator', 'Development/test fixture administrator', true)
ON CONFLICT (role_code) DO NOTHING;

INSERT INTO iam.permission(permission_code, resource_type, action, description, status)
VALUES ('TEST_FIXTURE_READ', 'TEST_FIXTURE', 'READ', 'Development/test fixture permission', 'ACTIVE')
ON CONFLICT (permission_code) DO NOTHING;

INSERT INTO iam.role_permission(role_code, permission_code)
VALUES ('TEST_ADMIN', 'TEST_FIXTURE_READ')
ON CONFLICT (role_code, permission_code) DO NOTHING;

INSERT INTO core.community(community_id, name, status, default_locale)
VALUES ('test-community-001', 'OLGA Test Community', 'ACTIVE', 'en-IN')
ON CONFLICT (community_id) DO NOTHING;

INSERT INTO iam.member(member_id, community_id, status, locale, verified_at)
VALUES
    ('test-member-001', 'test-community-001', 'ACTIVE', 'en-IN', CURRENT_TIMESTAMP - interval '30 days'),
    ('test-member-002', 'test-community-001', 'ACTIVE', 'en-IN', CURRENT_TIMESTAMP - interval '20 days'),
    ('test-member-003-admin', 'test-community-001', 'ACTIVE', 'en-IN', CURRENT_TIMESTAMP - interval '60 days')
ON CONFLICT (member_id) DO NOTHING;

INSERT INTO iam.member_identity(
    member_id, provider, provider_subject_hash, provider_subject_ciphertext,
    display_hint, is_primary, status, verified_at
)
SELECT 'test-member-001', 'EMAIL', repeat('1', 64), decode('746573742d63697068657274657874', 'hex'),
       't***1@example.test', true, 'ACTIVE', CURRENT_TIMESTAMP - interval '30 days'
WHERE NOT EXISTS (
    SELECT 1 FROM iam.member_identity
    WHERE provider = 'EMAIL' AND provider_subject_hash = repeat('1', 64)
);

INSERT INTO iam.member_role(member_id, role_code, granted_by)
VALUES ('test-member-003-admin', 'TEST_ADMIN', 'test-member-003-admin')
ON CONFLICT (member_id, role_code) DO NOTHING;

INSERT INTO iam.member_device(device_id, member_id, platform, app_version, status)
VALUES ('test-device-001', 'test-member-001', 'ANDROID', '1.0.0-test', 'ACTIVE')
ON CONFLICT (device_id) DO NOTHING;

INSERT INTO iam.auth_session(
    session_id, member_id, device_id, identity_provider, provider_session_hash,
    auth_strength, issued_at, expires_at, last_seen_at
)
VALUES (
    'test-session-001', 'test-member-001', 'test-device-001', 'EMAIL', repeat('2', 64),
    'STANDARD', CURRENT_TIMESTAMP - interval '5 minutes',
    CURRENT_TIMESTAMP + interval '1 day', CURRENT_TIMESTAMP
)
ON CONFLICT (session_id) DO NOTHING;

INSERT INTO core.organization(
    organization_id, community_id, name, normalized_name, website_domain,
    industry_code, verification_status, status
)
VALUES (
    'test-organization-001', 'test-community-001', 'Acme Test Labs',
    'acme test labs', 'example.test', 'TECHNOLOGY', 'VERIFIED', 'ACTIVE'
)
ON CONFLICT (organization_id) DO NOTHING;

INSERT INTO core.organization_member(
    organization_id, member_id, job_title, department, is_primary, started_on
)
SELECT 'test-organization-001', 'test-member-001', 'Product Lead', 'Product', true, DATE '2025-01-01'
WHERE NOT EXISTS (
    SELECT 1 FROM core.organization_member
    WHERE organization_id = 'test-organization-001'
      AND member_id = 'test-member-001'
      AND started_on = DATE '2025-01-01'
);

INSERT INTO core.member_profile(
    member_id, display_name, headline, professional_summary, role_category,
    profile_status, visibility, completeness_score, published_at
)
VALUES
    ('test-member-001', 'Asha Test', 'Product leader', 'Building privacy-aware professional communities.',
     'PRODUCT', 'ACTIVE', 'MEMBERS', 90.00, CURRENT_TIMESTAMP - interval '10 days'),
    ('test-member-002', 'Bala Test', 'AI engineer', 'Developing responsible matching systems.',
     'ENGINEERING', 'ACTIVE', 'MEMBERS', 85.00, CURRENT_TIMESTAMP - interval '8 days')
ON CONFLICT (member_id) DO NOTHING;

INSERT INTO core.sector(sector_code, name, status, sort_order)
VALUES ('TEST_TECHNOLOGY', 'Test Technology', 'ACTIVE', 9000)
ON CONFLICT (sector_code) DO NOTHING;

INSERT INTO core.member_sector(member_id, sector_code, is_primary)
VALUES ('test-member-001', 'TEST_TECHNOLOGY', true)
ON CONFLICT (member_id, sector_code) DO NOTHING;

INSERT INTO core.member_geography(member_id, country_code, region, city, is_primary)
SELECT 'test-member-001', 'IN', 'Karnataka', 'Bengaluru', true
WHERE NOT EXISTS (
    SELECT 1 FROM core.member_geography
    WHERE member_id = 'test-member-001' AND country_code = 'IN'
      AND region = 'Karnataka' AND city = 'Bengaluru'
);

INSERT INTO core.profile_field_visibility(member_id, field_code, audience)
VALUES ('test-member-001', 'PROFESSIONAL_SUMMARY', 'MEMBERS')
ON CONFLICT (member_id, field_code) DO NOTHING;

INSERT INTO storage.file_asset(
    file_asset_id, community_id, owner_member_id, purpose_code, container_name,
    blob_path, blob_path_hash, file_name, media_type, size_bytes, sha256,
    classification, scan_status, lifecycle_status
)
VALUES (
    'test-file-001', 'test-community-001', 'test-member-001', 'VERIFICATION_EVIDENCE',
    'test-private', 'test/verification/test-file-001.pdf', repeat('3', 64),
    'verification.pdf', 'application/pdf', 128, repeat('4', 64),
    'RESTRICTED', 'CLEAN', 'AVAILABLE'
)
ON CONFLICT (file_asset_id) DO NOTHING;

INSERT INTO core.member_verification(
    verification_id, member_id, verification_type, status,
    evidence_file_asset_id, reviewed_by, reviewed_at, reason_code
)
VALUES (
    'test-verification-001', 'test-member-001', 'MANUAL', 'APPROVED',
    'test-file-001', 'test-member-003-admin', CURRENT_TIMESTAMP - interval '1 day', 'TEST_APPROVED'
)
ON CONFLICT (verification_id) DO NOTHING;

INSERT INTO consent.consent_policy(
    policy_id, purpose_code, version, locale, content_hash, effective_from
)
VALUES (
    'test-live-mode-policy-v1', 'LIVE_MODE', 'test-v1', 'en-IN', repeat('5', 64),
    CURRENT_TIMESTAMP - interval '30 days'
)
ON CONFLICT (policy_id) DO NOTHING;

INSERT INTO consent.member_consent(
    member_id, policy_id, decision, captured_at, capture_channel, evidence_json
)
SELECT 'test-member-001', 'test-live-mode-policy-v1', 'GRANTED',
       CURRENT_TIMESTAMP - interval '1 hour', 'MOBILE', '{"app_version":"1.0.0-test"}'::jsonb
WHERE NOT EXISTS (
    SELECT 1 FROM consent.member_consent
    WHERE member_id = 'test-member-001' AND policy_id = 'test-live-mode-policy-v1'
);

INSERT INTO consent.privacy_request(
    privacy_request_id, member_id, request_type, status, verified_at, due_at
)
VALUES (
    'test-privacy-request-001', 'test-member-001', 'ACCESS', 'PROCESSING',
    CURRENT_TIMESTAMP - interval '1 day', CURRENT_TIMESTAMP + interval '29 days'
)
ON CONFLICT (privacy_request_id) DO NOTHING;

INSERT INTO consent.privacy_request_task(
    privacy_request_id, domain_code, action_type, status, attempt_count
)
SELECT 'test-privacy-request-001', 'PROFILE', 'EXPORT', 'PENDING', 0
WHERE NOT EXISTS (
    SELECT 1 FROM consent.privacy_request_task
    WHERE privacy_request_id = 'test-privacy-request-001'
      AND domain_code = 'PROFILE' AND action_type = 'EXPORT'
);

INSERT INTO event.venue(
    venue_id, name, country_code, region, city, coarse_geo_cell, timezone_id, status
)
VALUES (
    'test-venue-001', 'Bengaluru Test Convention Centre', 'IN', 'Karnataka',
    'Bengaluru', 'test-cell-001', 'Asia/Kolkata', 'ACTIVE'
)
ON CONFLICT (venue_id) DO NOTHING;

INSERT INTO event.event(
    event_id, community_id, venue_id, name, description, starts_at, ends_at,
    status, live_mode_enabled
)
VALUES (
    'test-event-001', 'test-community-001', 'test-venue-001', 'OLGA Test Networking Day',
    'A development fixture event.', CURRENT_TIMESTAMP - interval '1 hour',
    CURRENT_TIMESTAMP + interval '7 days', 'ACTIVE', true
)
ON CONFLICT (event_id) DO NOTHING;

INSERT INTO event.event_matching_policy(
    event_id, policy_version, status, registration_required, check_in_required,
    live_mode_required, proximity_mode, max_presence_age_minutes,
    alert_confidence_threshold, effective_from
)
SELECT 'test-event-001', 1, 'ACTIVE', true, false, true, 'VENUE', 15, 0.70000,
       CURRENT_TIMESTAMP - interval '1 hour'
WHERE NOT EXISTS (
    SELECT 1 FROM event.event_matching_policy
    WHERE event_id = 'test-event-001' AND policy_version = 1
);

INSERT INTO event.event_registration(
    event_id, member_id, status, checked_in_at, source
)
SELECT 'test-event-001', 'test-member-001', 'CHECKED_IN', CURRENT_TIMESTAMP - interval '30 minutes', 'APP'
WHERE NOT EXISTS (
    SELECT 1 FROM event.event_registration
    WHERE event_id = 'test-event-001' AND member_id = 'test-member-001'
);

INSERT INTO event.live_mode_session(
    live_session_id, event_id, member_id, consent_record_id, status,
    activated_at, active_until
)
SELECT 'test-live-session-001', 'test-event-001', 'test-member-001', mc.member_consent_id,
       'ACTIVE', CURRENT_TIMESTAMP - interval '20 minutes', CURRENT_TIMESTAMP + interval '1 day'
FROM consent.member_consent mc
WHERE mc.member_id = 'test-member-001'
  AND mc.policy_id = 'test-live-mode-policy-v1'
ORDER BY mc.captured_at DESC, mc.member_consent_id DESC
LIMIT 1
ON CONFLICT (live_session_id) DO NOTHING;

INSERT INTO event.event_presence(
    live_session_id, coarse_cell, observed_at, expires_at, source
)
SELECT 'test-live-session-001', 'test-cell-001', CURRENT_TIMESTAMP,
       CURRENT_TIMESTAMP + interval '15 minutes', 'CHECK_IN'
WHERE NOT EXISTS (
    SELECT 1 FROM event.event_presence
    WHERE live_session_id = 'test-live-session-001' AND source = 'CHECK_IN'
);

INSERT INTO nlp.nlp_model_version(
    model_version, provider, deployment_name, dimensions, preprocessing_version,
    status, activated_at
)
VALUES (
    'test-embedding-v1', 'OPENAI', 'text-embedding-3-small-test', 1536,
    'test-normalizer-v1', 'CANDIDATE', NULL
)
ON CONFLICT (model_version) DO NOTHING;

-- Reuse the single active ranking configuration installed by 050_seed.sql.

INSERT INTO nlp.nlp_intent(
    intent_id, member_id, context_id, intent_type, original_text, normalized_text,
    normalized_hash, language_code, contains_pii, status, category, industry,
    geography, expires_at, preprocessing_version
)
VALUES
    ('test-intent-want-001', 'test-member-001', 'test-event-001', 'WANT',
     'Looking for an AI engineering partner.', 'looking for an ai engineering partner',
     repeat('6', 64), 'en', false, 'MATCH_READY', 'PARTNERSHIP', 'TECHNOLOGY',
     'Bengaluru', CURRENT_TIMESTAMP + interval '30 days', 'test-normalizer-v1'),
    ('test-intent-offer-001', 'test-member-002', 'test-event-001', 'OFFER',
     'Offering AI matching engineering expertise.', 'offering ai matching engineering expertise',
     repeat('7', 64), 'en', false, 'MATCH_READY', 'PARTNERSHIP', 'TECHNOLOGY',
     'Bengaluru', CURRENT_TIMESTAMP + interval '30 days', 'test-normalizer-v1')
ON CONFLICT (intent_id) DO NOTHING;

INSERT INTO nlp.nlp_embedding(
    intent_id, model_version, dimensions, normalized_hash, embedding, status
)
VALUES (
    'test-intent-want-001', 'test-embedding-v1', 1536, repeat('6', 64),
    ('[' || rtrim(repeat('0.001,', 1536), ',') || ']')::vector, 'ACTIVE'
)
ON CONFLICT (intent_id, model_version) DO NOTHING;

INSERT INTO nlp.nlp_processing_job(job_id, intent_id, job_type, status, attempt_count)
VALUES ('test-nlp-job-001', 'test-intent-want-001', 'EMBED', 'SUCCEEDED', 1)
ON CONFLICT (job_id) DO NOTHING;

INSERT INTO nlp.match_request(
    request_id, request_hash, requester_id, intent_id, context_id, language_code,
    requested_limit, request_options_json, status, preprocessing_version,
    model_version, ranking_version, ranking_threshold, candidate_count, completed_at
)
VALUES (
    'test-match-request-001', repeat('8', 64), 'test-member-001',
    'test-intent-want-001', 'test-event-001', 'en', 3, '{"test_fixture":true}'::jsonb,
    'COMPLETED', 'test-normalizer-v1', 'test-embedding-v1', 'ranking-v1',
    0.35000, 1, CURRENT_TIMESTAMP
)
ON CONFLICT (request_id) DO NOTHING;

INSERT INTO nlp.nlp_match_result(
    request_id, requester_id, candidate_id, rank, semantic_score,
    reciprocal_score, final_score, label, reason_codes, reason_text,
    model_version, preprocessing_version, ranking_version, policy_status
)
SELECT 'test-match-request-001', 'test-member-001', 'test-member-002', 1,
       0.8200000, 0.7900000, 0.8100000, 'STRONG_MATCH',
       '["CATEGORY_ALIGNED","INDUSTRY_ALIGNED"]'::jsonb,
       'Complementary needs and expertise in the same industry.',
       'test-embedding-v1', 'test-normalizer-v1', 'ranking-v1', 'ELIGIBLE'
WHERE NOT EXISTS (
    SELECT 1 FROM nlp.nlp_match_result
    WHERE request_id = 'test-match-request-001' AND candidate_id = 'test-member-002'
);

INSERT INTO nlp.nlp_feedback(
    match_result_id, request_id, requester_id, candidate_id, label, reason_code
)
SELECT mr.match_result_id, mr.request_id, mr.requester_id, mr.candidate_id,
       'USEFUL', 'TEST_RELEVANT'
FROM nlp.nlp_match_result mr
WHERE mr.request_id = 'test-match-request-001' AND mr.candidate_id = 'test-member-002'
  AND NOT EXISTS (
      SELECT 1 FROM nlp.nlp_feedback f
      WHERE f.match_result_id = mr.match_result_id AND f.label = 'USEFUL'
  );

INSERT INTO nlp.match_suppression(
    member_id, intent_id, context_id, reason_code, starts_at, ends_at, created_by
)
SELECT 'test-member-002', 'test-intent-offer-001', 'test-event-001', 'TEST_EXPIRED',
       CURRENT_TIMESTAMP - interval '2 days', CURRENT_TIMESTAMP - interval '1 day', 'seed:test-data'
WHERE NOT EXISTS (
    SELECT 1 FROM nlp.match_suppression
    WHERE intent_id = 'test-intent-offer-001' AND reason_code = 'TEST_EXPIRED'
);

INSERT INTO nlp.evaluation_dataset(
    dataset_id, name, version, description, source_policy, status, approved_by
)
VALUES (
    'test-evaluation-dataset-001', 'Test reciprocal matching dataset', 'test-v1',
    'Synthetic, de-identified fixture data.', 'Synthetic data only; no member content.',
    'APPROVED', 'test-member-003-admin'
)
ON CONFLICT (dataset_id) DO NOTHING;

INSERT INTO nlp.evaluation_pair(
    dataset_id, requester_intent_text, candidate_intent_text,
    structured_features_json, gold_label, split, organization_group, label_reason
)
SELECT 'test-evaluation-dataset-001', 'Seeking an engineering partner.',
       'Offering engineering partnership expertise.',
       '{"category":"PARTNERSHIP","industry":"TECHNOLOGY"}'::jsonb,
       'STRONG', 'TEST', 'synthetic-group-001', 'Synthetic reciprocal match.'
WHERE NOT EXISTS (
    SELECT 1 FROM nlp.evaluation_pair
    WHERE dataset_id = 'test-evaluation-dataset-001' AND organization_group = 'synthetic-group-001'
);

INSERT INTO nlp.evaluation_run(
    evaluation_run_id, dataset_id, model_version, ranking_version, status,
    metrics_json, started_at, completed_at
)
VALUES (
    'test-evaluation-run-001', 'test-evaluation-dataset-001', 'test-embedding-v1',
    'ranking-v1', 'PASSED', '{"precision_at_5":1.0,"coverage":1.0}'::jsonb,
    CURRENT_TIMESTAMP - interval '2 minutes', CURRENT_TIMESTAMP - interval '1 minute'
)
ON CONFLICT (evaluation_run_id) DO NOTHING;

-- Accepted requests and their canonical connection must commit together.
INSERT INTO social.connection_request(
    connection_request_id, sender_member_id, recipient_member_id, context_id,
    match_result_id, note, status, expires_at, responded_at
)
SELECT 'test-connection-request-001', 'test-member-001', 'test-member-002',
       'test-event-001', mr.match_result_id, 'Would you like to connect?', 'ACCEPTED',
       CURRENT_TIMESTAMP + interval '30 days', CURRENT_TIMESTAMP
FROM nlp.nlp_match_result mr
WHERE mr.request_id = 'test-match-request-001' AND mr.candidate_id = 'test-member-002'
ON CONFLICT (connection_request_id) DO NOTHING;

INSERT INTO social.connection(
    connection_id, member_low_id, member_high_id, accepted_request_id, status
)
VALUES (
    'test-connection-001', 'test-member-001', 'test-member-002',
    'test-connection-request-001', 'ACTIVE'
)
ON CONFLICT (connection_id) DO NOTHING;

INSERT INTO social.member_block(
    blocker_member_id, blocked_member_id, reason_code, created_at, removed_at
)
SELECT 'test-member-001', 'test-member-003-admin', 'TEST_RESOLVED',
       CURRENT_TIMESTAMP - interval '2 days', CURRENT_TIMESTAMP - interval '1 day'
WHERE NOT EXISTS (
    SELECT 1 FROM social.member_block
    WHERE blocker_member_id = 'test-member-001'
      AND blocked_member_id = 'test-member-003-admin'
      AND reason_code = 'TEST_RESOLVED'
);

INSERT INTO social.member_report(
    report_id, reporter_member_id, reported_member_id, resource_type,
    resource_id, category, description, status
)
VALUES (
    'test-report-001', 'test-member-001', 'test-member-003-admin', 'PROFILE',
    'test-member-003-admin', 'TEST_CATEGORY', 'Synthetic report for workflow testing.', 'OPEN'
)
ON CONFLICT (report_id) DO NOTHING;

INSERT INTO chat.conversation(conversation_id, connection_id, status)
VALUES ('test-conversation-001', 'test-connection-001', 'ACTIVE')
ON CONFLICT (conversation_id) DO NOTHING;

INSERT INTO chat.conversation_participant(conversation_id, member_id)
VALUES
    ('test-conversation-001', 'test-member-001'),
    ('test-conversation-001', 'test-member-002')
ON CONFLICT (conversation_id, member_id) DO NOTHING;

INSERT INTO chat.message(
    message_id, conversation_id, sender_member_id, message_type, body,
    client_sent_at, moderation_status
)
VALUES (
    'test-message-001', 'test-conversation-001', 'test-member-001', 'TEXT',
    'Hello from the OLGA test fixture.', CURRENT_TIMESTAMP, 'CLEAR'
)
ON CONFLICT (message_id) DO NOTHING;

INSERT INTO chat.message_receipt(message_id, member_id, delivered_at, read_at)
VALUES (
    'test-message-001', 'test-member-002',
    CURRENT_TIMESTAMP - interval '1 minute', CURRENT_TIMESTAMP
)
ON CONFLICT (message_id, member_id) DO NOTHING;

INSERT INTO storage.file_asset_link(
    file_asset_id, resource_type, resource_id, relationship_type, linked_by
)
SELECT 'test-file-001', 'MEMBER_VERIFICATION', 'test-verification-001', 'EVIDENCE',
       'test-member-003-admin'
WHERE NOT EXISTS (
    SELECT 1 FROM storage.file_asset_link
    WHERE file_asset_id = 'test-file-001'
      AND resource_type = 'MEMBER_VERIFICATION'
      AND resource_id = 'test-verification-001'
      AND relationship_type = 'EVIDENCE'
);

INSERT INTO notification.notification_policy(
    community_id, purpose_code, channel, policy_version, status,
    member_opt_out_allowed, quiet_hours_behavior, dedupe_window_seconds,
    max_per_hour, max_per_day, max_attempts, retry_schedule_seconds,
    ttl_minutes, effective_from
)
SELECT 'test-community-001', 'MATCH', 'PUSH', 1, 'ACTIVE', true, 'DEFER',
       300, 6, 30, 3, '60,300,1800', 1440, CURRENT_TIMESTAMP - interval '1 day'
WHERE NOT EXISTS (
    SELECT 1 FROM notification.notification_policy
    WHERE community_id = 'test-community-001' AND purpose_code = 'MATCH'
      AND channel = 'PUSH' AND policy_version = 1
);

INSERT INTO notification.notification_preference(
    member_id, purpose_code, push_enabled, email_enabled,
    quiet_start_local, quiet_end_local, timezone_id
)
VALUES (
    'test-member-001', 'MATCH', true, false, TIME '22:00', TIME '07:00', 'Asia/Kolkata'
)
ON CONFLICT (member_id, purpose_code) DO NOTHING;

INSERT INTO notification.push_token(
    device_id, provider, token_ciphertext, status, token_fingerprint
)
SELECT 'test-device-001', 'FCM', decode('746573742d707573682d746f6b656e', 'hex'),
       'ACTIVE', repeat('9', 64)
WHERE NOT EXISTS (
    SELECT 1 FROM notification.push_token WHERE token_fingerprint = repeat('9', 64)
);

INSERT INTO notification.notification(
    notification_id, member_id, notification_policy_id, event_matching_policy_id,
    purpose_code, channel, resource_type, resource_id, template_code,
    dedupe_key, dedupe_bucket_start, source_confidence, context_id, status,
    scheduled_at, expires_at, attempt_count, sent_at
)
SELECT 'test-notification-001', 'test-member-001', np.notification_policy_id,
       emp.event_matching_policy_id, 'MATCH', 'PUSH', 'MATCH', mr.match_result_id::varchar(64),
       'MATCH_FOUND_V1', 'test:match:test-member-001:test-match-request-001',
       date_trunc('hour', CURRENT_TIMESTAMP), 0.81000, 'test-event-001', 'SENT',
       CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + interval '1 day', 1, CURRENT_TIMESTAMP
FROM notification.notification_policy np
CROSS JOIN event.event_matching_policy emp
CROSS JOIN nlp.nlp_match_result mr
WHERE np.community_id = 'test-community-001' AND np.purpose_code = 'MATCH'
  AND np.channel = 'PUSH' AND np.policy_version = 1
  AND emp.event_id = 'test-event-001' AND emp.policy_version = 1
  AND mr.request_id = 'test-match-request-001' AND mr.candidate_id = 'test-member-002'
ON CONFLICT (notification_id) DO NOTHING;

INSERT INTO notification.notification_delivery_attempt(
    notification_id, attempt_number, provider, push_token_id,
    provider_message_id, status, attempted_at, acknowledged_at, duration_ms
)
SELECT 'test-notification-001', 1, 'FCM', pt.push_token_id,
       'test-provider-message-001', 'ACCEPTED', CURRENT_TIMESTAMP - interval '1 minute',
       CURRENT_TIMESTAMP, 120
FROM notification.push_token pt
WHERE pt.token_fingerprint = repeat('9', 64)
  AND NOT EXISTS (
      SELECT 1 FROM notification.notification_delivery_attempt a
      WHERE a.notification_id = 'test-notification-001' AND a.attempt_number = 1
  );

INSERT INTO moderation.moderation_case(
    moderation_case_id, source_type, source_id, subject_member_id,
    resource_type, resource_id, priority, status, assigned_to
)
VALUES (
    'test-moderation-case-001', 'MEMBER_REPORT', 'test-report-001',
    'test-member-003-admin', 'PROFILE', 'test-member-003-admin',
    'NORMAL', 'TRIAGED', 'test-member-003-admin'
)
ON CONFLICT (moderation_case_id) DO NOTHING;

INSERT INTO moderation.moderation_action(
    moderation_case_id, actor_member_id, action_type, reason_code, notes
)
SELECT 'test-moderation-case-001', 'test-member-003-admin', 'REVIEW',
       'TEST_REVIEWED', 'Synthetic moderation action.'
WHERE NOT EXISTS (
    SELECT 1 FROM moderation.moderation_action
    WHERE moderation_case_id = 'test-moderation-case-001' AND reason_code = 'TEST_REVIEWED'
);

INSERT INTO moderation.content_rule(
    content_rule_id, rule_type, version, config_json, status, active_from, created_by
)
VALUES (
    'test-content-rule-001', 'TERM', 'test-v1', '{"blocked_terms":["synthetic-test-term"]}'::jsonb,
    'ACTIVE', CURRENT_TIMESTAMP - interval '1 day', 'test-member-003-admin'
)
ON CONFLICT (content_rule_id) DO NOTHING;

INSERT INTO moderation.content_scan(
    resource_type, resource_id, scanner, scanner_version, result, reason_codes
)
SELECT 'FILE_ASSET', 'test-file-001', 'test-scanner', '1.0', 'CLEAN', '[]'::jsonb
WHERE NOT EXISTS (
    SELECT 1 FROM moderation.content_scan
    WHERE resource_type = 'FILE_ASSET' AND resource_id = 'test-file-001'
      AND scanner = 'test-scanner'
);

INSERT INTO ops.sync_change(
    community_id, member_scope_id, resource_type, resource_id, change_type,
    resource_version, payload_json, occurred_at, expires_at
)
SELECT 'test-community-001', 'test-member-001', 'PROFILE', 'test-member-001',
       'UPSERT', 1, '{"display_name":"Asha Test"}'::jsonb,
       CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + interval '30 days'
WHERE NOT EXISTS (
    SELECT 1 FROM ops.sync_change
    WHERE community_id = 'test-community-001' AND member_scope_id = 'test-member-001'
      AND resource_type = 'PROFILE' AND resource_id = 'test-member-001'
);

INSERT INTO ops.retention_policy(
    resource_type, policy_version, status, retention_days, disposition_action,
    legal_hold_supported, effective_from, approved_by
)
SELECT 'TEST_RESOURCE', 1, 'ACTIVE', 30, 'DELETE', true,
       CURRENT_TIMESTAMP - interval '1 day', 'test-member-003-admin'
WHERE NOT EXISTS (
    SELECT 1 FROM ops.retention_policy
    WHERE resource_type = 'TEST_RESOURCE' AND policy_version = 1
);

INSERT INTO ops.retention_execution(
    retention_execution_id, retention_policy_id, scope_start, scope_end,
    status, examined_count, disposed_count, skipped_hold_count,
    evidence_hash, started_at, completed_at
)
SELECT 'test-retention-execution-001', rp.retention_policy_id,
       CURRENT_TIMESTAMP - interval '31 days', CURRENT_TIMESTAMP - interval '30 days',
       'SUCCEEDED', 1, 1, 0, repeat('a', 64),
       CURRENT_TIMESTAMP - interval '2 minutes', CURRENT_TIMESTAMP - interval '1 minute'
FROM ops.retention_policy rp
WHERE rp.resource_type = 'TEST_RESOURCE' AND rp.policy_version = 1
ON CONFLICT (retention_execution_id) DO NOTHING;

INSERT INTO ops.outbox_event(
    outbox_event_id, aggregate_type, aggregate_id, event_type,
    payload_json, published_at, attempt_count
)
VALUES (
    'test-outbox-event-001', 'MEMBER', 'test-member-001', 'member.test_fixture_created.v1',
    '{"member_id":"test-member-001"}'::jsonb, CURRENT_TIMESTAMP, 1
)
ON CONFLICT (outbox_event_id) DO NOTHING;

INSERT INTO ops.idempotency_record(
    scope, idempotency_key, actor_id, request_hash,
    status_code, response_ref, expires_at
)
VALUES (
    'test-fixture', 'test-idempotency-key-001', 'test-member-001', repeat('b', 64),
    201, '/v1/test-resources/test-001', CURRENT_TIMESTAMP + interval '1 day'
)
ON CONFLICT (scope, actor_id, idempotency_key) DO NOTHING;

INSERT INTO ops.background_job(
    background_job_id, job_type, resource_type, resource_id,
    payload_json, status, attempt_count
)
VALUES (
    'test-background-job-001', 'SCAN_FILE', 'FILE_ASSET', 'test-file-001',
    '{"test_fixture":true}'::jsonb, 'SUCCEEDED', 1
)
ON CONFLICT (background_job_id) DO NOTHING;

INSERT INTO ops.audit_event(
    actor_type, actor_id, action, resource_type, resource_id,
    outcome, correlation_id, metadata_json
)
SELECT 'ADMIN', 'test-member-003-admin', 'test.fixture.created', 'COMMUNITY',
       'test-community-001', 'SUCCESS', 'test-correlation-001',
       '{"source":"seed_test_data.sql"}'::jsonb
WHERE NOT EXISTS (
    SELECT 1 FROM ops.audit_event
    WHERE correlation_id = 'test-correlation-001' AND action = 'test.fixture.created'
);

INSERT INTO analytics.product_event(
    product_event_id, event_name, member_pseudonym, community_id,
    context_type, context_id, properties_json, occurred_at
)
VALUES (
    'test-product-event-001', 'MATCH_VIEWED', repeat('c', 64), 'test-community-001',
    'EVENT', 'test-event-001', '{"rank":1,"test_fixture":true}'::jsonb, CURRENT_TIMESTAMP
)
ON CONFLICT (product_event_id) DO NOTHING;

-- Fail the transaction if a future application table is added without corresponding seed coverage.
DO $verify$
DECLARE
    target record;
    row_exists boolean;
BEGIN
    FOR target IN
        SELECT schemaname, tablename
        FROM pg_catalog.pg_tables
        WHERE schemaname IN (
            'core', 'iam', 'consent', 'event', 'social', 'chat', 'storage',
            'notification', 'nlp', 'moderation', 'ops', 'analytics'
        )
        ORDER BY schemaname, tablename
    LOOP
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.%I)', target.schemaname, target.tablename)
        INTO row_exists;
        IF NOT row_exists THEN
            RAISE EXCEPTION 'Test seed left %.% empty.', target.schemaname, target.tablename;
        END IF;
    END LOOP;
END;
$verify$;

COMMIT;
