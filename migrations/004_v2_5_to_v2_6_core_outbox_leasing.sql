/*
OLGA Connect v2.5 -> v2.6: reliable Core outbox leasing.

Run as the migration identity against an existing v2.5 database. This migration
adds only worker-coordination state to ops.outbox_event. It does not change chat,
NLP, notification, file-scanning, roles, grants, ownership, or identities.
*/
BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('olga_schema_migration', 0));

DO $version_guard$
DECLARE
    current_version text := obj_description('ops'::regnamespace, 'pg_namespace');
BEGIN
    IF current_version NOT IN ('OLGA.SchemaVersion=2.5', 'OLGA.SchemaVersion=2.6') THEN
        RAISE EXCEPTION 'Core outbox-leasing migration requires schema version 2.5 or 2.6; found %.',
            COALESCE(current_version, '<unset>');
    END IF;
END;
$version_guard$;

SET ROLE olga_ddl_admin;

ALTER TABLE ops.outbox_event
    ADD COLUMN IF NOT EXISTS lease_id varchar(64) NULL,
    ADD COLUMN IF NOT EXISTS leased_until timestamptz NULL,
    ADD COLUMN IF NOT EXISTS last_attempt_at timestamptz NULL,
    ADD COLUMN IF NOT EXISTS exhausted_at timestamptz NULL,
    ADD COLUMN IF NOT EXISTS last_error_code varchar(64) NULL,
    ADD COLUMN IF NOT EXISTS last_error_summary varchar(512) NULL,
    ADD COLUMN IF NOT EXISTS row_version bigint NOT NULL DEFAULT 1;

DO $constraints$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'ops.outbox_event'::regclass
          AND conname = 'ck_outbox_event_attempt_count'
    ) THEN
        ALTER TABLE ops.outbox_event
            ADD CONSTRAINT ck_outbox_event_attempt_count
            CHECK (attempt_count >= 0) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'ops.outbox_event'::regclass
          AND conname = 'ck_outbox_event_lease_pair'
    ) THEN
        ALTER TABLE ops.outbox_event
            ADD CONSTRAINT ck_outbox_event_lease_pair
            CHECK ((lease_id IS NULL) = (leased_until IS NULL)) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'ops.outbox_event'::regclass
          AND conname = 'ck_outbox_event_published_not_leased'
    ) THEN
        ALTER TABLE ops.outbox_event
            ADD CONSTRAINT ck_outbox_event_published_not_leased
            CHECK (published_at IS NULL OR (lease_id IS NULL AND leased_until IS NULL)) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'ops.outbox_event'::regclass
          AND conname = 'ck_outbox_event_exhausted_state'
    ) THEN
        ALTER TABLE ops.outbox_event
            ADD CONSTRAINT ck_outbox_event_exhausted_state
            CHECK (
                exhausted_at IS NULL
                OR (published_at IS NULL AND lease_id IS NULL AND leased_until IS NULL)
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'ops.outbox_event'::regclass
          AND conname = 'ck_outbox_event_error_code'
    ) THEN
        ALTER TABLE ops.outbox_event
            ADD CONSTRAINT ck_outbox_event_error_code
            CHECK (
                last_error_code IS NULL
                OR last_error_code ~ '^[A-Z0-9][A-Z0-9_.-]{0,63}$'
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'ops.outbox_event'::regclass
          AND conname = 'ck_outbox_event_error_summary'
    ) THEN
        ALTER TABLE ops.outbox_event
            ADD CONSTRAINT ck_outbox_event_error_summary
            CHECK (
                last_error_summary IS NULL
                OR (
                    char_length(last_error_summary) <= 512
                    AND last_error_summary !~ '[[:cntrl:]]'
                )
            ) NOT VALID;
    END IF;
END;
$constraints$;

ALTER TABLE ops.outbox_event VALIDATE CONSTRAINT ck_outbox_event_attempt_count;
ALTER TABLE ops.outbox_event VALIDATE CONSTRAINT ck_outbox_event_lease_pair;
ALTER TABLE ops.outbox_event VALIDATE CONSTRAINT ck_outbox_event_published_not_leased;
ALTER TABLE ops.outbox_event VALIDATE CONSTRAINT ck_outbox_event_exhausted_state;
ALTER TABLE ops.outbox_event VALIDATE CONSTRAINT ck_outbox_event_error_code;
ALTER TABLE ops.outbox_event VALIDATE CONSTRAINT ck_outbox_event_error_summary;

CREATE OR REPLACE TRIGGER set_row_version
BEFORE UPDATE ON ops.outbox_event
FOR EACH ROW EXECUTE FUNCTION ops.set_row_version();

-- The predicate contains only immutable row-state tests. Eligibility timestamps
-- remain parameterized in the claim query; the trailing keys support its stable order.
CREATE INDEX IF NOT EXISTS ix_outbox_event_core_claim
    ON ops.outbox_event (next_attempt_at, leased_until, occurred_at, outbox_event_id)
    WHERE published_at IS NULL AND exhausted_at IS NULL;

DO $verification$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'ops'
          AND table_name = 'outbox_event'
          AND column_name IN (
              'lease_id', 'leased_until', 'last_attempt_at', 'exhausted_at',
              'last_error_code', 'last_error_summary', 'row_version'
          )
        GROUP BY table_schema, table_name
        HAVING count(*) <> 7
    ) OR (
        SELECT count(*)
        FROM information_schema.columns
        WHERE table_schema = 'ops'
          AND table_name = 'outbox_event'
          AND column_name IN (
              'lease_id', 'leased_until', 'last_attempt_at', 'exhausted_at',
              'last_error_code', 'last_error_summary', 'row_version'
          )
    ) <> 7 THEN
        RAISE EXCEPTION 'One or more required ops.outbox_event leasing columns are missing.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'ops.outbox_event'::regclass
          AND tgname = 'set_row_version'
          AND tgfoid = 'ops.set_row_version()'::regprocedure
          AND tgenabled <> 'D'
    ) THEN
        RAISE EXCEPTION 'ops.outbox_event row_version trigger is missing or disabled.';
    END IF;

    IF to_regclass('ops.ix_outbox_event_core_claim') IS NULL THEN
        RAISE EXCEPTION 'Required Core outbox claim index is missing.';
    END IF;
END;
$verification$;

COMMENT ON SCHEMA ops IS 'OLGA.SchemaVersion=2.6';

RESET ROLE;
COMMIT;
