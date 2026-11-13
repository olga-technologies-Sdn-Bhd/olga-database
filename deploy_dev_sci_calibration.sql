/*
OLGA Connect - development-only SCI calibration activation

Run with Execute SQL Script as the migration identity. This script is
transactional and rerunnable.

The calibration is provisional and exists only to unblock development UI/API
integration. It must not be promoted to production as a reviewed calibration.
*/
BEGIN;

SELECT pg_advisory_xact_lock(
    hashtextextended('olga_schema_migration', 0)
);

DO $configuration_guard$
DECLARE
    target_config_pk bigint;
BEGIN
    SELECT sci_scoring_config_pk
      INTO target_config_pk
      FROM nlp.sci_scoring_config
     WHERE scoring_config_id = 'SCI_GLOBAL_V1'
       AND region_code = 'GLOBAL'
       AND scorer_version = 'sci-v1'
       AND status IN ('DRAFT', 'ACTIVE');

    IF target_config_pk IS NULL THEN
        RAISE EXCEPTION
            'SCI_GLOBAL_V1 is missing or is not eligible for development activation.';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM nlp.sci_scoring_config
         WHERE region_code = 'GLOBAL'
           AND status = 'ACTIVE'
           AND sci_scoring_config_pk <> target_config_pk
    ) THEN
        RAISE EXCEPTION
            'Another GLOBAL SCI scoring configuration is already active.';
    END IF;

    /*
    Calibration identity is intentionally irrelevant. Reuse any active,
    in-window calibration with valid f50/f99 for the target configuration.
    */
    IF EXISTS (
        SELECT 1
          FROM nlp.sci_calibration
         WHERE sci_scoring_config_pk = target_config_pk
           AND status = 'ACTIVE'
    ) AND NOT EXISTS (
        SELECT 1
          FROM nlp.sci_calibration
         WHERE sci_scoring_config_pk = target_config_pk
           AND status = 'ACTIVE'
           AND effective_from IS NOT NULL
           AND effective_from <= CURRENT_TIMESTAMP
           AND (
               effective_to IS NULL
               OR effective_to > CURRENT_TIMESTAMP
           )
           AND f50 IS NOT NULL
           AND f99 IS NOT NULL
           AND f99 > f50
    ) THEN
        RAISE EXCEPTION
            'SCI_GLOBAL_V1 has active calibration data, but none is in-window with valid f50/f99.';
    END IF;
END;
$configuration_guard$;

INSERT INTO nlp.sci_calibration (
    calibration_id,
    sci_scoring_config_pk,
    calibration_method,
    f50,
    f99,
    model_payload_json,
    sample_count,
    status,
    effective_from,
    effective_to
)
SELECT
    'SCI_GLOBAL_V1_DEV_LINEAR_V1',
    sci_scoring_config_pk,
    'LINEAR',
    0.5000000,
    0.9900000,
    '{"environment":"dev","purpose":"mobile_sci_integration","provisional":true}'::jsonb,
    0,
    'ACTIVE',
    CURRENT_TIMESTAMP,
    NULL
FROM nlp.sci_scoring_config
WHERE scoring_config_id = 'SCI_GLOBAL_V1'
  AND NOT EXISTS (
      SELECT 1
        FROM nlp.sci_calibration existing
       WHERE existing.sci_scoring_config_pk =
             nlp.sci_scoring_config.sci_scoring_config_pk
         AND existing.status = 'ACTIVE'
         AND existing.effective_from <= CURRENT_TIMESTAMP
         AND (
             existing.effective_to IS NULL
             OR existing.effective_to > CURRENT_TIMESTAMP
         )
         AND existing.f50 IS NOT NULL
         AND existing.f99 IS NOT NULL
         AND existing.f99 > existing.f50
  )
ON CONFLICT (calibration_id) DO UPDATE
SET sci_scoring_config_pk = EXCLUDED.sci_scoring_config_pk,
    calibration_method = EXCLUDED.calibration_method,
    f50 = EXCLUDED.f50,
    f99 = EXCLUDED.f99,
    model_payload_json = EXCLUDED.model_payload_json,
    sample_count = EXCLUDED.sample_count,
    status = EXCLUDED.status,
    effective_from = COALESCE(
        nlp.sci_calibration.effective_from,
        EXCLUDED.effective_from
    ),
    effective_to = NULL,
    updated_at = CURRENT_TIMESTAMP;

UPDATE nlp.sci_scoring_config
   SET status = 'ACTIVE',
       effective_from = COALESCE(
           effective_from,
           CURRENT_TIMESTAMP
       ),
       effective_to = NULL,
       updated_at = CURRENT_TIMESTAMP
 WHERE scoring_config_id = 'SCI_GLOBAL_V1';

-- Recover only jobs that previously exhausted retries because this calibration
-- was unavailable. Existing PENDING jobs need no change and will be leased by
-- the worker automatically.
UPDATE nlp.sci_scoring_job
   SET status = 'PENDING',
       attempt_count = 0,
       available_at = CURRENT_TIMESTAMP,
       locked_until = NULL,
       error_code = NULL,
       updated_at = CURRENT_TIMESTAMP
 WHERE status IN ('FAILED', 'DEAD')
   AND error_code = 'SCI_ACTIVE_CALIBRATION_MISSING';

DO $verification$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM nlp.sci_scoring_config config
          JOIN nlp.sci_calibration calibration
            ON calibration.sci_scoring_config_pk =
               config.sci_scoring_config_pk
         WHERE config.scoring_config_id = 'SCI_GLOBAL_V1'
           AND config.status = 'ACTIVE'
           AND config.effective_from <= CURRENT_TIMESTAMP
           AND (
               config.effective_to IS NULL
               OR config.effective_to > CURRENT_TIMESTAMP
           )
           AND calibration.status = 'ACTIVE'
           AND calibration.effective_from <= CURRENT_TIMESTAMP
           AND (
               calibration.effective_to IS NULL
               OR calibration.effective_to > CURRENT_TIMESTAMP
           )
           AND calibration.f50 IS NOT NULL
           AND calibration.f99 IS NOT NULL
           AND calibration.f99 > calibration.f50
    ) THEN
        RAISE EXCEPTION
            'Development SCI configuration activation verification failed.';
    END IF;
END;
$verification$;

COMMIT;

SELECT
    config.scoring_config_id,
    config.status AS config_status,
    calibration.calibration_id,
    calibration.status AS calibration_status,
    calibration.f50,
    calibration.f99
FROM nlp.sci_scoring_config config
JOIN nlp.sci_calibration calibration
  ON calibration.sci_scoring_config_pk =
     config.sci_scoring_config_pk
WHERE config.scoring_config_id = 'SCI_GLOBAL_V1';

SELECT
    status,
    count(*) AS job_count
FROM nlp.sci_scoring_job
GROUP BY status
ORDER BY status;

SELECT
    job_id,
    status,
    attempt_count,
    error_code,
    available_at,
    updated_at
FROM nlp.sci_scoring_job
ORDER BY updated_at DESC, sci_scoring_job_pk DESC
LIMIT 20;
