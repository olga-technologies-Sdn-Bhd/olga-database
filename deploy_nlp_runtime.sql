/*
OLGA Connect - one-time NLP model and worker-permission upgrade

Run with Execute SQL Script (Alt+X) as the migration identity. The script accepts
only olga_connect_dev or olga_connect_prod and is rerunnable if verification is needed.
It does not alter memberships of existing login roles.
*/
BEGIN;

DO $deployment_guard$
BEGIN
    IF current_database() NOT IN ('olga_connect_dev', 'olga_connect_prod') THEN
        RAISE EXCEPTION
            'NLP upgrade stopped: connected to unsupported database %.',
            current_database();
    END IF;
END;
$deployment_guard$;

SELECT pg_advisory_xact_lock(hashtextextended('olga_schema_migration', 0));

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'olga_nlp_worker') THEN
        EXECUTE 'CREATE ROLE olga_nlp_worker NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION';
    END IF;
END;
$$;

SET ROLE olga_ddl_admin;

UPDATE nlp.nlp_model_version
SET status = 'RETIRED',
    updated_at = CURRENT_TIMESTAMP
WHERE status = 'ACTIVE'
  AND model_version <> 'azure-text-embedding-3-small-1536-v1';

INSERT INTO nlp.nlp_model_version(
    model_version, provider, deployment_name, dimensions, preprocessing_version, status, activated_at
) VALUES (
    'azure-text-embedding-3-small-1536-v1', 'AZURE_OPENAI', 'text-embedding-3-small',
    1536, 'normalizer-v1', 'ACTIVE', CURRENT_TIMESTAMP
)
ON CONFLICT (model_version) DO UPDATE SET
    provider = EXCLUDED.provider,
    deployment_name = EXCLUDED.deployment_name,
    dimensions = EXCLUDED.dimensions,
    preprocessing_version = EXCLUDED.preprocessing_version,
    status = 'ACTIVE',
    activated_at = CASE
        WHEN nlp.nlp_model_version.status = 'ACTIVE'
            THEN COALESCE(nlp.nlp_model_version.activated_at, EXCLUDED.activated_at)
        ELSE EXCLUDED.activated_at
    END,
    updated_at = CURRENT_TIMESTAMP;

-- Reset only the dedicated worker permission role. Existing login roles and their
-- memberships are not changed.
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA nlp, ops FROM olga_nlp_worker;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA nlp, ops FROM olga_nlp_worker;
REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA nlp, ops FROM olga_nlp_worker;
REVOKE ALL PRIVILEGES ON SCHEMA nlp, ops FROM olga_nlp_worker;

GRANT USAGE ON SCHEMA nlp, ops TO olga_nlp_worker;
GRANT SELECT ON nlp.nlp_intent, nlp.nlp_processing_job, nlp.nlp_embedding TO olga_nlp_worker;
GRANT UPDATE (status, updated_at) ON nlp.nlp_intent TO olga_nlp_worker;
GRANT UPDATE (status, attempt_count, available_at, locked_until, error_code, updated_at)
    ON nlp.nlp_processing_job TO olga_nlp_worker;
GRANT INSERT, UPDATE ON nlp.nlp_embedding TO olga_nlp_worker;
GRANT INSERT ON ops.outbox_event TO olga_nlp_worker;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM nlp.nlp_model_version
        WHERE model_version = 'azure-text-embedding-3-small-1536-v1'
          AND provider = 'AZURE_OPENAI'
          AND deployment_name = 'text-embedding-3-small'
          AND dimensions = 1536
          AND preprocessing_version = 'normalizer-v1'
          AND status = 'ACTIVE'
          AND activated_at IS NOT NULL
    ) THEN RAISE EXCEPTION 'The approved active NLP model is missing or inconsistent.'; END IF;

    IF NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_intent', 'SELECT')
       OR NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_processing_job', 'SELECT')
       OR NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_embedding', 'SELECT')
       OR NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_embedding', 'INSERT')
       OR NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_embedding', 'UPDATE')
       OR NOT has_table_privilege('olga_nlp_worker', 'ops.outbox_event', 'INSERT')
       OR NOT has_column_privilege('olga_nlp_worker', 'nlp.nlp_intent', 'status', 'UPDATE')
       OR NOT has_column_privilege('olga_nlp_worker', 'nlp.nlp_processing_job', 'locked_until', 'UPDATE')
       OR has_table_privilege('olga_nlp_worker', 'nlp.nlp_intent', 'INSERT')
       OR has_table_privilege('olga_nlp_worker', 'nlp.nlp_intent', 'DELETE')
       OR has_table_privilege('olga_nlp_worker', 'nlp.nlp_processing_job', 'INSERT')
       OR has_table_privilege('olga_nlp_worker', 'nlp.nlp_processing_job', 'DELETE')
       OR has_table_privilege('olga_nlp_worker', 'ops.outbox_event', 'SELECT')
       OR has_table_privilege('olga_nlp_worker', 'ops.outbox_event', 'UPDATE')
       OR has_table_privilege('olga_nlp_worker', 'ops.outbox_event', 'DELETE')
       OR has_table_privilege('olga_nlp_worker', 'nlp.match_request', 'SELECT') THEN
        RAISE EXCEPTION 'NLP worker privileges are missing or exceed the approved boundary.';
    END IF;
END;
$$;

RESET ROLE;
COMMIT;
