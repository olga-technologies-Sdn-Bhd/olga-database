/*
OLGA Connect - production database-role binding

Run this file against olga_connect_prod as the migration identity after running
map_prod_identities.template.sql against the postgres database. Replace both
angle-bracket placeholders with the same Microsoft Entra principal names.

The script enforces one intended OLGA runtime role per service identity. The
migration identity retains all OLGA database roles for deployment and support.
*/

BEGIN;

DO $database_guard$
BEGIN
    IF current_database() <> 'olga_connect_prod' THEN
        RAISE EXCEPTION
            'Production identity binding stopped: connected to database %, expected olga_connect_prod.',
            current_database();
    END IF;
END;
$database_guard$;

SELECT pg_advisory_xact_lock(hashtextextended('olga_identity_binding', 0));

CREATE TEMP TABLE prod_role_binding_parameter(
    identity_purpose varchar(32) PRIMARY KEY,
    principal_name text NOT NULL UNIQUE,
    database_role name NOT NULL
) ON COMMIT DROP;

INSERT INTO prod_role_binding_parameter(identity_purpose, principal_name, database_role)
VALUES
    ('MIGRATION', 'olga_migration_admin', 'olga_ddl_admin'),
    ('APPLICATION', '<production-application-entra-principal>', 'olga_dml_writer'),
    ('READER', '<production-reader-entra-principal>', 'olga_reader'),
    ('NLP_API', 'id-olga-nlp-prod', 'olga_dml_writer'),
    ('NLP_WORKER', 'id-olga-worker-prod', 'olga_nlp_worker');

DO $binding$
DECLARE
    binding_record record;
    olga_role name;
    required_name text;
BEGIN
    IF EXISTS (
        SELECT 1
        FROM prod_role_binding_parameter
        WHERE principal_name ~ '[<>]'
           OR btrim(principal_name) = ''
    ) THEN
        RAISE EXCEPTION
            'Identity binding made no changes: replace every angle-bracket placeholder.';
    END IF;

    FOREACH required_name IN ARRAY ARRAY[
        'olga_ddl_admin',
        'olga_dml_writer',
        'olga_reader',
        'olga_nlp_worker'
    ]
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = required_name) THEN
            RAISE EXCEPTION
                'Identity binding made no changes: required database role % does not exist.',
                required_name;
        END IF;
    END LOOP;

    FOR binding_record IN
        SELECT identity_purpose, principal_name, database_role
        FROM prod_role_binding_parameter
        ORDER BY identity_purpose
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_roles
            WHERE rolname = binding_record.principal_name
              AND rolcanlogin
        ) THEN
            RAISE EXCEPTION
                'Identity binding made no changes: login principal % is missing.',
                binding_record.principal_name;
        END IF;
    END LOOP;

    FOR binding_record IN
        SELECT identity_purpose, principal_name, database_role
        FROM prod_role_binding_parameter
        ORDER BY identity_purpose
    LOOP
        IF binding_record.identity_purpose = 'MIGRATION' THEN
            FOREACH olga_role IN ARRAY ARRAY[
                'olga_ddl_admin'::name,
                'olga_dml_writer'::name,
                'olga_reader'::name,
                'olga_nlp_worker'::name
            ]
            LOOP
                EXECUTE format(
                    'GRANT %I TO %I',
                    olga_role,
                    binding_record.principal_name
                );
            END LOOP;
            CONTINUE;
        END IF;

        FOREACH olga_role IN ARRAY ARRAY[
            'olga_ddl_admin'::name,
            'olga_dml_writer'::name,
            'olga_reader'::name,
            'olga_nlp_worker'::name
        ]
        LOOP
            IF olga_role <> binding_record.database_role THEN
                EXECUTE format(
                    'REVOKE %I FROM %I',
                    olga_role,
                    binding_record.principal_name
                );
            END IF;
        END LOOP;

        EXECUTE format(
            'GRANT %I TO %I',
            binding_record.database_role,
            binding_record.principal_name
        );
    END LOOP;
END;
$binding$;

DO $verification$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM prod_role_binding_parameter parameter
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_auth_members membership
            JOIN pg_roles granted_role ON granted_role.oid = membership.roleid
            JOIN pg_roles member_role ON member_role.oid = membership.member
            WHERE member_role.rolname = parameter.principal_name
              AND granted_role.rolname = parameter.database_role
        )
    ) THEN
        RAISE EXCEPTION 'Production identity membership verification failed.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM prod_role_binding_parameter parameter
        JOIN pg_roles member_role ON member_role.rolname = parameter.principal_name
        JOIN pg_auth_members membership ON membership.member = member_role.oid
        JOIN pg_roles granted_role ON granted_role.oid = membership.roleid
        WHERE granted_role.rolname IN (
            'olga_ddl_admin',
            'olga_dml_writer',
            'olga_reader',
            'olga_nlp_worker'
        )
          AND granted_role.rolname <> parameter.database_role
          AND parameter.identity_purpose <> 'MIGRATION'
    ) THEN
        RAISE EXCEPTION 'Unexpected OLGA role membership remains after binding.';
    END IF;
END;
$verification$;

SELECT parameter.identity_purpose,
       member_role.rolname AS principal_name,
       granted_role.rolname AS granted_role
FROM prod_role_binding_parameter parameter
JOIN pg_roles member_role ON member_role.rolname = parameter.principal_name
JOIN pg_auth_members membership ON membership.member = member_role.oid
JOIN pg_roles granted_role ON granted_role.oid = membership.roleid
WHERE granted_role.rolname IN (
    'olga_ddl_admin',
    'olga_dml_writer',
    'olga_reader',
    'olga_nlp_worker'
)
ORDER BY parameter.identity_purpose;

COMMIT;
