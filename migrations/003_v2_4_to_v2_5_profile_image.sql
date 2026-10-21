/*
OLGA Connect v2.4 -> v2.5: member profile-image metadata.

Run as the migration identity against an existing v2.4 database. Image bytes remain
in object storage; PostgreSQL stores only blob paths and processing metadata. The
script is transactional and rerunnable.
*/
BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('olga_schema_migration', 0));

DO $version_guard$
DECLARE
    current_version text := obj_description('ops'::regnamespace, 'pg_namespace');
BEGIN
    IF current_version NOT IN ('OLGA.SchemaVersion=2.4', 'OLGA.SchemaVersion=2.5') THEN
        RAISE EXCEPTION 'Profile-image migration requires schema version 2.4 or 2.5; found %.',
            COALESCE(current_version, '<unset>');
    END IF;
END;
$version_guard$;

SET ROLE olga_ddl_admin;

CREATE TABLE IF NOT EXISTS core.member_profile_image (
    profile_image_id bigint GENERATED ALWAYS AS IDENTITY,
    image_api_id varchar(64) NOT NULL,
    member_id varchar(64) NOT NULL,
    source_blob_path varchar(1024) NOT NULL,
    display_blob_path varchar(1024) NULL,
    thumbnail_blob_path varchar(1024) NULL,
    content_type varchar(100) NOT NULL,
    size_bytes bigint NOT NULL,
    content_sha256 char(64) NOT NULL,
    status varchar(24) NOT NULL DEFAULT 'PENDING',
    rejection_reason varchar(240) NULL,
    processed_at timestamptz NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_version bigint NOT NULL DEFAULT 1,
    created_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    updated_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    CONSTRAINT pk_member_profile_image PRIMARY KEY (profile_image_id),
    CONSTRAINT ux_member_profile_image_api_id UNIQUE (image_api_id)
);

ALTER TABLE core.member_profile
    ADD COLUMN IF NOT EXISTS profile_image_id bigint NULL;

DO $constraints$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'core.member_profile_image'::regclass
          AND conname = 'fk_member_profile_image_member_id'
    ) THEN
        ALTER TABLE core.member_profile_image
            ADD CONSTRAINT fk_member_profile_image_member_id
            FOREIGN KEY (member_id) REFERENCES iam.member (member_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'core.member_profile'::regclass
          AND conname = 'fk_member_profile_profile_image_id'
    ) THEN
        ALTER TABLE core.member_profile
            ADD CONSTRAINT fk_member_profile_profile_image_id
            FOREIGN KEY (profile_image_id)
            REFERENCES core.member_profile_image (profile_image_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'core.member_profile_image'::regclass
          AND conname = 'ck_member_profile_image_status'
    ) THEN
        ALTER TABLE core.member_profile_image
            ADD CONSTRAINT ck_member_profile_image_status
            CHECK (status IN ('PENDING','PROCESSING','APPROVED','REJECTED','FAILED'));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'core.member_profile_image'::regclass
          AND conname = 'ck_member_profile_image_size_bytes'
    ) THEN
        ALTER TABLE core.member_profile_image
            ADD CONSTRAINT ck_member_profile_image_size_bytes
            CHECK (size_bytes > 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'core.member_profile_image'::regclass
          AND conname = 'ck_member_profile_image_content_type'
    ) THEN
        ALTER TABLE core.member_profile_image
            ADD CONSTRAINT ck_member_profile_image_content_type
            CHECK (content_type IN ('image/jpeg','image/png','image/webp'));
    END IF;
END;
$constraints$;

CREATE INDEX IF NOT EXISTS ix_member_profile_image_member_id
    ON core.member_profile_image (member_id);
CREATE INDEX IF NOT EXISTS ix_member_profile_image_status
    ON core.member_profile_image (status);
CREATE INDEX IF NOT EXISTS ix_member_profile_image_cleanup
    ON core.member_profile_image (status, processed_at)
    WHERE status IN ('APPROVED','REJECTED','FAILED') AND processed_at IS NOT NULL;

DROP TRIGGER IF EXISTS set_audit_actor ON core.member_profile_image;
CREATE TRIGGER set_audit_actor
BEFORE INSERT OR UPDATE ON core.member_profile_image
FOR EACH ROW EXECUTE FUNCTION ops.set_audit_actor();

DROP TRIGGER IF EXISTS set_row_version ON core.member_profile_image;
CREATE TRIGGER set_row_version
BEFORE UPDATE ON core.member_profile_image
FOR EACH ROW EXECUTE FUNCTION ops.set_row_version();

GRANT SELECT, INSERT, UPDATE, DELETE ON core.member_profile_image TO olga_dml_writer;
GRANT USAGE, SELECT, UPDATE ON SEQUENCE core.member_profile_image_profile_image_id_seq TO olga_dml_writer;
GRANT SELECT ON core.member_profile_image TO olga_reader;

REVOKE ALL PRIVILEGES ON core.member_profile_image FROM olga_nlp_worker;
REVOKE ALL PRIVILEGES ON SEQUENCE core.member_profile_image_profile_image_id_seq FROM olga_nlp_worker;

DO $verification$
BEGIN
    IF to_regclass('core.member_profile_image') IS NULL THEN
        RAISE EXCEPTION 'Required table core.member_profile_image is missing.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'core'
          AND table_name = 'member_profile'
          AND column_name = 'profile_image_id'
          AND data_type = 'bigint'
          AND is_nullable = 'YES'
    ) THEN
        RAISE EXCEPTION 'core.member_profile.profile_image_id is missing or invalid.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'core.member_profile_image'::regclass
          AND tgname = 'set_row_version'
          AND tgfoid = 'ops.set_row_version()'::regprocedure
          AND tgenabled <> 'D'
    ) THEN
        RAISE EXCEPTION 'core.member_profile_image row_version trigger is missing or disabled.';
    END IF;

    IF NOT has_table_privilege('olga_dml_writer', 'core.member_profile_image', 'SELECT')
       OR NOT has_table_privilege('olga_dml_writer', 'core.member_profile_image', 'INSERT')
       OR NOT has_table_privilege('olga_dml_writer', 'core.member_profile_image', 'UPDATE')
       OR NOT has_table_privilege('olga_dml_writer', 'core.member_profile_image', 'DELETE')
       OR NOT has_sequence_privilege('olga_dml_writer', 'core.member_profile_image_profile_image_id_seq', 'USAGE')
       OR NOT has_table_privilege('olga_reader', 'core.member_profile_image', 'SELECT')
       OR has_table_privilege('olga_nlp_worker', 'core.member_profile_image', 'SELECT')
       OR has_table_privilege('olga_nlp_worker', 'core.member_profile_image', 'INSERT')
       OR has_table_privilege('olga_nlp_worker', 'core.member_profile_image', 'UPDATE')
       OR has_table_privilege('olga_nlp_worker', 'core.member_profile_image', 'DELETE')
       OR has_sequence_privilege('olga_nlp_worker', 'core.member_profile_image_profile_image_id_seq', 'USAGE') THEN
        RAISE EXCEPTION 'Profile-image privileges are missing or exceed the approved boundary.';
    END IF;
END;
$verification$;

COMMENT ON SCHEMA ops IS 'OLGA.SchemaVersion=2.5';

RESET ROLE;
COMMIT;
