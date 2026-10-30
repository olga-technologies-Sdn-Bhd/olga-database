/*
Development-only role migration for a database created by an earlier OLGA setup.

Run as the same migration identity that owns the existing OLGA objects. This script
preserves data, transfers OLGA object ownership to olga_ddl_admin, grants the new
coarse-grained access roles, and removes the former service-specific roles.
*/
BEGIN;

DO $$
BEGIN
    IF current_database() <> 'olga_connect_dev' THEN
        RAISE EXCEPTION
            'Development role migration stopped: connected to database %, expected olga_connect_dev.',
            current_database();
    END IF;
END;
$$;

SELECT pg_advisory_xact_lock(hashtextextended('olga_schema_migration', 0));

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'olga_ddl_admin') THEN
        EXECUTE 'CREATE ROLE olga_ddl_admin NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'olga_dml_writer') THEN
        EXECUTE 'CREATE ROLE olga_dml_writer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'olga_reader') THEN
        EXECUTE 'CREATE ROLE olga_reader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'olga_nlp_worker') THEN
        EXECUTE 'CREATE ROLE olga_nlp_worker NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION';
    END IF;
END;
$$;

GRANT olga_ddl_admin TO CURRENT_USER;

-- The former roles were permission bundles, not object owners. Temporary membership
-- lets the migration identity remove their grants safely at the end of this script.
DO $$
DECLARE
    role_name text;
BEGIN
    FOREACH role_name IN ARRAY ARRAY[
        'olga_core_app', 'olga_identity_app', 'olga_consent_app', 'olga_event_app',
        'olga_social_app', 'olga_chat_app', 'olga_storage_app', 'olga_notification_app',
        'olga_nlp_app', 'olga_moderation_app', 'olga_ops_worker',
        'olga_analytics_writer', 'olga_admin_reader'
    ]
    LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
            EXECUTE format('GRANT %I TO %I', role_name, session_user);
        END IF;
    END LOOP;
END;
$$;

-- The new owner must own the schemas before relation/routine ownership can be
-- transferred to it.
ALTER SCHEMA core OWNER TO olga_ddl_admin;
ALTER SCHEMA iam OWNER TO olga_ddl_admin;
ALTER SCHEMA consent OWNER TO olga_ddl_admin;
ALTER SCHEMA event OWNER TO olga_ddl_admin;
ALTER SCHEMA social OWNER TO olga_ddl_admin;
ALTER SCHEMA chat OWNER TO olga_ddl_admin;
ALTER SCHEMA storage OWNER TO olga_ddl_admin;
ALTER SCHEMA notification OWNER TO olga_ddl_admin;
ALTER SCHEMA nlp OWNER TO olga_ddl_admin;
ALTER SCHEMA moderation OWNER TO olga_ddl_admin;
ALTER SCHEMA ops OWNER TO olga_ddl_admin;
ALTER SCHEMA analytics OWNER TO olga_ddl_admin;
ALTER SCHEMA admin OWNER TO olga_ddl_admin;
ALTER SCHEMA history OWNER TO olga_ddl_admin;

-- Transfer all existing OLGA relations. Index ownership follows table ownership;
-- identity-owned sequences follow their parent tables and are excluded here.
DO $$
DECLARE
    object_record record;
    object_kind text;
BEGIN
    FOR object_record IN
        SELECT n.nspname AS schema_name, c.relname AS object_name, c.relkind
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = ANY (ARRAY[
            'core', 'iam', 'consent', 'event', 'social', 'chat', 'storage',
            'notification', 'nlp', 'moderation', 'ops', 'analytics', 'admin', 'history'
        ])
          AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
          AND (
              c.relkind <> 'S'
              OR NOT EXISTS (
                  SELECT 1
                  FROM pg_depend d
                  WHERE d.classid = 'pg_class'::regclass
                    AND d.objid = c.oid
                    AND d.deptype IN ('a', 'i')
              )
          )
        ORDER BY CASE c.relkind
            WHEN 'r' THEN 1 WHEN 'p' THEN 1 WHEN 'f' THEN 1
            WHEN 'v' THEN 2 WHEN 'm' THEN 2 WHEN 'S' THEN 3
        END
    LOOP
        object_kind := CASE object_record.relkind
            WHEN 'r' THEN 'TABLE'
            WHEN 'p' THEN 'TABLE'
            WHEN 'f' THEN 'FOREIGN TABLE'
            WHEN 'v' THEN 'VIEW'
            WHEN 'm' THEN 'MATERIALIZED VIEW'
            WHEN 'S' THEN 'SEQUENCE'
        END;
        EXECUTE format(
            'ALTER %s %I.%I OWNER TO olga_ddl_admin',
            object_kind,
            object_record.schema_name,
            object_record.object_name
        );
    END LOOP;
END;
$$;

DO $$
DECLARE
    routine_record record;
BEGIN
    FOR routine_record IN
        SELECT n.nspname AS schema_name, p.proname AS routine_name,
               pg_get_function_identity_arguments(p.oid) AS identity_arguments
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = ANY (ARRAY[
            'core', 'iam', 'consent', 'event', 'social', 'chat', 'storage',
            'notification', 'nlp', 'moderation', 'ops', 'analytics', 'admin', 'history'
        ])
          AND p.prokind IN ('f', 'p', 'w')
    LOOP
        EXECUTE format(
            'ALTER ROUTINE %I.%I(%s) OWNER TO olga_ddl_admin',
            routine_record.schema_name,
            routine_record.routine_name,
            routine_record.identity_arguments
        );
    END LOOP;
END;
$$;

SET ROLE olga_ddl_admin;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA core, iam, consent, event, social, chat,
    storage, notification, nlp, moderation, ops, analytics, admin, history FROM PUBLIC;
REVOKE ALL ON SCHEMA history FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA history FROM PUBLIC;

GRANT USAGE ON SCHEMA core, iam, consent, event, social, chat, storage, notification,
    nlp, moderation, ops, analytics, admin, history TO olga_dml_writer, olga_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, iam, consent, event,
    social, chat, storage, notification, nlp, moderation, ops, analytics, admin, history
    TO olga_dml_writer;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA core, iam, consent, event, social,
    chat, storage, notification, nlp, moderation, ops, analytics, admin, history
    TO olga_dml_writer;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA core, iam, consent, event, social, chat, storage,
    notification, nlp, moderation, ops, analytics, admin, history TO olga_dml_writer;
GRANT SELECT ON ALL TABLES IN SCHEMA core, iam, consent, event, social, chat, storage,
    notification, nlp, moderation, ops, analytics, admin, history TO olga_reader;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA core, iam, consent, event, social, chat, storage,
    notification, nlp, moderation, ops, analytics, admin, history TO olga_reader;
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

ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO olga_dml_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO olga_dml_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT EXECUTE ON FUNCTIONS TO olga_dml_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT SELECT ON TABLES TO olga_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT SELECT ON SEQUENCES TO olga_reader;

RESET ROLE;

DO $$
DECLARE
    role_name text;
BEGIN
    FOREACH role_name IN ARRAY ARRAY[
        'olga_core_app', 'olga_identity_app', 'olga_consent_app', 'olga_event_app',
        'olga_social_app', 'olga_chat_app', 'olga_storage_app', 'olga_notification_app',
        'olga_nlp_app', 'olga_moderation_app', 'olga_ops_worker',
        'olga_analytics_writer', 'olga_admin_reader'
    ]
    LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
            EXECUTE format('DROP OWNED BY %I', role_name);
            EXECUTE format('DROP ROLE %I', role_name);
        END IF;
    END LOOP;
END;
$$;

COMMIT;
