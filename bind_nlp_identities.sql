/*
OLGA Connect - one-time NLP managed-identity binding

Run after the environment's NLP API and worker managed identities have been mapped
into PostgreSQL. This script only adds the two approved memberships. It never creates,
drops, alters, or revokes a role, and aborts before granting if any role is absent.
*/
BEGIN;

DO $binding$
DECLARE
    api_principal text;
    worker_principal text;
    required_role text;
BEGIN
    CASE current_database()
        WHEN 'olga_connect_dev' THEN
            api_principal := 'id-olga-nlp-dev';
            worker_principal := 'id-olga-worker-dev';
        WHEN 'olga_connect_prod' THEN
            api_principal := 'id-olga-nlp-prod';
            worker_principal := 'id-olga-worker-prod';
        ELSE
            RAISE EXCEPTION
                'NLP identity binding stopped: connected to unsupported database %.',
                current_database();
    END CASE;

    FOREACH required_role IN ARRAY ARRAY[
        'olga_dml_writer',
        'olga_nlp_worker',
        api_principal,
        worker_principal
    ]
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = required_role) THEN
            RAISE EXCEPTION
                'Identity binding made no changes: required PostgreSQL role % does not exist.',
                required_role;
        END IF;
    END LOOP;

    EXECUTE format('GRANT olga_dml_writer TO %I', api_principal);
    EXECUTE format('GRANT olga_nlp_worker TO %I', worker_principal);

    IF NOT pg_has_role(api_principal, 'olga_dml_writer', 'MEMBER')
       OR NOT pg_has_role(worker_principal, 'olga_nlp_worker', 'MEMBER') THEN
        RAISE EXCEPTION 'NLP identity role-membership verification failed.';
    END IF;
END;
$binding$;

COMMIT;
