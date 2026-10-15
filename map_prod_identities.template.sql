/*
OLGA Connect - production Microsoft Entra principal mapping

Run this file against the server's postgres database as a Microsoft Entra
administrator. Replace both angle-bracket placeholders before execution.
The script is rerunnable and does not store passwords.
*/

BEGIN;

DO $database_guard$
BEGIN
    IF current_database() <> 'postgres' THEN
        RAISE EXCEPTION
            'Identity mapping stopped: connected to database %, expected postgres.',
            current_database();
    END IF;
END;
$database_guard$;

CREATE TEMP TABLE prod_identity_parameter(
    identity_purpose varchar(32) PRIMARY KEY,
    principal_name text NOT NULL UNIQUE
) ON COMMIT DROP;

INSERT INTO prod_identity_parameter(identity_purpose, principal_name)
VALUES
    ('MIGRATION', 'olga_migration_admin'),
    ('APPLICATION', '<production-application-entra-principal>'),
    ('READER', '<production-reader-entra-principal>'),
    ('NLP_API', 'id-olga-nlp-prod'),
    ('NLP_WORKER', 'id-olga-worker-prod');

DO $mapping$
DECLARE
    identity_record record;
BEGIN
    IF EXISTS (
        SELECT 1
        FROM prod_identity_parameter
        WHERE principal_name ~ '[<>]'
           OR btrim(principal_name) = ''
    ) THEN
        RAISE EXCEPTION
            'Identity mapping made no changes: replace every angle-bracket placeholder.';
    END IF;

    FOR identity_record IN
        SELECT identity_purpose, principal_name
        FROM prod_identity_parameter
        ORDER BY identity_purpose
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_roles
            WHERE rolname = identity_record.principal_name
        ) THEN
            PERFORM *
            FROM pg_catalog.pgaadauth_create_principal(
                identity_record.principal_name,
                false,
                false
            );
        END IF;
    END LOOP;
END;
$mapping$;

DO $verification$
DECLARE
    missing_principals text;
BEGIN
    SELECT string_agg(parameter.principal_name, ', ' ORDER BY parameter.principal_name)
    INTO missing_principals
    FROM prod_identity_parameter parameter
    WHERE NOT EXISTS (
        SELECT 1
        FROM pg_roles role
        WHERE role.rolname = parameter.principal_name
          AND role.rolcanlogin
    );

    IF missing_principals IS NOT NULL THEN
        RAISE EXCEPTION
            'Production identity mapping verification failed for: %.',
            missing_principals;
    END IF;
END;
$verification$;

SELECT parameter.identity_purpose, role.rolname AS principal_name, role.rolcanlogin
FROM prod_identity_parameter parameter
JOIN pg_roles role ON role.rolname = parameter.principal_name
ORDER BY parameter.identity_purpose;

COMMIT;
