BEGIN;

-- Serialize schema deployments even if two external pipelines are started.
SELECT pg_advisory_xact_lock(hashtextextended('olga_schema_migration', 0));

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

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
SET ROLE olga_ddl_admin;

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS iam;
CREATE SCHEMA IF NOT EXISTS consent;
CREATE SCHEMA IF NOT EXISTS event;
CREATE SCHEMA IF NOT EXISTS social;
CREATE SCHEMA IF NOT EXISTS chat;
CREATE SCHEMA IF NOT EXISTS storage;
CREATE SCHEMA IF NOT EXISTS notification;
CREATE SCHEMA IF NOT EXISTS nlp;
CREATE SCHEMA IF NOT EXISTS moderation;
CREATE SCHEMA IF NOT EXISTS ops;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS admin;
CREATE SCHEMA IF NOT EXISTS history;

CREATE SEQUENCE IF NOT EXISTS chat.message_sequence AS bigint START WITH 1 INCREMENT BY 1 CACHE 100;
CREATE SEQUENCE IF NOT EXISTS ops.sync_change_sequence AS bigint START WITH 1 INCREMENT BY 1 CACHE 100;

CREATE OR REPLACE FUNCTION ops.set_row_version()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.row_version := OLD.row_version + 1;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION ops.add_constraint_if_missing(
    p_schema name, p_table name, p_constraint name, p_definition text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = p_schema AND t.relname = p_table AND c.conname = p_constraint
    ) THEN
        EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I %s', p_schema, p_table, p_constraint, p_definition);
    END IF;
END;
$$;
