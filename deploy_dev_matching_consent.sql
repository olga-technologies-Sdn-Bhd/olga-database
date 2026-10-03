/*
Development-only matching-consent publication for an existing database.

Run with Execute SQL Script as the migration identity. The script is rerunnable,
targets only the three explicitly listed development events, and refuses to run
outside olga_connect_dev.

The application must display this exact UTF-8 text when recording consent:
I consent to OLGA using my profile, intent, and event participation data to generate matching recommendations.

SHA-256:
631c2062a3a65f119bdc084a8d9acfae3e27d784aff8058c8e2321d39beacba3
*/
BEGIN;

DO $deployment_guard$
BEGIN
    IF current_database() <> 'olga_connect_dev' THEN
        RAISE EXCEPTION
            'Matching consent deployment stopped: connected to database %, expected olga_connect_dev.',
            current_database();
    END IF;
END;
$deployment_guard$;

SELECT pg_advisory_xact_lock(hashtextextended('olga_schema_migration', 0));

CREATE TEMP TABLE dev_matching_deployment_parameter(
    event_id varchar(64) PRIMARY KEY
) ON COMMIT DROP;

INSERT INTO dev_matching_deployment_parameter(event_id)
VALUES
    ('test-event-001'),
    ('evt_c26f6facca7b6616ef2df74d120a7c3e'),
    ('evt_e0cf28419c4f685f67fcd781074ed355');

DO $event_guard$
DECLARE
    v_event_id varchar(64);
BEGIN
    FOR v_event_id IN SELECT event_id FROM dev_matching_deployment_parameter LOOP
        IF NOT EXISTS (SELECT 1 FROM event.event WHERE event_id = v_event_id) THEN
            RAISE EXCEPTION 'Development test event % does not exist.', v_event_id;
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM event.event_matching_policy
            WHERE event_id = v_event_id
              AND status = 'ACTIVE'
              AND effective_from <= CURRENT_TIMESTAMP
              AND (effective_to IS NULL OR effective_to > CURRENT_TIMESTAMP)
        ) THEN
            RAISE EXCEPTION 'Development test event % has no currently active matching policy.', v_event_id;
        END IF;
    END LOOP;
END;
$event_guard$;

INSERT INTO consent.consent_policy(
    policy_id, purpose_code, version, locale, content_hash, effective_from
)
VALUES (
    'matching-consent-dev-v1',
    'MATCHING',
    'dev-v1',
    'en-IN',
    '631c2062a3a65f119bdc084a8d9acfae3e27d784aff8058c8e2321d39beacba3',
    CURRENT_TIMESTAMP
)
ON CONFLICT (policy_id) DO NOTHING;

UPDATE event.event_matching_policy policy
SET check_in_required = false,
    updated_at = CURRENT_TIMESTAMP
FROM dev_matching_deployment_parameter parameter
WHERE policy.event_id = parameter.event_id
  AND policy.status = 'ACTIVE'
  AND policy.effective_from <= CURRENT_TIMESTAMP
  AND (policy.effective_to IS NULL OR policy.effective_to > CURRENT_TIMESTAMP)
  AND policy.check_in_required IS TRUE;

DO $verification$
DECLARE
    v_event_id varchar(64);
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM consent.consent_policy
        WHERE policy_id = 'matching-consent-dev-v1'
          AND purpose_code = 'MATCHING'
          AND version = 'dev-v1'
          AND locale = 'en-IN'
          AND content_hash = '631c2062a3a65f119bdc084a8d9acfae3e27d784aff8058c8e2321d39beacba3'
          AND effective_from <= CURRENT_TIMESTAMP
          AND retired_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Active development MATCHING consent policy verification failed.';
    END IF;

    FOR v_event_id IN SELECT event_id FROM dev_matching_deployment_parameter LOOP
        IF EXISTS (
            SELECT 1
            FROM event.event_matching_policy
            WHERE event_id = v_event_id
              AND status = 'ACTIVE'
              AND effective_from <= CURRENT_TIMESTAMP
              AND (effective_to IS NULL OR effective_to > CURRENT_TIMESTAMP)
              AND check_in_required IS TRUE
        ) THEN
            RAISE EXCEPTION 'check_in_required remains true for development test event %.', v_event_id;
        END IF;
    END LOOP;
END;
$verification$;

SELECT policy_id, purpose_code, version, locale, content_hash, effective_from, retired_at
FROM consent.consent_policy
WHERE policy_id = 'matching-consent-dev-v1';

SELECT policy.event_id, policy.policy_version, policy.status,
       policy.registration_required, policy.check_in_required, policy.live_mode_required
FROM event.event_matching_policy policy
JOIN dev_matching_deployment_parameter parameter ON parameter.event_id = policy.event_id
WHERE policy.status = 'ACTIVE'
  AND policy.effective_from <= CURRENT_TIMESTAMP
  AND (policy.effective_to IS NULL OR policy.effective_to > CURRENT_TIMESTAMP);

COMMIT;
