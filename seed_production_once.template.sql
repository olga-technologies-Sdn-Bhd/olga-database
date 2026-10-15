/*
OLGA Connect - one-time production reference/configuration seed

Manual DBeaver procedure:
1. Obtain the approved values listed in docs/production-seed-readiness.md.
2. Replace the empty input sections below with literal VALUES rows.
3. Set activate_baseline_notification_policies to true only after Product/Ops
   approves the policy values already defined in 050_seed.sql.
4. Connect to olga_connect_prod and use Execute SQL Script (Alt+X).

The script is rerunnable. Existing versioned rows are never overwritten. A
conflicting row or an incomplete required input aborts the transaction.
*/
BEGIN;

DO $deployment_guard$
BEGIN
    IF current_database() <> 'olga_connect_prod' THEN
        RAISE EXCEPTION
            'Production seed stopped: connected to database %, expected olga_connect_prod.',
            current_database();
    END IF;
END;
$deployment_guard$;

SELECT pg_advisory_xact_lock(hashtextextended('olga_production_seed', 0));

CREATE TEMP TABLE production_seed_setting (
    activate_baseline_notification_policies boolean NOT NULL
) ON COMMIT DROP;

-- Change to true only after the six policies in 050_seed.sql are approved.
INSERT INTO production_seed_setting(activate_baseline_notification_policies)
VALUES (false);

CREATE TEMP TABLE production_consent_seed (
    policy_id varchar(64) PRIMARY KEY,
    purpose_code varchar(64) NOT NULL,
    version varchar(32) NOT NULL,
    locale varchar(16) NOT NULL,
    content_hash char(64) NOT NULL,
    effective_from timestamptz NOT NULL
) ON COMMIT DROP;

/* Required: hashes must be SHA-256 of the exact text displayed by the app.
INSERT INTO production_consent_seed VALUES
    ('live-mode-consent-prod-v1', 'LIVE_MODE', 'prod-v1', 'en-IN', '<64 lowercase hex characters>', '2026-10-12T00:00:00+05:30'),
    ('matching-consent-prod-v1',  'MATCHING',  'prod-v1', 'en-IN', '<64 lowercase hex characters>', '2026-10-12T00:00:00+05:30');
*/

CREATE TEMP TABLE production_sector_seed (
    sector_code varchar(64) PRIMARY KEY,
    parent_sector_code varchar(64) NULL,
    name varchar(150) NOT NULL,
    status varchar(16) NOT NULL,
    sort_order int NOT NULL
) ON COMMIT DROP;

/* Required: replace with the approved complete taxonomy.
INSERT INTO production_sector_seed VALUES
    ('TELECOM',    NULL, 'Telecom',    'ACTIVE', 10),
    ('GOVERNMENT', NULL, 'Government', 'ACTIVE', 20),
    ('VENTURE',    NULL, 'Venture',    'ACTIVE', 30),
    ('EDUCATION',  NULL, 'Education',  'ACTIVE', 40);
*/

CREATE TEMP TABLE production_venue_seed (
    venue_id varchar(64) PRIMARY KEY,
    name varchar(200) NOT NULL,
    country_code char(2) NOT NULL,
    region varchar(120) NULL,
    city varchar(120) NULL,
    coarse_geo_cell varchar(32) NULL,
    timezone_id varchar(64) NOT NULL,
    status varchar(16) NOT NULL
) ON COMMIT DROP;

/* Optional until the first real event is created.
INSERT INTO production_venue_seed VALUES
    ('<stable-venue-id>', '<name>', 'IN', '<state>', '<city>', '<approved coarse cell>', 'Asia/Kolkata', 'ACTIVE');
*/

CREATE TEMP TABLE production_event_policy_seed (
    event_id varchar(64) PRIMARY KEY,
    policy_version smallint NOT NULL,
    registration_required boolean NOT NULL,
    check_in_required boolean NOT NULL,
    live_mode_required boolean NOT NULL,
    proximity_mode varchar(24) NOT NULL,
    max_presence_age_minutes smallint NULL,
    match_threshold_override numeric(6,5) NULL,
    alert_confidence_threshold numeric(6,5) NOT NULL,
    max_match_alerts_per_hour smallint NOT NULL,
    max_match_alerts_per_event smallint NOT NULL,
    minimum_alert_interval_minutes smallint NOT NULL,
    effective_from timestamptz NOT NULL
) ON COMMIT DROP;

/* Required for every PUBLISHED/ACTIVE event with Live Mode enabled.
INSERT INTO production_event_policy_seed VALUES
    ('<existing-event-id>', 1, true, true, true, 'VENUE', 15, NULL, 0.70000, 2, 10, 30,
     '2026-10-12T00:00:00+05:30');
*/

CREATE TEMP TABLE production_retention_seed (
    resource_type varchar(64) PRIMARY KEY,
    policy_version smallint NOT NULL,
    retention_days int NOT NULL,
    disposition_action varchar(20) NOT NULL,
    legal_hold_supported boolean NOT NULL,
    effective_from timestamptz NOT NULL,
    approved_by varchar(64) NULL
) ON COMMIT DROP;

/* Required: one row per data class approved by Legal/Privacy.
INSERT INTO production_retention_seed VALUES
    ('<resource-type>', 1, <days>, '<DELETE|ANONYMIZE|ARCHIVE>', true,
     '2026-10-12T00:00:00+05:30', '<existing-admin-member-id>');
*/

CREATE TEMP TABLE production_content_rule_seed (
    content_rule_id varchar(64) PRIMARY KEY,
    rule_type varchar(32) NOT NULL,
    version varchar(32) NOT NULL,
    config_json jsonb NOT NULL,
    active_from timestamptz NOT NULL,
    created_by varchar(64) NOT NULL
) ON COMMIT DROP;

/* Required: validated worker/API configuration and an existing admin member.
INSERT INTO production_content_rule_seed VALUES
    ('<stable-rule-id>', '<FILE_TYPE|TERM|RATE|POLICY>', 'prod-v1', '<approved JSON>'::jsonb,
     '2026-10-12T00:00:00+05:30', '<existing-admin-member-id>');
*/

DO $input_validation$
BEGIN
    IF (
        NOT EXISTS (
            SELECT 1 FROM production_consent_seed
            WHERE purpose_code = 'LIVE_MODE' AND locale = 'en-IN'
        ) AND NOT EXISTS (
            SELECT 1 FROM consent.consent_policy
            WHERE purpose_code = 'LIVE_MODE' AND locale = 'en-IN'
              AND effective_from <= CURRENT_TIMESTAMP AND retired_at IS NULL
        )
    ) OR (
        NOT EXISTS (
            SELECT 1 FROM production_consent_seed
            WHERE purpose_code = 'MATCHING' AND locale = 'en-IN'
        ) AND NOT EXISTS (
            SELECT 1 FROM consent.consent_policy
            WHERE purpose_code = 'MATCHING' AND locale = 'en-IN'
              AND effective_from <= CURRENT_TIMESTAMP AND retired_at IS NULL
        )
    ) THEN
        RAISE EXCEPTION 'Approved active en-IN LIVE_MODE and MATCHING consent rows must exist or be supplied.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM production_consent_seed
        WHERE content_hash::text !~ '^[0-9a-f]{64}$'
           OR effective_from > CURRENT_TIMESTAMP
    ) THEN
        RAISE EXCEPTION 'Consent hashes must be lowercase SHA-256 values and effective_from must not be in the future.';
    END IF;

    IF EXISTS (
        SELECT purpose_code, locale
        FROM production_consent_seed
        GROUP BY purpose_code, locale
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'Supply only one current consent version per purpose and locale.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM production_consent_seed input
        JOIN consent.consent_policy actual
          ON actual.purpose_code = input.purpose_code
         AND actual.locale = input.locale
         AND actual.retired_at IS NULL
         AND actual.policy_id <> input.policy_id
    ) THEN
        RAISE EXCEPTION 'Retire the existing consent version explicitly before supplying its replacement.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM production_sector_seed)
       AND NOT EXISTS (SELECT 1 FROM core.sector WHERE status = 'ACTIVE') THEN
        RAISE EXCEPTION 'An approved active sector taxonomy must exist or be supplied.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM production_sector_seed
        WHERE status NOT IN ('ACTIVE', 'RETIRED')
           OR parent_sector_code = sector_code
    ) THEN
        RAISE EXCEPTION 'Sector input contains an invalid status or self-parent.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM production_sector_seed child
        WHERE child.parent_sector_code IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM production_sector_seed parent
              WHERE parent.sector_code = child.parent_sector_code
          )
          AND NOT EXISTS (
              SELECT 1 FROM core.sector parent
              WHERE parent.sector_code = child.parent_sector_code
          )
    ) THEN
        RAISE EXCEPTION 'Every sector parent must exist in the input or already exist in core.sector.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM production_venue_seed
        WHERE status NOT IN ('ACTIVE', 'RETIRED')
           OR country_code::text !~ '^[A-Z]{2}$'
    ) THEN
        RAISE EXCEPTION 'Venue input contains an invalid status or ISO alpha-2 country code.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM production_event_policy_seed input
        LEFT JOIN event.event e ON e.event_id = input.event_id
        WHERE e.event_id IS NULL
    ) THEN
        RAISE EXCEPTION 'Every event policy input must reference an existing event.event row.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM production_event_policy_seed
        WHERE policy_version <= 0
           OR proximity_mode NOT IN ('NONE', 'VENUE', 'COARSE_CELL')
           OR (check_in_required AND NOT registration_required)
           OR (proximity_mode = 'COARSE_CELL' AND
               (NOT live_mode_required OR max_presence_age_minutes IS NULL OR max_presence_age_minutes <= 0))
           OR (match_threshold_override IS NOT NULL AND match_threshold_override NOT BETWEEN 0 AND 1)
           OR alert_confidence_threshold NOT BETWEEN 0 AND 1
           OR max_match_alerts_per_hour < 0
           OR max_match_alerts_per_event < 0
           OR minimum_alert_interval_minutes < 0
           OR effective_from > CURRENT_TIMESTAMP
    ) THEN
        RAISE EXCEPTION 'Event matching policy input violates schema or activation rules.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM production_retention_seed)
       AND NOT EXISTS (
           SELECT 1 FROM ops.retention_policy
           WHERE status = 'ACTIVE' AND effective_from <= CURRENT_TIMESTAMP
             AND (effective_to IS NULL OR effective_to > CURRENT_TIMESTAMP)
       ) THEN
        RAISE EXCEPTION 'Legal/Privacy-approved active retention policies must exist or be supplied.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM production_retention_seed input
        LEFT JOIN iam.member approver ON approver.member_id = input.approved_by
        WHERE input.policy_version <= 0
           OR input.retention_days < 0
           OR input.disposition_action NOT IN ('DELETE', 'ANONYMIZE', 'ARCHIVE')
           OR input.effective_from > CURRENT_TIMESTAMP
           OR input.approved_by IS NULL
           OR approver.member_id IS NULL
    ) THEN
        RAISE EXCEPTION 'Retention input is invalid or approved_by is not an existing member.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM production_content_rule_seed)
       AND NOT EXISTS (
           SELECT 1 FROM moderation.content_rule
           WHERE status = 'ACTIVE' AND active_from <= CURRENT_TIMESTAMP
       ) THEN
        RAISE EXCEPTION 'Security/Product-approved active moderation rules must exist or be supplied.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM production_content_rule_seed input
        LEFT JOIN iam.member creator ON creator.member_id = input.created_by
        WHERE input.rule_type NOT IN ('FILE_TYPE', 'TERM', 'RATE', 'POLICY')
           OR input.effective_from > CURRENT_TIMESTAMP
           OR creator.member_id IS NULL
    ) THEN
        RAISE EXCEPTION 'Content-rule input is invalid or created_by is not an existing member.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM event.event e
        WHERE e.status IN ('PUBLISHED', 'ACTIVE')
          AND e.live_mode_enabled
          AND NOT EXISTS (
              SELECT 1 FROM event.event_matching_policy current_policy
              WHERE current_policy.event_id = e.event_id
                AND current_policy.status = 'ACTIVE'
                AND current_policy.effective_from <= CURRENT_TIMESTAMP
                AND (current_policy.effective_to IS NULL OR current_policy.effective_to > CURRENT_TIMESTAMP)
          )
          AND NOT EXISTS (
              SELECT 1 FROM production_event_policy_seed input
              WHERE input.event_id = e.event_id
          )
    ) THEN
        RAISE EXCEPTION 'At least one published/active Live Mode event has neither an active policy nor an input row.';
    END IF;
END;
$input_validation$;

-- Reuse the canonical baseline rather than maintaining a second copy.
SELECT set_config(
    'olga.seed_mvp_policies',
    CASE WHEN activate_baseline_notification_policies THEN '1' ELSE '0' END,
    true
)
FROM production_seed_setting;

@include 050_seed.sql

INSERT INTO consent.consent_policy(
    policy_id, purpose_code, version, locale, content_hash, effective_from
)
SELECT policy_id, purpose_code, version, locale, content_hash, effective_from
FROM production_consent_seed
ON CONFLICT (policy_id) DO NOTHING;

INSERT INTO core.sector(sector_code, parent_sector_code, name, status, sort_order)
SELECT sector_code, parent_sector_code, name, status, sort_order
FROM production_sector_seed
ON CONFLICT (sector_code) DO NOTHING;

INSERT INTO event.venue(
    venue_id, name, country_code, region, city, coarse_geo_cell, timezone_id, status
)
SELECT venue_id, name, country_code, region, city, coarse_geo_cell, timezone_id, status
FROM production_venue_seed
ON CONFLICT (venue_id) DO NOTHING;

INSERT INTO event.event_matching_policy(
    event_id, policy_version, status, registration_required, check_in_required,
    live_mode_required, proximity_mode, max_presence_age_minutes,
    match_threshold_override, alert_confidence_threshold, max_match_alerts_per_hour,
    max_match_alerts_per_event, minimum_alert_interval_minutes, effective_from
)
SELECT event_id, policy_version, 'ACTIVE', registration_required, check_in_required,
       live_mode_required, proximity_mode, max_presence_age_minutes,
       match_threshold_override, alert_confidence_threshold, max_match_alerts_per_hour,
       max_match_alerts_per_event, minimum_alert_interval_minutes, effective_from
FROM production_event_policy_seed
ON CONFLICT (event_id, policy_version) DO NOTHING;

INSERT INTO ops.retention_policy(
    resource_type, policy_version, status, retention_days, disposition_action,
    legal_hold_supported, effective_from, approved_by
)
SELECT resource_type, policy_version, 'ACTIVE', retention_days, disposition_action,
       legal_hold_supported, effective_from, approved_by
FROM production_retention_seed
ON CONFLICT (resource_type, policy_version) DO NOTHING;

INSERT INTO moderation.content_rule(
    content_rule_id, rule_type, version, config_json, status, active_from, created_by
)
SELECT content_rule_id, rule_type, version, config_json, 'ACTIVE', active_from, created_by
FROM production_content_rule_seed
ON CONFLICT (content_rule_id) DO NOTHING;

DO $result_verification$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM production_consent_seed input
        LEFT JOIN consent.consent_policy actual USING (policy_id)
        WHERE actual.policy_id IS NULL
           OR (actual.purpose_code, actual.version, actual.locale, actual.content_hash, actual.effective_from)
              IS DISTINCT FROM
              (input.purpose_code, input.version, input.locale, input.content_hash, input.effective_from)
           OR actual.retired_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Consent verification failed; an existing row conflicts with the approved input.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM production_sector_seed input
        LEFT JOIN core.sector actual USING (sector_code)
        WHERE actual.sector_code IS NULL
           OR (actual.parent_sector_code, actual.name, actual.status, actual.sort_order)
              IS DISTINCT FROM
              (input.parent_sector_code, input.name, input.status, input.sort_order)
    ) THEN
        RAISE EXCEPTION 'Sector verification failed; an existing row conflicts with the approved input.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM production_venue_seed input
        LEFT JOIN event.venue actual USING (venue_id)
        WHERE actual.venue_id IS NULL
           OR (actual.name, actual.country_code, actual.region, actual.city,
               actual.coarse_geo_cell, actual.timezone_id, actual.status)
              IS DISTINCT FROM
              (input.name, input.country_code, input.region, input.city,
               input.coarse_geo_cell, input.timezone_id, input.status)
    ) THEN
        RAISE EXCEPTION 'Venue verification failed; an existing row conflicts with the approved input.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM production_event_policy_seed input
        LEFT JOIN event.event_matching_policy actual
          ON actual.event_id = input.event_id
         AND actual.policy_version = input.policy_version
        WHERE actual.event_matching_policy_id IS NULL
           OR actual.status <> 'ACTIVE'
           OR (actual.registration_required, actual.check_in_required, actual.live_mode_required,
               actual.proximity_mode, actual.max_presence_age_minutes,
               actual.match_threshold_override, actual.alert_confidence_threshold,
               actual.max_match_alerts_per_hour, actual.max_match_alerts_per_event,
               actual.minimum_alert_interval_minutes, actual.effective_from)
              IS DISTINCT FROM
              (input.registration_required, input.check_in_required, input.live_mode_required,
               input.proximity_mode, input.max_presence_age_minutes,
               input.match_threshold_override, input.alert_confidence_threshold,
               input.max_match_alerts_per_hour, input.max_match_alerts_per_event,
               input.minimum_alert_interval_minutes, input.effective_from)
    ) THEN
        RAISE EXCEPTION 'Event matching policy verification failed; an existing row conflicts with the approved input.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM production_retention_seed input
        LEFT JOIN ops.retention_policy actual
          ON actual.resource_type = input.resource_type
         AND actual.policy_version = input.policy_version
        WHERE actual.retention_policy_id IS NULL
           OR actual.status <> 'ACTIVE'
           OR (actual.retention_days, actual.disposition_action,
               actual.legal_hold_supported, actual.effective_from, actual.approved_by)
              IS DISTINCT FROM
              (input.retention_days, input.disposition_action,
               input.legal_hold_supported, input.effective_from, input.approved_by)
    ) THEN
        RAISE EXCEPTION 'Retention policy verification failed; an existing row conflicts with the approved input.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM production_content_rule_seed input
        LEFT JOIN moderation.content_rule actual USING (content_rule_id)
        WHERE actual.content_rule_id IS NULL
           OR actual.status <> 'ACTIVE'
           OR (actual.rule_type, actual.version, actual.config_json,
               actual.active_from, actual.created_by)
              IS DISTINCT FROM
              (input.rule_type, input.version, input.config_json,
               input.active_from, input.created_by)
    ) THEN
        RAISE EXCEPTION 'Content-rule verification failed; an existing row conflicts with the approved input.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM consent.consent_policy
        WHERE purpose_code = 'LIVE_MODE' AND locale = 'en-IN'
          AND effective_from <= CURRENT_TIMESTAMP AND retired_at IS NULL
    ) OR NOT EXISTS (
        SELECT 1 FROM consent.consent_policy
        WHERE purpose_code = 'MATCHING' AND locale = 'en-IN'
          AND effective_from <= CURRENT_TIMESTAMP AND retired_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Required active production consent policies are missing after seed.';
    END IF;

    IF EXISTS (
        SELECT purpose_code, locale
        FROM consent.consent_policy
        WHERE purpose_code IN ('LIVE_MODE', 'MATCHING')
          AND locale = 'en-IN'
          AND effective_from <= CURRENT_TIMESTAMP
          AND retired_at IS NULL
        GROUP BY purpose_code, locale
        HAVING count(*) <> 1
    ) THEN
        RAISE EXCEPTION 'Exactly one active en-IN consent version is required for LIVE_MODE and MATCHING.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM core.sector WHERE status = 'ACTIVE') THEN
        RAISE EXCEPTION 'No active production sector exists after seed.';
    END IF;
END;
$result_verification$;

SELECT 'community' AS configuration, count(*) AS active_count
FROM core.community WHERE community_id = 'olga' AND status = 'ACTIVE'
UNION ALL
SELECT 'consent_policy', count(*) FROM consent.consent_policy
WHERE retired_at IS NULL AND effective_from <= CURRENT_TIMESTAMP
UNION ALL
SELECT 'sector', count(*) FROM core.sector WHERE status = 'ACTIVE'
UNION ALL
SELECT 'venue', count(*) FROM event.venue WHERE status = 'ACTIVE'
UNION ALL
SELECT 'event_matching_policy', count(*) FROM event.event_matching_policy
WHERE status = 'ACTIVE' AND effective_from <= CURRENT_TIMESTAMP
  AND (effective_to IS NULL OR effective_to > CURRENT_TIMESTAMP)
UNION ALL
SELECT 'notification_policy', count(*) FROM notification.notification_policy
WHERE status = 'ACTIVE' AND effective_from <= CURRENT_TIMESTAMP
  AND (effective_to IS NULL OR effective_to > CURRENT_TIMESTAMP)
UNION ALL
SELECT 'retention_policy', count(*) FROM ops.retention_policy
WHERE status = 'ACTIVE' AND effective_from <= CURRENT_TIMESTAMP
  AND (effective_to IS NULL OR effective_to > CURRENT_TIMESTAMP)
UNION ALL
SELECT 'content_rule', count(*) FROM moderation.content_rule
WHERE status = 'ACTIVE' AND active_from <= CURRENT_TIMESTAMP;

COMMIT;
