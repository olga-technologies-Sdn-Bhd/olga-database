/*
OLGA Connect existing-database upgrade bundle: schema v2.4 -> v2.9.

Use this only when the database reports OLGA.SchemaVersion=2.4. Each contained
migration is transactional and advances the version before the next migration.
*/
-- ======================== migrations\003_v2_4_to_v2_5_profile_image.sql ========================
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

-- ======================== migrations\004_v2_5_to_v2_6_core_outbox_leasing.sql ========================
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

-- ======================== migrations\005_v2_6_to_v2_7_chat_outbox_contract.sql ========================
/*
OLGA Connect v2.6 -> v2.7: canonical chat message outbox contract.

Run as the migration identity against an existing v2.6 database. This migration
updates only the two controlled chat write functions. It is transactional and
rerunnable at schema version v2.7.
*/
BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('olga_schema_migration', 0));

DO $version_guard$
DECLARE
    current_version text := obj_description('ops'::regnamespace, 'pg_namespace');
BEGIN
    IF current_version NOT IN ('OLGA.SchemaVersion=2.6', 'OLGA.SchemaVersion=2.7') THEN
        RAISE EXCEPTION 'Chat outbox-contract migration requires schema version 2.6 or 2.7; found %.',
            COALESCE(current_version, '<unset>');
    END IF;
END;
$version_guard$;

SET ROLE olga_ddl_admin;

CREATE OR REPLACE FUNCTION chat.save_message(
    p_message_id varchar(64), p_conversation_id varchar(64), p_sender_member_id varchar(64),
    p_message_type varchar(20), p_body text, p_client_sent_at timestamptz,
    p_idempotency_key varchar(128), p_request_hash char(64),
    p_idempotency_expires_at timestamptz, p_sync_expires_at timestamptz
)
RETURNS SETOF chat.message
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, chat, ops, iam
AS $$
DECLARE
    v_message chat.message%ROWTYPE;
    v_existing_hash char(64);
    v_idempotency_status smallint;
    v_claimed boolean := false;
    v_community_id varchar(64);
    v_recipient_member_id varchar(64);
BEGIN
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' OR p_request_hash IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Idempotency key and request hash are required.';
    END IF;
    IF p_idempotency_expires_at <= CURRENT_TIMESTAMP OR p_sync_expires_at <= CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Idempotency and sync expiry must be in the future.';
    END IF;
    IF p_message_type NOT IN ('TEXT','FILE','SYSTEM') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Unsupported message type.';
    END IF;

    INSERT INTO ops.idempotency_record(scope, idempotency_key, actor_id, request_hash, expires_at)
    VALUES ('chat.save_message', p_idempotency_key, p_sender_member_id, p_request_hash, p_idempotency_expires_at)
    ON CONFLICT (scope, actor_id, idempotency_key) DO NOTHING
    RETURNING true INTO v_claimed;
    SELECT request_hash, status_code
    INTO v_existing_hash, v_idempotency_status
    FROM ops.idempotency_record
    WHERE scope = 'chat.save_message'
      AND actor_id = p_sender_member_id
      AND idempotency_key = p_idempotency_key
    FOR UPDATE;
    IF v_existing_hash IS DISTINCT FROM p_request_hash THEN
        RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'Idempotency key was already used with a different request.';
    END IF;
    IF NOT COALESCE(v_claimed, false) THEN
        IF v_idempotency_status IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = '55P03', MESSAGE = 'Idempotent operation is still in progress.';
        END IF;
        SELECT * INTO v_message FROM chat.message WHERE message_id = p_message_id;
        IF NOT FOUND OR v_message.conversation_id IS DISTINCT FROM p_conversation_id
           OR v_message.sender_member_id IS DISTINCT FROM p_sender_member_id
           OR v_message.message_type IS DISTINCT FROM p_message_type
           OR v_message.body IS DISTINCT FROM p_body
           OR v_message.client_sent_at IS DISTINCT FROM p_client_sent_at THEN
            RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'Idempotency result does not match the message request.';
        END IF;
        RETURN NEXT v_message;
        RETURN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM chat.vw_authorized_conversation
        WHERE conversation_id = p_conversation_id AND member_id = p_sender_member_id AND can_send
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Member is not authorized to send to this conversation.';
    END IF;
    PERFORM 1 FROM chat.conversation WHERE conversation_id = p_conversation_id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM chat.message WHERE message_id = p_message_id) THEN
        RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'message_id is already bound to another idempotent operation.';
    END IF;
    INSERT INTO chat.message(message_id, conversation_id, sender_member_id, message_type, body, client_sent_at)
    VALUES (p_message_id, p_conversation_id, p_sender_member_id, p_message_type, p_body, p_client_sent_at)
    RETURNING * INTO v_message;

    UPDATE chat.conversation
    SET last_message_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
    WHERE conversation_id = p_conversation_id;

    SELECT sender.community_id, recipient.member_id
    INTO v_community_id, v_recipient_member_id
    FROM iam.member sender
    JOIN chat.conversation_participant recipient
      ON recipient.conversation_id = p_conversation_id
     AND recipient.member_id <> p_sender_member_id
    WHERE sender.member_id = p_sender_member_id;

    INSERT INTO ops.outbox_event(outbox_event_id, aggregate_type, aggregate_id, event_type, payload_json)
    VALUES (gen_random_uuid()::text, 'MESSAGE', p_message_id, 'MessageCreated.v1',
            jsonb_build_object(
                'message_id', p_message_id,
                'conversation_id', p_conversation_id,
                'sender_member_id', p_sender_member_id,
                'recipient_member_id', v_recipient_member_id,
                'server_sequence', v_message.server_sequence
            ));
    INSERT INTO ops.sync_change(
        community_id, member_scope_id, resource_type, resource_id, change_type,
        resource_version, payload_json, expires_at
    )
    SELECT v_community_id, cp.member_id, 'MESSAGE', p_message_id, 'UPSERT',
           v_message.row_version,
           jsonb_build_object(
               'messageId', p_message_id,
               'conversationId', p_conversation_id,
               'senderMemberId', p_sender_member_id,
               'serverSequence', v_message.server_sequence
           ),
           p_sync_expires_at
    FROM chat.conversation_participant cp
    WHERE cp.conversation_id = p_conversation_id;

    UPDATE ops.idempotency_record
    SET status_code = 200, response_ref = p_message_id
    WHERE scope = 'chat.save_message'
      AND actor_id = p_sender_member_id
      AND idempotency_key = p_idempotency_key;
    RETURN NEXT v_message;
END;
$$;

CREATE OR REPLACE FUNCTION chat.save_message_receipt(
    p_message_id varchar(64), p_member_id varchar(64),
    p_delivered_at timestamptz, p_read_at timestamptz,
    p_idempotency_key varchar(128), p_request_hash char(64),
    p_idempotency_expires_at timestamptz, p_sync_expires_at timestamptz
)
RETURNS SETOF chat.message_receipt
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, chat, ops, iam
AS $$
DECLARE
    v_receipt chat.message_receipt%ROWTYPE;
    v_existing_hash char(64);
    v_idempotency_status smallint;
    v_claimed boolean := false;
    v_changed boolean := false;
    v_delivered_at timestamptz := COALESCE(p_delivered_at, p_read_at);
    v_conversation_id varchar(64);
    v_community_id varchar(64);
    v_message_version bigint;
BEGIN
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' OR p_request_hash IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Idempotency key and request hash are required.';
    END IF;
    IF p_idempotency_expires_at <= CURRENT_TIMESTAMP OR p_sync_expires_at <= CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Idempotency and sync expiry must be in the future.';
    END IF;
    IF v_delivered_at IS NULL AND p_read_at IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A delivered or read timestamp is required.';
    END IF;

    INSERT INTO ops.idempotency_record(scope, idempotency_key, actor_id, request_hash, expires_at)
    VALUES ('chat.save_message_receipt', p_idempotency_key, p_member_id, p_request_hash, p_idempotency_expires_at)
    ON CONFLICT (scope, actor_id, idempotency_key) DO NOTHING
    RETURNING true INTO v_claimed;
    SELECT request_hash, status_code
    INTO v_existing_hash, v_idempotency_status
    FROM ops.idempotency_record
    WHERE scope = 'chat.save_message_receipt'
      AND actor_id = p_member_id
      AND idempotency_key = p_idempotency_key
    FOR UPDATE;
    IF v_existing_hash IS DISTINCT FROM p_request_hash THEN
        RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'Idempotency key was already used with a different request.';
    END IF;
    IF NOT COALESCE(v_claimed, false) THEN
        IF v_idempotency_status IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = '55P03', MESSAGE = 'Idempotent operation is still in progress.';
        END IF;
        SELECT * INTO v_receipt
        FROM chat.message_receipt
        WHERE message_id = p_message_id AND member_id = p_member_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'Idempotency result does not match the receipt request.';
        END IF;
        RETURN NEXT v_receipt;
        RETURN;
    END IF;

    SELECT msg.conversation_id, msg.row_version, sender.community_id
    INTO v_conversation_id, v_message_version, v_community_id
    FROM chat.message msg
    JOIN iam.member sender ON sender.member_id = msg.sender_member_id
    WHERE msg.message_id = p_message_id
    FOR UPDATE OF msg;
    IF v_conversation_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Message not found.';
    END IF;

    INSERT INTO chat.message_receipt(message_id, member_id, delivered_at, read_at)
    VALUES (p_message_id, p_member_id, v_delivered_at, p_read_at)
    ON CONFLICT (message_id, member_id) DO UPDATE
    SET delivered_at = COALESCE(chat.message_receipt.delivered_at, EXCLUDED.delivered_at),
        read_at = COALESCE(chat.message_receipt.read_at, EXCLUDED.read_at),
        updated_at = CURRENT_TIMESTAMP
    WHERE (chat.message_receipt.delivered_at IS NULL AND EXCLUDED.delivered_at IS NOT NULL)
       OR (chat.message_receipt.read_at IS NULL AND EXCLUDED.read_at IS NOT NULL)
    RETURNING * INTO v_receipt;
    v_changed := FOUND;
    IF NOT v_changed THEN
        SELECT * INTO v_receipt
        FROM chat.message_receipt
        WHERE message_id = p_message_id AND member_id = p_member_id;
    END IF;

    IF p_read_at IS NOT NULL THEN
        UPDATE chat.conversation_participant cp
        SET last_read_message_id = p_message_id
        WHERE cp.conversation_id = v_conversation_id
          AND cp.member_id = p_member_id
          AND (
              cp.last_read_message_id IS NULL
              OR (SELECT old_message.server_sequence FROM chat.message old_message
                  WHERE old_message.message_id = cp.last_read_message_id) <=
                 (SELECT current_message.server_sequence FROM chat.message current_message
                  WHERE current_message.message_id = p_message_id)
          );
    END IF;

    IF v_changed THEN
        INSERT INTO ops.sync_change(
            community_id, member_scope_id, resource_type, resource_id, change_type,
            resource_version, payload_json, expires_at
        )
        SELECT v_community_id, cp.member_id, 'MESSAGE', p_message_id, 'UPSERT',
               v_message_version,
               jsonb_build_object(
                   'messageId', p_message_id,
                   'receiptMemberId', p_member_id,
                   'isDelivered', v_receipt.delivered_at IS NOT NULL,
                   'isRead', v_receipt.read_at IS NOT NULL
               ),
               p_sync_expires_at
        FROM chat.conversation_participant cp
        WHERE cp.conversation_id = v_conversation_id;
    END IF;

    UPDATE ops.idempotency_record
    SET status_code = 200, response_ref = p_message_id || ':' || p_member_id
    WHERE scope = 'chat.save_message_receipt'
      AND actor_id = p_member_id
      AND idempotency_key = p_idempotency_key;
    RETURN NEXT v_receipt;
END;
$$;

DO $verification$
DECLARE
    save_message_definition text := pg_get_functiondef(
        'chat.save_message(character varying, character varying, character varying, character varying, text, timestamp with time zone, character varying, character, timestamp with time zone, timestamp with time zone)'::regprocedure
    );
    save_receipt_definition text := pg_get_functiondef(
        'chat.save_message_receipt(character varying, character varying, timestamp with time zone, timestamp with time zone, character varying, character, timestamp with time zone, timestamp with time zone)'::regprocedure
    );
BEGIN
    IF save_message_definition NOT LIKE '%MessageCreated.v1%'
       OR save_message_definition NOT LIKE '%recipient_member_id%'
       OR save_message_definition NOT LIKE '%server_sequence%' THEN
        RAISE EXCEPTION 'chat.save_message does not expose the canonical message-created contract.';
    END IF;
    IF save_receipt_definition LIKE '%INSERT INTO ops.outbox_event%' THEN
        RAISE EXCEPTION 'chat.save_message_receipt still publishes an outbox event.';
    END IF;
END;
$verification$;

COMMENT ON SCHEMA ops IS 'OLGA.SchemaVersion=2.7';

RESET ROLE;
COMMIT;

-- ======================== migrations\006_v2_7_to_v2_8_industry_questionnaire.sql ========================
/*
OLGA Connect v2.7 -> v2.8: controlled industries and versioned member-profile questionnaires.

Run as the migration identity against an existing v2.7 development database. The script is
transactional, takes the shared migration lock, is rerunnable at v2.8, and does not delete member data.
*/
BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('olga_schema_migration', 0));

DO $version_guard$
DECLARE
    current_version text := obj_description('ops'::regnamespace, 'pg_namespace');
BEGIN
    IF current_version NOT IN ('OLGA.SchemaVersion=2.7', 'OLGA.SchemaVersion=2.8') THEN
        RAISE EXCEPTION 'Industry-questionnaire migration requires schema version 2.7 or 2.8; found %.',
            COALESCE(current_version, '<unset>');
    END IF;
END;
$version_guard$;

SET ROLE olga_ddl_admin;

-- The full setup drops this deployment-only helper after creating its constraints, so the
-- incremental migration recreates it transactionally and removes it again below.
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

ALTER TABLE core.member_sector
    ADD COLUMN IF NOT EXISTS custom_sector_name varchar(150) NULL;

-- core.sector_questionnaire: Current published questionnaire definition for a sector.
CREATE TABLE IF NOT EXISTS core.sector_questionnaire (
        sector_questionnaire_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Internal key.
        questionnaire_api_id varchar(64) NOT NULL, -- Stable API identifier.
        sector_code varchar(64) NOT NULL, -- FK controlled sector taxonomy.
        definition_version int NOT NULL CONSTRAINT df_sector_questionnaire_definition_version DEFAULT (1), -- Incremented whenever the published question set changes.
        status varchar(16) NOT NULL CONSTRAINT df_sector_questionnaire_status DEFAULT ('ACTIVE'), -- DRAFT, ACTIVE or RETIRED.
        created_at timestamptz NOT NULL CONSTRAINT df_sector_questionnaire_created_at DEFAULT (CURRENT_TIMESTAMP),
        updated_at timestamptz NOT NULL CONSTRAINT df_sector_questionnaire_updated_at DEFAULT (CURRENT_TIMESTAMP),
        row_version bigint NOT NULL DEFAULT 1,
        CONSTRAINT pk_sector_questionnaire PRIMARY KEY (sector_questionnaire_id),
        CONSTRAINT ux_sector_questionnaire_api_id UNIQUE (questionnaire_api_id)
    );
-- core.profile_question: Versioned generic or sector-specific member-profile question.
CREATE TABLE IF NOT EXISTS core.profile_question (
        profile_question_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL, -- Internal immutable question-version key.
        question_api_id varchar(64) NOT NULL, -- Stable API identifier for this question version.
        sector_code varchar(64) NULL, -- Null means the question is generic for every sector.
        question_code varchar(64) NOT NULL, -- Stable business code across question versions.
        question_version int NOT NULL CONSTRAINT df_profile_question_question_version DEFAULT (1),
        prompt varchar(500) NOT NULL,
        answer_type varchar(24) NOT NULL, -- SINGLE_SELECT, MULTI_SELECT, TEXT, NUMBER or BOOLEAN.
        is_required boolean NOT NULL CONSTRAINT df_profile_question_is_required DEFAULT (false),
        sort_order int NOT NULL CONSTRAINT df_profile_question_sort_order DEFAULT (0),
        configuration_json jsonb NOT NULL CONSTRAINT df_profile_question_configuration_json DEFAULT ('{}'::jsonb), -- Options and bounded validation metadata.
        status varchar(16) NOT NULL CONSTRAINT df_profile_question_status DEFAULT ('ACTIVE'), -- DRAFT, ACTIVE or RETIRED.
        created_at timestamptz NOT NULL CONSTRAINT df_profile_question_created_at DEFAULT (CURRENT_TIMESTAMP),
        updated_at timestamptz NOT NULL CONSTRAINT df_profile_question_updated_at DEFAULT (CURRENT_TIMESTAMP),
        row_version bigint NOT NULL DEFAULT 1,
        CONSTRAINT pk_profile_question PRIMARY KEY (profile_question_id),
        CONSTRAINT ux_profile_question_api_id UNIQUE (question_api_id)
    );
-- core.sector_questionnaire_question: Immutable membership of question versions in a questionnaire definition.
CREATE TABLE IF NOT EXISTS core.sector_questionnaire_question (
        sector_questionnaire_question_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
        sector_questionnaire_id bigint NOT NULL,
        definition_version int NOT NULL,
        profile_question_id bigint NOT NULL,
        is_required boolean NOT NULL,
        sort_order int NOT NULL,
        created_at timestamptz NOT NULL CONSTRAINT df_sector_questionnaire_question_created_at DEFAULT (CURRENT_TIMESTAMP),
        CONSTRAINT pk_sector_questionnaire_question PRIMARY KEY (sector_questionnaire_question_id)
    );
-- core.member_questionnaire_response: Member response to one exact sector-questionnaire definition.
CREATE TABLE IF NOT EXISTS core.member_questionnaire_response (
        member_questionnaire_response_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
        response_api_id varchar(64) NOT NULL,
        member_id varchar(64) NOT NULL,
        sector_questionnaire_id bigint NOT NULL,
        definition_version int NOT NULL,
        status varchar(20) NOT NULL CONSTRAINT df_member_questionnaire_response_status DEFAULT ('DRAFT'), -- DRAFT, COMPLETED or SUPERSEDED.
        completed_at timestamptz NULL,
        created_at timestamptz NOT NULL CONSTRAINT df_member_questionnaire_response_created_at DEFAULT (CURRENT_TIMESTAMP),
        updated_at timestamptz NOT NULL CONSTRAINT df_member_questionnaire_response_updated_at DEFAULT (CURRENT_TIMESTAMP),
        row_version bigint NOT NULL DEFAULT 1,
        CONSTRAINT pk_member_questionnaire_response PRIMARY KEY (member_questionnaire_response_id),
        CONSTRAINT ux_member_questionnaire_response_api_id UNIQUE (response_api_id)
    );
-- core.member_question_answer: Validated answer to the exact immutable question version shown to the member.
CREATE TABLE IF NOT EXISTS core.member_question_answer (
        member_question_answer_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
        answer_api_id varchar(64) NOT NULL,
        member_questionnaire_response_id bigint NOT NULL,
        profile_question_id bigint NOT NULL,
        answer_json jsonb NOT NULL,
        created_at timestamptz NOT NULL CONSTRAINT df_member_question_answer_created_at DEFAULT (CURRENT_TIMESTAMP),
        updated_at timestamptz NOT NULL CONSTRAINT df_member_question_answer_updated_at DEFAULT (CURRENT_TIMESTAMP),
        row_version bigint NOT NULL DEFAULT 1,
        CONSTRAINT pk_member_question_answer PRIMARY KEY (member_question_answer_id),
        CONSTRAINT ux_member_question_answer_api_id UNIQUE (answer_api_id)
    );

SELECT ops.add_constraint_if_missing('core', 'sector_questionnaire', 'fk_sector_questionnaire_sector_code', $constraint$FOREIGN KEY (sector_code) REFERENCES core.sector (sector_code)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'profile_question', 'fk_profile_question_sector_code', $constraint$FOREIGN KEY (sector_code) REFERENCES core.sector (sector_code)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'sector_questionnaire_question', 'fk_sector_questionnaire_question_questionnaire_id', $constraint$FOREIGN KEY (sector_questionnaire_id) REFERENCES core.sector_questionnaire (sector_questionnaire_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'sector_questionnaire_question', 'fk_sector_questionnaire_question_question_id', $constraint$FOREIGN KEY (profile_question_id) REFERENCES core.profile_question (profile_question_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_questionnaire_response', 'fk_member_questionnaire_response_member_id', $constraint$FOREIGN KEY (member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_questionnaire_response', 'fk_member_questionnaire_response_questionnaire_id', $constraint$FOREIGN KEY (sector_questionnaire_id) REFERENCES core.sector_questionnaire (sector_questionnaire_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_question_answer', 'fk_member_question_answer_response_id', $constraint$FOREIGN KEY (member_questionnaire_response_id) REFERENCES core.member_questionnaire_response (member_questionnaire_response_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_question_answer', 'fk_member_question_answer_question_id', $constraint$FOREIGN KEY (profile_question_id) REFERENCES core.profile_question (profile_question_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_sector', 'ck_member_sector_custom_name', $constraint$CHECK ((sector_code = 'OTHER' AND custom_sector_name IS NOT NULL AND btrim(custom_sector_name) <> '') OR (sector_code <> 'OTHER' AND custom_sector_name IS NULL))$constraint$);
SELECT ops.add_constraint_if_missing('core', 'sector_questionnaire', 'ck_sector_questionnaire_values', $constraint$CHECK (definition_version > 0 AND status IN ('DRAFT','ACTIVE','RETIRED'))$constraint$);
SELECT ops.add_constraint_if_missing('core', 'profile_question', 'ck_profile_question_values', $constraint$CHECK (question_version > 0 AND answer_type IN ('SINGLE_SELECT','MULTI_SELECT','TEXT','NUMBER','BOOLEAN') AND status IN ('DRAFT','ACTIVE','RETIRED') AND jsonb_typeof(configuration_json) = 'object')$constraint$);
SELECT ops.add_constraint_if_missing('core', 'sector_questionnaire_question', 'ck_sector_questionnaire_question_values', $constraint$CHECK (definition_version > 0)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_questionnaire_response', 'ck_member_questionnaire_response_values', $constraint$CHECK (definition_version > 0 AND status IN ('DRAFT','COMPLETED','SUPERSEDED') AND (status <> 'COMPLETED' OR completed_at IS NOT NULL))$constraint$);
SELECT ops.add_constraint_if_missing('core', 'member_question_answer', 'ck_member_question_answer_object', $constraint$CHECK (jsonb_typeof(answer_json) = 'object')$constraint$);
CREATE UNIQUE INDEX IF NOT EXISTS ux_sector_questionnaire_active ON core.sector_questionnaire (sector_code) WHERE status = 'ACTIVE';
CREATE UNIQUE INDEX IF NOT EXISTS ux_profile_question_scope_version ON core.profile_question (sector_code, question_code, question_version) NULLS NOT DISTINCT;
CREATE UNIQUE INDEX IF NOT EXISTS ux_profile_question_active ON core.profile_question (sector_code, question_code) NULLS NOT DISTINCT WHERE status = 'ACTIVE';
CREATE UNIQUE INDEX IF NOT EXISTS ux_sector_questionnaire_question_version ON core.sector_questionnaire_question (sector_questionnaire_id, definition_version, profile_question_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_member_questionnaire_response_version ON core.member_questionnaire_response (member_id, sector_questionnaire_id, definition_version);
CREATE UNIQUE INDEX IF NOT EXISTS ux_member_question_answer_question ON core.member_question_answer (member_questionnaire_response_id, profile_question_id);
CREATE INDEX IF NOT EXISTS ix_profile_question_sector_status_sort ON core.profile_question (sector_code, status, sort_order);
CREATE INDEX IF NOT EXISTS ix_sector_questionnaire_question_definition ON core.sector_questionnaire_question (sector_questionnaire_id, definition_version, sort_order);
CREATE INDEX IF NOT EXISTS ix_member_questionnaire_response_member_status ON core.member_questionnaire_response (member_id, status, updated_at);
CREATE INDEX IF NOT EXISTS ix_member_question_answer_response ON core.member_question_answer (member_questionnaire_response_id);

DROP FUNCTION ops.add_constraint_if_missing(name, name, name, text);

DO $audit_triggers$
DECLARE
    target regclass;
BEGIN
    FOREACH target IN ARRAY ARRAY[
        'core.sector_questionnaire'::regclass,
        'core.profile_question'::regclass,
        'core.member_questionnaire_response'::regclass,
        'core.member_question_answer'::regclass
    ]
    LOOP
        EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS created_by varchar(64)', target);
        EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS updated_by varchar(64)', target);
        EXECUTE format('UPDATE %s SET created_by = COALESCE(created_by, %L), updated_by = COALESCE(updated_by, created_by, %L) WHERE created_by IS NULL OR updated_by IS NULL', target, 'legacy_unknown', 'legacy_unknown');
        EXECUTE format('ALTER TABLE %s ALTER COLUMN created_by SET DEFAULT ops.current_audit_actor_id()', target);
        EXECUTE format('ALTER TABLE %s ALTER COLUMN updated_by SET DEFAULT ops.current_audit_actor_id()', target);
        EXECUTE format('ALTER TABLE %s ALTER COLUMN created_by SET NOT NULL', target);
        EXECUTE format('ALTER TABLE %s ALTER COLUMN updated_by SET NOT NULL', target);
        EXECUTE format('DROP TRIGGER IF EXISTS set_audit_actor ON %s', target);
        EXECUTE format('CREATE TRIGGER set_audit_actor BEFORE INSERT OR UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION ops.set_audit_actor()', target);
        EXECUTE format('DROP TRIGGER IF EXISTS set_row_version ON %s', target);
        EXECUTE format('CREATE TRIGGER set_row_version BEFORE UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION ops.set_row_version()', target);
    END LOOP;
END;
$audit_triggers$;

-- QA and early development databases used four short sector codes before the canonical API
-- taxonomy was approved. Reconcile only the exact known aliases and fail closed if a member or
-- child sector now depends on one of them. Organization.industry_code is textual, so update it too.
DO $legacy_sector_aliases$
DECLARE
    alias record;
BEGIN
    FOR alias IN
        SELECT * FROM (VALUES
            ('GOV'::varchar(64), 'GOVERNMENT'::varchar(64), 'Government & Public Sector'::varchar(150)),
            ('HEALTH'::varchar(64), 'HEALTHCARE'::varchar(64), 'Healthcare & Life Sciences'::varchar(150)),
            ('MFG'::varchar(64), 'MANUFACTURING'::varchar(64), 'Manufacturing & Industrial'::varchar(150)),
            ('TELCO'::varchar(64), 'TELECOMMUNICATIONS'::varchar(64), 'Telecommunications'::varchar(150))
        ) AS aliases(legacy_code, canonical_code, expected_name)
    LOOP
        IF EXISTS (
            SELECT 1 FROM core.sector
            WHERE sector_code = alias.legacy_code AND name = alias.expected_name
        ) THEN
            IF EXISTS (SELECT 1 FROM core.member_sector WHERE sector_code = alias.legacy_code)
               OR EXISTS (SELECT 1 FROM core.sector WHERE parent_sector_code = alias.legacy_code)
               OR EXISTS (SELECT 1 FROM core.sector_questionnaire WHERE sector_code = alias.legacy_code)
               OR EXISTS (SELECT 1 FROM core.profile_question WHERE sector_code = alias.legacy_code) THEN
                RAISE EXCEPTION 'Legacy sector % has dependent references and cannot be automatically canonicalized.', alias.legacy_code;
            END IF;
            UPDATE core.organization
            SET industry_code = alias.canonical_code, updated_at = CURRENT_TIMESTAMP
            WHERE industry_code = alias.legacy_code;
            DELETE FROM core.sector WHERE sector_code = alias.legacy_code;
        END IF;
    END LOOP;
END;
$legacy_sector_aliases$;

-- Controlled industry taxonomy and the first published profile questionnaire definition.
-- Question option codes are stable matching features; labels are presentation text for locale en.
INSERT INTO core.sector(sector_code, parent_sector_code, name, status, sort_order) VALUES
    ('TECHNOLOGY',NULL,'Technology, Software & AI','ACTIVE',10),
    ('FINANCIAL_SERVICES',NULL,'Financial Services, Fintech & Insurance','ACTIVE',20),
    ('HEALTHCARE',NULL,'Healthcare & Life Sciences','ACTIVE',30),
    ('EDUCATION',NULL,'Education & Training','ACTIVE',40),
    ('GOVERNMENT',NULL,'Government & Public Sector','ACTIVE',50),
    ('MANUFACTURING',NULL,'Manufacturing & Industrial','ACTIVE',60),
    ('RETAIL',NULL,'Retail, Consumer Goods & E-commerce','ACTIVE',70),
    ('TELECOMMUNICATIONS',NULL,'Telecommunications','ACTIVE',80),
    ('MEDIA',NULL,'Media, Marketing & Creative','ACTIVE',90),
    ('ENERGY',NULL,'Energy, Utilities & Climate','ACTIVE',100),
    ('CONSTRUCTION',NULL,'Construction, Real Estate & Infrastructure','ACTIVE',110),
    ('LOGISTICS',NULL,'Logistics, Supply Chain & Mobility','ACTIVE',120),
    ('PROFESSIONAL_SERVICES',NULL,'Professional & Business Services','ACTIVE',130),
    ('AGRICULTURE',NULL,'Agriculture & Food','ACTIVE',140),
    ('TRAVEL',NULL,'Travel, Hospitality & Events','ACTIVE',150),
    ('NONPROFIT',NULL,'Nonprofit & Social Impact','ACTIVE',160),
    ('OTHER',NULL,'Other / Not listed','ACTIVE',999)
ON CONFLICT (sector_code) DO UPDATE SET
    name = EXCLUDED.name, status = 'ACTIVE', sort_order = EXCLUDED.sort_order, updated_at = CURRENT_TIMESTAMP;

INSERT INTO core.sector_questionnaire(questionnaire_api_id, sector_code, definition_version, status)
SELECT 'sq_' || lower(sector_code), sector_code, 1, 'ACTIVE'
FROM core.sector
WHERE sector_code IN (
    'TECHNOLOGY','FINANCIAL_SERVICES','HEALTHCARE','EDUCATION','GOVERNMENT','MANUFACTURING','RETAIL',
    'TELECOMMUNICATIONS','MEDIA','ENERGY','CONSTRUCTION','LOGISTICS','PROFESSIONAL_SERVICES',
    'AGRICULTURE','TRAVEL','NONPROFIT','OTHER'
)
ON CONFLICT (questionnaire_api_id) DO UPDATE SET status = 'ACTIVE', updated_at = CURRENT_TIMESTAMP;

WITH question_seed(question_api_id, sector_code, question_code, prompt, answer_type, is_required, sort_order, options_text) AS (VALUES
    ('q_role_v1',NULL,'ROLE','What best describes your role?','SINGLE_SELECT',true,10,'FOUNDER:Founder or business owner|EXECUTIVE:Executive or senior leader|BUSINESS_DEVELOPMENT:Sales or business development|PRODUCT:Product or programme management|TECHNOLOGY:Technology or engineering|OPERATIONS:Operations or supply chain|MARKETING:Marketing or communications|FINANCE:Finance|INVESTOR:Investor|ADVISOR:Advisor or consultant|RESEARCHER:Researcher or academic|POLICYMAKER:Government or policymaker|OTHER:Other'),
    ('q_organization_provides_v1',NULL,'ORGANIZATION_PROVIDES','What does your organization primarily provide?','MULTI_SELECT',true,20,'PRODUCTS:Physical products|SOFTWARE:Software or technology|SERVICES:Professional services|MANUFACTURING:Manufacturing|DISTRIBUTION:Distribution or logistics|FUNDING:Funding or investment|RESEARCH:Research or intellectual property|EDUCATION:Education or training|INFRASTRUCTURE:Infrastructure|PUBLIC_SERVICES:Public services|SOCIAL_SERVICES:Nonprofit or social services|OTHER:Other'),
    ('q_customer_segments_v1',NULL,'CUSTOMER_SEGMENTS','Who do you primarily serve?','MULTI_SELECT',true,30,'CONSUMERS:Consumers|STARTUPS:Startups|SMES:Small and medium businesses|ENTERPRISES:Large enterprises|GOVERNMENT:Government|NONPROFITS:Nonprofit organizations|INVESTORS:Investors|EDUCATION:Educational institutions|HEALTHCARE:Healthcare organizations|OTHER:Other'),
    ('q_offers_v1',NULL,'OFFERS','What can you help other members with?','MULTI_SELECT',true,40,'EXPERTISE:Industry expertise|INTRODUCTIONS:Business introductions|FUNDING:Investment or funding|TECHNOLOGY:Technology|DISTRIBUTION:Sales or distribution|MARKET_ACCESS:Market access|TALENT:Hiring or talent|PROCUREMENT:Procurement or suppliers|RESEARCH:Research|ADVISORY:Mentoring or advisory|POLICY:Government or policy connections|OTHER:Other'),
    ('q_needs_v1',NULL,'NEEDS','What are you currently looking for?','MULTI_SELECT',true,50,'CLIENTS:Clients or customers|SUPPLIERS:Suppliers|DISTRIBUTORS:Distributors|FUNDING:Investors or funding|INVESTMENTS:Investment opportunities|TECHNOLOGY:Technology partners|PARTNERS:Business partners|TALENT:Talent|ADVISORS:Advisors or mentors|RESEARCH:Research partners|POLICY:Government or policy connections|COFOUNDERS:Co-founders|OTHER:Other'),
    ('q_markets_v1',NULL,'MARKETS','Which markets do you operate in or want to enter?','TEXT',false,60,NULL),

    ('q_technology_product_v1','TECHNOLOGY','TECH_PRODUCT','What type of technology or product do you provide?','MULTI_SELECT',true,110,'SAAS:SaaS|AI_ML:AI / ML|CYBERSECURITY:Cybersecurity|CLOUD:Cloud|DATA:Data and analytics|HARDWARE:Hardware|MARKETPLACE:Marketplace|DEV_TOOLS:Developer tools|ENTERPRISE_SOFTWARE:Enterprise software|CONSUMER_APP:Consumer application|OTHER:Other'),
    ('q_technology_buyer_v1','TECHNOLOGY','TECH_BUYER','Who normally buys or uses your solution?','MULTI_SELECT',true,120,'CONSUMERS:Consumers|STARTUPS:Startups|SMES:SMEs|ENTERPRISES:Enterprises|GOVERNMENT:Government|DEVELOPERS:Developers|OTHER:Industry-specific organizations'),
    ('q_technology_stage_v1','TECHNOLOGY','TECH_STAGE','What stage is the product or business?','SINGLE_SELECT',true,130,'IDEA:Idea|PROTOTYPE:Prototype|LAUNCHED:Launched|EARLY_REVENUE:Early revenue|GROWTH:Growth|ESTABLISHED:Established'),

    ('q_finance_segment_v1','FINANCIAL_SERVICES','FINANCE_SEGMENT','Which financial-services segment best describes your work?','MULTI_SELECT',true,110,'BANKING:Banking|PAYMENTS:Payments|LENDING:Lending|INSURANCE:Insurance|WEALTH:Wealth management|CAPITAL_MARKETS:Capital markets|REGTECH:Regtech|FINTECH_INFRA:Fintech infrastructure|OTHER:Other'),
    ('q_finance_model_v1','FINANCIAL_SERVICES','FINANCE_MODEL','What is your operating model?','MULTI_SELECT',true,120,'REGULATED:Regulated institution|TECH_PROVIDER:Technology provider|INTERMEDIARY:Intermediary|ADVISOR:Advisor|INVESTOR:Investor|SERVICE_PROVIDER:Service provider'),
    ('q_finance_seeking_v1','FINANCIAL_SERVICES','FINANCE_SEEKING','What type of partnership are you seeking?','MULTI_SELECT',true,130,'CUSTOMERS:Customers|REGULATED_PARTNERS:Regulated partners|DISTRIBUTION:Distribution|INTEGRATION:Technology integration|FUNDING:Funding|INVESTMENTS:Investment opportunities|MARKET_ACCESS:Market access'),

    ('q_healthcare_area_v1','HEALTHCARE','HEALTHCARE_AREA','Which healthcare area best describes your work?','MULTI_SELECT',true,110,'PROVIDER:Healthcare provider|PHARMA:Pharmaceutical|BIOTECH:Biotechnology|MEDTECH:Medical devices|DIAGNOSTICS:Diagnostics|HEALTHTECH:Health technology|WELLNESS:Wellness|SERVICES:Healthcare services|OTHER:Other'),
    ('q_healthcare_value_chain_v1','HEALTHCARE','HEALTHCARE_VALUE_CHAIN','Where do you operate in the healthcare value chain?','MULTI_SELECT',true,120,'RESEARCH:Research|DEVELOPMENT:Development|MANUFACTURING:Manufacturing|CLINICAL:Clinical delivery|DISTRIBUTION:Distribution|TECHNOLOGY:Technology|CONSULTING:Consulting|INVESTMENT:Investment'),
    ('q_healthcare_seeking_v1','HEALTHCARE','HEALTHCARE_SEEKING','What type of collaboration are you seeking?','MULTI_SELECT',true,130,'RESEARCH:Research|CLINICAL:Clinical partners|PROVIDERS:Providers|DISTRIBUTORS:Distributors|INVESTORS:Investors|TECHNOLOGY:Technology partners|SUPPLIERS:Suppliers|MARKET_ACCESS:Market access'),

    ('q_education_segment_v1','EDUCATION','EDUCATION_SEGMENT','Which education segment do you serve?','MULTI_SELECT',true,110,'K12:K-12|HIGHER_ED:Higher education|VOCATIONAL:Vocational training|CORPORATE:Corporate learning|CERTIFICATION:Professional certification|EDTECH:Edtech|OTHER:Other'),
    ('q_education_delivery_v1','EDUCATION','EDUCATION_DELIVERY','How is the education or training delivered?','MULTI_SELECT',true,120,'ONLINE:Online|IN_PERSON:In person|HYBRID:Hybrid|LICENSING:Institutional licensing|EMPLOYER:Employer-sponsored'),
    ('q_education_seeking_v1','EDUCATION','EDUCATION_SEEKING','What type of partner are you looking for?','MULTI_SELECT',true,130,'INSTITUTIONS:Educational institutions|EMPLOYERS:Employers|TRAINERS:Trainers|CONTENT:Content providers|TECHNOLOGY:Technology providers|FUNDERS:Funders|GOVERNMENT:Government'),

    ('q_government_area_v1','GOVERNMENT','GOVERNMENT_AREA','Which public-service or policy areas are relevant to your work?','MULTI_SELECT',true,110,'ECONOMIC_DEVELOPMENT:Economic development|HEALTHCARE:Healthcare|EDUCATION:Education|INFRASTRUCTURE:Infrastructure|DIGITAL_GOVERNMENT:Digital government|SUSTAINABILITY:Sustainability|PUBLIC_SAFETY:Public safety|INVESTMENT_PROMOTION:Investment promotion|OTHER:Other'),
    ('q_government_role_v1','GOVERNMENT','GOVERNMENT_ROLE','What best describes your current public-sector role?','MULTI_SELECT',true,120,'POLICY:Policymaking|SERVICE_DELIVERY:Service delivery|PROGRAMME:Programme management|PROCUREMENT:Procurement|REGULATION:Regulation|ECOSYSTEM:Ecosystem development|ADVISORY:Advisory'),
    ('q_government_seeking_v1','GOVERNMENT','GOVERNMENT_SEEKING','What external support or collaboration is relevant?','MULTI_SELECT',true,130,'TECHNOLOGY:Technology|SUPPLIERS:Suppliers|RESEARCH:Research|INVESTMENT:Investment|EXPERTISE:Industry expertise|IMPLEMENTATION:Implementation partners|PPP:Public-private partnerships'),

    ('q_manufacturing_product_v1','MANUFACTURING','MANUFACTURING_PRODUCT','What do you manufacture or support?','MULTI_SELECT',true,110,'CONSUMER_GOODS:Consumer goods|INDUSTRIAL_EQUIPMENT:Industrial equipment|ELECTRONICS:Electronics|AUTOMOTIVE:Automotive|CHEMICALS:Chemicals|PHARMA:Pharmaceuticals|MATERIALS:Materials|PACKAGING:Packaging|OTHER:Other'),
    ('q_manufacturing_capability_v1','MANUFACTURING','MANUFACTURING_CAPABILITY','Which capabilities do you provide?','MULTI_SELECT',true,120,'DESIGN:Product design|COMPONENTS:Component manufacturing|ASSEMBLY:Assembly|CONTRACT:Contract manufacturing|TESTING:Quality testing|AUTOMATION:Automation|MAINTENANCE:Maintenance|DISTRIBUTION:Distribution'),
    ('q_manufacturing_seeking_v1','MANUFACTURING','MANUFACTURING_SEEKING','What are you currently seeking?','MULTI_SELECT',true,130,'BUYERS:Buyers|SUPPLIERS:Suppliers|CONTRACT_MANUFACTURERS:Contract manufacturers|AUTOMATION:Automation|FINANCING:Financing|TECHNOLOGY:Technology|DISTRIBUTORS:Distributors|EXPANSION:Market expansion'),

    ('q_retail_category_v1','RETAIL','RETAIL_CATEGORY','Which product categories are relevant?','MULTI_SELECT',true,110,'FOOD_BEVERAGE:Food and beverage|FASHION:Fashion|BEAUTY:Beauty|ELECTRONICS:Electronics|HOME:Home|HEALTH:Health|LUXURY:Luxury|GENERAL:General merchandise|OTHER:Other'),
    ('q_retail_channel_v1','RETAIL','RETAIL_CHANNEL','Which sales channels do you use?','MULTI_SELECT',true,120,'PHYSICAL:Physical retail|OWN_ECOMMERCE:Own e-commerce|MARKETPLACES:Marketplaces|WHOLESALE:Wholesale|DISTRIBUTORS:Distributors|SOCIAL:Social commerce'),
    ('q_retail_seeking_v1','RETAIL','RETAIL_SEEKING','What type of partner are you seeking?','MULTI_SELECT',true,130,'BRANDS:Brands|RETAILERS:Retailers|DISTRIBUTORS:Distributors|MARKETPLACES:Marketplaces|LOGISTICS:Logistics|MARKETING:Marketing|TECHNOLOGY:Technology|INVESTORS:Investors'),

    ('q_telecom_area_v1','TELECOMMUNICATIONS','TELECOM_AREA','Which telecommunications area best describes your work?','MULTI_SELECT',true,110,'OPERATOR:Network operator|INFRASTRUCTURE:Infrastructure|CONNECTIVITY:Connectivity|ENTERPRISE:Enterprise solutions|DEVICES:Devices|IOT:IoT|SOFTWARE:Telecom software|OTHER:Other'),
    ('q_telecom_customer_v1','TELECOMMUNICATIONS','TELECOM_CUSTOMER','Which customer segments do you serve?','MULTI_SELECT',true,120,'CONSUMERS:Consumers|SMES:SMEs|ENTERPRISES:Enterprises|GOVERNMENT:Government|OPERATORS:Operators|TECH_PROVIDERS:Technology providers'),
    ('q_telecom_seeking_v1','TELECOMMUNICATIONS','TELECOM_SEEKING','What type of partnership is relevant?','MULTI_SELECT',true,130,'INFRASTRUCTURE:Infrastructure|TECHNOLOGY:Technology|CUSTOMERS:Enterprise customers|DISTRIBUTION:Distribution|INTEGRATION:Integration|INVESTMENT:Investment|GOVERNMENT:Government relationships'),

    ('q_media_capability_v1','MEDIA','MEDIA_CAPABILITY','Which capabilities do you provide?','MULTI_SELECT',true,110,'ADVERTISING:Advertising|BRANDING:Branding|PR:Public relations|CONTENT:Content creation|PUBLISHING:Publishing|PRODUCTION:Film or video production|EVENTS:Events|INFLUENCER:Influencer marketing|OTHER:Other'),
    ('q_media_platform_v1','MEDIA','MEDIA_PLATFORM','Which audiences or platforms are most relevant?','MULTI_SELECT',true,120,'CONSUMER:Consumer|B2B:B2B|TELEVISION:Television|PRINT:Print|DIGITAL:Digital|SOCIAL:Social media|STREAMING:Streaming|LIVE:Live events'),
    ('q_media_seeking_v1','MEDIA','MEDIA_SEEKING','What type of collaboration are you seeking?','MULTI_SELECT',true,130,'CLIENTS:Clients|SPONSORS:Sponsors|CREATORS:Creators|DISTRIBUTION:Distribution|PRODUCTION:Production partners|TECHNOLOGY:Technology|INVESTMENT:Investment'),

    ('q_energy_area_v1','ENERGY','ENERGY_AREA','Which area best describes your work?','MULTI_SELECT',true,110,'RENEWABLE:Renewable energy|CONVENTIONAL:Conventional energy|GRID:Grid|STORAGE:Energy storage|WATER:Water|WASTE:Waste|CARBON:Carbon management|CLIMATE_TECH:Climate technology|OTHER:Other'),
    ('q_energy_stage_v1','ENERGY','ENERGY_STAGE','What project stage do you support?','MULTI_SELECT',true,120,'RESEARCH:Research|DEVELOPMENT:Development|FINANCING:Financing|CONSTRUCTION:Construction|OPERATIONS:Operations|TECHNOLOGY:Technology|ADVISORY:Advisory'),
    ('q_energy_seeking_v1','ENERGY','ENERGY_SEEKING','What are you seeking?','MULTI_SELECT',true,130,'CAPITAL:Project capital|SITES:Sites|CUSTOMERS:Customers|TECHNOLOGY:Technology|SUPPLIERS:Suppliers|IMPLEMENTATION:Implementation partners|GOVERNMENT:Government relationships'),

    ('q_construction_asset_v1','CONSTRUCTION','CONSTRUCTION_ASSET','Which asset classes are relevant?','MULTI_SELECT',true,110,'RESIDENTIAL:Residential|COMMERCIAL:Commercial|INDUSTRIAL:Industrial|HOSPITALITY:Hospitality|MIXED_USE:Mixed-use|PUBLIC_INFRA:Public infrastructure'),
    ('q_construction_role_v1','CONSTRUCTION','CONSTRUCTION_ROLE','What is your role in the project lifecycle?','MULTI_SELECT',true,120,'DEVELOPMENT:Development|INVESTMENT:Investment|DESIGN:Design|CONSTRUCTION:Construction|SUPPLY:Supply|OPERATIONS:Operations|TECHNOLOGY:Technology|ADVISORY:Advisory'),
    ('q_construction_seeking_v1','CONSTRUCTION','CONSTRUCTION_SEEKING','What are you seeking?','MULTI_SELECT',true,130,'PROJECTS:Projects|CAPITAL:Capital|CONTRACTORS:Contractors|SUPPLIERS:Suppliers|TECHNOLOGY:Technology|TENANTS:Tenants|BUYERS:Buyers|GOVERNMENT:Government relationships'),

    ('q_logistics_service_v1','LOGISTICS','LOGISTICS_SERVICE','Which logistics or mobility services do you provide?','MULTI_SELECT',true,110,'FREIGHT:Freight|WAREHOUSING:Warehousing|LAST_MILE:Last-mile delivery|COLD_CHAIN:Cold chain|CUSTOMS:Customs|FLEET:Fleet services|MOBILITY:Mobility|SOFTWARE:Supply-chain software'),
    ('q_logistics_mode_v1','LOGISTICS','LOGISTICS_MODE','Which transport modes do you support?','MULTI_SELECT',true,120,'ROAD:Road|AIR:Air|SEA:Sea|RAIL:Rail|MULTIMODAL:Multimodal'),
    ('q_logistics_seeking_v1','LOGISTICS','LOGISTICS_SEEKING','What are you currently seeking?','MULTI_SELECT',true,130,'SHIPPERS:Shippers|CARRIERS:Carriers|WAREHOUSE:Warehouse capacity|TECHNOLOGY:Technology|INFRASTRUCTURE:Infrastructure|FINANCING:Financing|EXPANSION:Market expansion'),

    ('q_professional_discipline_v1','PROFESSIONAL_SERVICES','PROFESSIONAL_DISCIPLINE','Which professional discipline best describes your work?','MULTI_SELECT',true,110,'CONSULTING:Consulting|LEGAL:Legal|ACCOUNTING:Accounting|RECRUITMENT:Recruitment|HR:HR|DESIGN:Design|OUTSOURCING:Outsourced operations|COMPLIANCE:Compliance|OTHER:Other'),
    ('q_professional_client_v1','PROFESSIONAL_SERVICES','PROFESSIONAL_CLIENT','Which types of clients do you primarily serve?','MULTI_SELECT',true,120,'STARTUPS:Startups|SMES:SMEs|ENTERPRISES:Enterprises|GOVERNMENT:Government|NONPROFITS:Nonprofits|INDIVIDUALS:Individuals'),
    ('q_professional_seeking_v1','PROFESSIONAL_SERVICES','PROFESSIONAL_SEEKING','What type of opportunities are relevant?','MULTI_SELECT',true,130,'CLIENTS:Clients|REFERRALS:Referral partners|DELIVERY:Delivery partners|EXPERTISE:Specialist expertise|GEOGRAPHY:Geographic coverage|PARTNERSHIPS:Strategic partnerships'),

    ('q_agriculture_value_chain_v1','AGRICULTURE','AGRICULTURE_VALUE_CHAIN','Where do you operate in the value chain?','MULTI_SELECT',true,110,'FARMING:Farming|INPUTS:Inputs|PROCESSING:Processing|INGREDIENTS:Ingredients|MANUFACTURING:Food manufacturing|DISTRIBUTION:Distribution|BRANDS:Food brands|FOOD_SERVICE:Food service|AGTECH:Agtech'),
    ('q_agriculture_category_v1','AGRICULTURE','AGRICULTURE_CATEGORY','Which product categories are relevant?','TEXT',true,120,NULL),
    ('q_agriculture_seeking_v1','AGRICULTURE','AGRICULTURE_SEEKING','What are you currently seeking?','MULTI_SELECT',true,130,'BUYERS:Buyers|SUPPLIERS:Suppliers|TECHNOLOGY:Technology|FINANCING:Financing|PROCESSING:Processing capacity|DISTRIBUTORS:Distributors|CERTIFICATION:Certification support|MARKET_ACCESS:Market access'),

    ('q_travel_segment_v1','TRAVEL','TRAVEL_SEGMENT','Which segment best describes your work?','MULTI_SELECT',true,110,'ACCOMMODATION:Accommodation|TOURISM:Tourism|TRAVEL_SERVICES:Travel services|TRAVEL_TECH:Travel technology|VENUES:Venues|EVENTS:Corporate events|DESTINATION:Destination services'),
    ('q_travel_customer_v1','TRAVEL','TRAVEL_CUSTOMER','Which customer groups do you serve?','MULTI_SELECT',true,120,'LEISURE:Leisure travellers|BUSINESS:Business travellers|GROUPS:Groups|ENTERPRISES:Enterprises|ORGANIZERS:Event organizers|GOVERNMENT:Government'),
    ('q_travel_seeking_v1','TRAVEL','TRAVEL_SEEKING','What type of partnership are you seeking?','MULTI_SELECT',true,130,'DISTRIBUTION:Distribution|CORPORATE_CLIENTS:Corporate clients|SUPPLIERS:Suppliers|VENUES:Venues|SPONSORS:Sponsors|TECHNOLOGY:Technology|DESTINATIONS:Destination partners'),

    ('q_nonprofit_cause_v1','NONPROFIT','NONPROFIT_CAUSE','Which cause areas are relevant?','MULTI_SELECT',true,110,'EDUCATION:Education|HEALTH:Health|ENVIRONMENT:Environment|POVERTY:Poverty reduction|YOUTH:Youth|INCLUSION:Inclusion|HUMANITARIAN:Humanitarian support|COMMUNITY:Community development'),
    ('q_nonprofit_model_v1','NONPROFIT','NONPROFIT_MODEL','What is your operating model?','MULTI_SELECT',true,120,'DIRECT_SERVICE:Direct service|ADVOCACY:Advocacy|GRANTMAKING:Grantmaking|RESEARCH:Research|CAPACITY:Capacity building|SOCIAL_ENTERPRISE:Social enterprise'),
    ('q_nonprofit_seeking_v1','NONPROFIT','NONPROFIT_SEEKING','What type of support are you seeking?','MULTI_SELECT',true,130,'FUNDING:Funding|VOLUNTEERS:Volunteers|CORPORATE:Corporate partners|GOVERNMENT:Government relationships|TECHNOLOGY:Technology|EXPERTISE:Expertise|DELIVERY:Delivery partners'),

    ('q_other_industry_v1','OTHER','OTHER_INDUSTRY','How would you describe your industry or field?','TEXT',true,110,NULL),
    ('q_other_work_v1','OTHER','OTHER_WORK','What does your organization do?','TEXT',true,120,NULL),
    ('q_other_counterpart_v1','OTHER','OTHER_COUNTERPART','What type of people or organizations would be useful to meet?','TEXT',true,130,NULL)
)
INSERT INTO core.profile_question(
    question_api_id, sector_code, question_code, question_version, prompt, answer_type,
    is_required, sort_order, configuration_json, status
)
SELECT question_api_id, sector_code, question_code, 1, prompt, answer_type, is_required, sort_order,
       CASE
           WHEN options_text IS NULL THEN jsonb_build_object('max_length', 1000)
           ELSE jsonb_build_object(
               'options', (
                   SELECT jsonb_agg(
                       jsonb_build_object('code', split_part(option_value, ':', 1), 'label', split_part(option_value, ':', 2))
                       ORDER BY option_order
                   )
                   FROM unnest(string_to_array(options_text, '|')) WITH ORDINALITY AS option_row(option_value, option_order)
               ),
               'min_selections', 1,
               'max_selections', CASE WHEN answer_type = 'SINGLE_SELECT' THEN 1 WHEN sort_order < 100 THEN 8 ELSE 5 END
           )
       END,
       'ACTIVE'
FROM question_seed
ON CONFLICT (question_api_id) DO NOTHING;

INSERT INTO core.sector_questionnaire_question(
    sector_questionnaire_id, definition_version, profile_question_id, is_required, sort_order
)
SELECT sq.sector_questionnaire_id, sq.definition_version, q.profile_question_id, q.is_required, q.sort_order
FROM core.sector_questionnaire sq
JOIN core.profile_question q ON q.status = 'ACTIVE' AND (q.sector_code IS NULL OR q.sector_code = sq.sector_code)
WHERE sq.status = 'ACTIVE'
ON CONFLICT (sector_questionnaire_id, definition_version, profile_question_id) DO NOTHING;

-- Conservative legacy backfill: only exact controlled codes are migrated. Ambiguous role_category
-- values remain untouched for product review instead of being silently reclassified.
INSERT INTO core.member_sector(member_id, sector_code, is_primary)
SELECT p.member_id, s.sector_code, true
FROM core.member_profile p
JOIN core.sector s ON s.sector_code = upper(btrim(p.role_category)) AND s.status = 'ACTIVE'
WHERE p.role_category IS NOT NULL
  AND s.sector_code <> 'OTHER'
  AND NOT EXISTS (SELECT 1 FROM core.member_sector ms WHERE ms.member_id = p.member_id AND ms.is_primary)
ON CONFLICT (member_id, sector_code) DO NOTHING;

REVOKE INSERT, UPDATE, DELETE ON
    core.sector, core.sector_questionnaire, core.profile_question, core.sector_questionnaire_question
FROM olga_dml_writer;
GRANT SELECT ON
    core.sector, core.sector_questionnaire, core.profile_question, core.sector_questionnaire_question
TO olga_dml_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON
    core.member_questionnaire_response, core.member_question_answer
TO olga_dml_writer;
GRANT SELECT ON
    core.sector_questionnaire, core.profile_question, core.sector_questionnaire_question,
    core.member_questionnaire_response, core.member_question_answer
TO olga_reader;
REVOKE ALL PRIVILEGES ON
    core.sector_questionnaire, core.profile_question, core.sector_questionnaire_question,
    core.member_questionnaire_response, core.member_question_answer
FROM olga_nlp_worker;
DO $questionnaire_sequence_privileges$
DECLARE
    sequence_name text;
    runtime_writable boolean;
BEGIN
    FOR sequence_name, runtime_writable IN
        SELECT * FROM (VALUES
            (pg_get_serial_sequence('core.sector_questionnaire', 'sector_questionnaire_id'), false),
            (pg_get_serial_sequence('core.profile_question', 'profile_question_id'), false),
            (pg_get_serial_sequence('core.sector_questionnaire_question', 'sector_questionnaire_question_id'), false),
            (pg_get_serial_sequence('core.member_questionnaire_response', 'member_questionnaire_response_id'), true),
            (pg_get_serial_sequence('core.member_question_answer', 'member_question_answer_id'), true)
        ) AS sequences(name, writable)
    LOOP
        IF sequence_name IS NULL THEN
            RAISE EXCEPTION 'Questionnaire identity sequence could not be resolved.';
        END IF;
        IF runtime_writable THEN
            EXECUTE format('GRANT USAGE, SELECT, UPDATE ON SEQUENCE %s TO olga_dml_writer', sequence_name);
        ELSE
            EXECUTE format('REVOKE ALL PRIVILEGES ON SEQUENCE %s FROM olga_dml_writer', sequence_name);
        END IF;
        EXECUTE format('GRANT SELECT ON SEQUENCE %s TO olga_reader', sequence_name);
        EXECUTE format('REVOKE ALL PRIVILEGES ON SEQUENCE %s FROM olga_nlp_worker', sequence_name);
    END LOOP;
END;
$questionnaire_sequence_privileges$;

DO $verify$
DECLARE
    target regclass;
BEGIN
    IF (SELECT count(*) FROM core.sector_questionnaire WHERE status = 'ACTIVE') <> 17
       OR (SELECT count(*) FROM core.profile_question WHERE sector_code IS NULL AND status = 'ACTIVE') <> 6
       OR NOT EXISTS (SELECT 1 FROM core.sector WHERE sector_code = 'OTHER' AND status = 'ACTIVE')
       OR EXISTS (
            SELECT 1 FROM core.sector_questionnaire sq
            WHERE sq.status = 'ACTIVE'
              AND NOT EXISTS (
                  SELECT 1 FROM core.sector_questionnaire_question sqq
                  WHERE sqq.sector_questionnaire_id = sq.sector_questionnaire_id
                    AND sqq.definition_version = sq.definition_version
              )
       ) THEN
        RAISE EXCEPTION 'Industry questionnaire reference data is missing or inconsistent.';
    END IF;
    IF NOT has_table_privilege('olga_dml_writer', 'core.sector_questionnaire', 'SELECT')
       OR NOT has_table_privilege('olga_dml_writer', 'core.profile_question', 'SELECT')
       OR NOT has_table_privilege('olga_dml_writer', 'core.sector_questionnaire_question', 'SELECT')
       OR has_table_privilege('olga_dml_writer', 'core.sector_questionnaire', 'UPDATE')
       OR has_table_privilege('olga_dml_writer', 'core.profile_question', 'UPDATE')
       OR has_table_privilege('olga_dml_writer', 'core.sector_questionnaire_question', 'INSERT') THEN
        RAISE EXCEPTION 'Questionnaire-definition privileges exceed the approved runtime boundary.';
    END IF;
    FOREACH target IN ARRAY ARRAY[
        'core.sector_questionnaire'::regclass,
        'core.profile_question'::regclass,
        'core.member_questionnaire_response'::regclass,
        'core.member_question_answer'::regclass
    ]
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_trigger
            WHERE tgrelid = target AND tgname = 'set_row_version' AND tgenabled <> 'D'
        ) THEN
            RAISE EXCEPTION 'Required row-version trigger is missing for %.', target;
        END IF;
    END LOOP;
END;
$verify$;

COMMENT ON SCHEMA ops IS 'OLGA.SchemaVersion=2.8';
RESET ROLE;
COMMIT;

-- ======================== migrations\007_v2_8_to_v2_9_social_capital_index.sql ========================
/*
OLGA Connect v2.8 -> v2.9: ventures, imported-contact vault, invitation consent,
and the intent-gated Social Capital Index.

Run as the migration identity against an existing v2.8 development database. The
script is transactional, takes the shared migration lock, is rerunnable at v2.9,
and does not delete member data. The SCI scoring configuration is installed as
DRAFT and must not be activated until calibration is reviewed.
*/
BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('olga_schema_migration', 0));

DO $version_guard$
DECLARE
    current_version text := obj_description('ops'::regnamespace, 'pg_namespace');
BEGIN
    IF current_version NOT IN ('OLGA.SchemaVersion=2.8', 'OLGA.SchemaVersion=2.9') THEN
        RAISE EXCEPTION 'SCI migration requires schema version 2.8 or 2.9; found %.',
            COALESCE(current_version, '<unset>');
    END IF;
END;
$version_guard$;

SET ROLE olga_ddl_admin;

/*
OLGA Connect Social Capital Index database extension.

This module is included by the current full setup and embedded verbatim in the
v2.8 -> v2.9 migration. It intentionally reuses the existing Core, Social, NLP,
outbox, audit, and worker boundaries; it does not introduce a new service or an
approximate vector index.
*/

CREATE OR REPLACE FUNCTION ops.add_constraint_if_missing(
    p_schema name, p_table name, p_constraint name, p_definition text
)
RETURNS void
LANGUAGE plpgsql
AS $function$
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
$function$;

-- A venture is a member-owned business context. It is deliberately distinct from
-- core.organization, which remains the canonical professional organization record.
CREATE TABLE IF NOT EXISTS core.venture (
    venture_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    venture_id varchar(64) NOT NULL,
    owner_member_id varchar(64) NOT NULL,
    organization_id varchar(64) NULL,
    name varchar(250) NOT NULL,
    industry_code varchar(64) NULL,
    stage_code varchar(32) NULL,
    revenue_band_code varchar(32) NULL,
    team_size_band_code varchar(32) NULL,
    status varchar(20) NOT NULL DEFAULT 'ACTIVE',
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_version bigint NOT NULL DEFAULT 1,
    created_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    updated_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    CONSTRAINT pk_venture PRIMARY KEY (venture_pk),
    CONSTRAINT ux_venture_id UNIQUE (venture_id)
);

CREATE TABLE IF NOT EXISTS core.venture_geography (
    venture_pk bigint NOT NULL,
    geography_code varchar(64) NOT NULL,
    is_primary boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_venture_geography PRIMARY KEY (venture_pk, geography_code)
);

CREATE TABLE IF NOT EXISTS core.venture_qualification (
    venture_qualification_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    qualification_id varchar(64) NOT NULL,
    venture_pk bigint NOT NULL,
    qualification_code varchar(64) NOT NULL,
    comparison_operator varchar(16) NOT NULL,
    required_value_json jsonb NOT NULL,
    status varchar(16) NOT NULL DEFAULT 'ACTIVE',
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_version bigint NOT NULL DEFAULT 1,
    created_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    updated_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    CONSTRAINT pk_venture_qualification PRIMARY KEY (venture_qualification_pk),
    CONSTRAINT ux_venture_qualification_id UNIQUE (qualification_id)
);

-- One versioned structured intent set groups the WANT and OFFER nlp_intent rows
-- for a venture. Event-specific intents continue to use the existing context flow.
CREATE TABLE IF NOT EXISTS nlp.venture_intent_set (
    venture_intent_set_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    intent_set_id varchar(64) NOT NULL,
    venture_pk bigint NOT NULL,
    owner_member_id varchar(64) NOT NULL,
    intent_version int NOT NULL,
    raw_text varchar(4000) NOT NULL,
    structured_intent_json jsonb NOT NULL,
    valid_until timestamptz NOT NULL,
    status varchar(20) NOT NULL DEFAULT 'PROCESSING',
    supersedes_intent_set_pk bigint NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_version bigint NOT NULL DEFAULT 1,
    created_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    updated_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    CONSTRAINT pk_venture_intent_set PRIMARY KEY (venture_intent_set_pk),
    CONSTRAINT ux_venture_intent_set_id UNIQUE (intent_set_id)
);

ALTER TABLE nlp.nlp_intent
    ADD COLUMN IF NOT EXISTS venture_intent_set_pk bigint NULL;

-- Owner-scoped imported-contact vault. No raw non-member identifier is persisted.
CREATE TABLE IF NOT EXISTS social.contact_record (
    contact_record_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    contact_record_id varchar(64) NOT NULL,
    owner_member_id varchar(64) NOT NULL,
    label_ciphertext bytea NOT NULL,
    source_type varchar(24) NOT NULL,
    status varchar(16) NOT NULL DEFAULT 'ACTIVE',
    first_imported_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_refreshed_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_version bigint NOT NULL DEFAULT 1,
    created_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    updated_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    CONSTRAINT pk_contact_record PRIMARY KEY (contact_record_pk),
    CONSTRAINT ux_contact_record_id UNIQUE (contact_record_id),
    CONSTRAINT ux_contact_record_owner_pair UNIQUE (contact_record_pk, owner_member_id)
);

CREATE TABLE IF NOT EXISTS social.contact_identifier (
    contact_identifier_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    contact_record_pk bigint NOT NULL,
    owner_member_id varchar(64) NOT NULL,
    identifier_type varchar(16) NOT NULL,
    identifier_hash char(64) NOT NULL,
    hash_key_version varchar(32) NOT NULL,
    source_type varchar(24) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_contact_identifier PRIMARY KEY (contact_identifier_pk)
);

-- The link holds import/join/consent lifecycle. SCI placement remains per venture
-- in nlp.sci_link_score so one contact can be in one SCI and outside another.
CREATE TABLE IF NOT EXISTS social.contact_link (
    contact_link_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    link_id varchar(64) NOT NULL,
    owner_member_id varchar(64) NOT NULL,
    contact_record_pk bigint NOT NULL,
    contact_member_id varchar(64) NULL,
    connection_id varchar(64) NULL,
    origin_type varchar(16) NOT NULL DEFAULT 'IMPORT',
    lifecycle_state varchar(20) NOT NULL DEFAULT 'IMPORTED',
    consent_at timestamptz NULL,
    joined_at timestamptz NULL,
    pinned_at timestamptz NULL,
    hidden_at timestamptz NULL,
    last_transition_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_version bigint NOT NULL DEFAULT 1,
    created_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    updated_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    CONSTRAINT pk_contact_link PRIMARY KEY (contact_link_pk),
    CONSTRAINT ux_contact_link_id UNIQUE (link_id),
    CONSTRAINT ux_contact_link_owner_pair UNIQUE (contact_link_pk, owner_member_id),
    CONSTRAINT ux_contact_link_record UNIQUE (contact_record_pk)
);

CREATE TABLE IF NOT EXISTS social.invite_batch (
    invite_batch_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    batch_id varchar(64) NOT NULL,
    owner_member_id varchar(64) NOT NULL,
    venture_pk bigint NULL,
    status varchar(16) NOT NULL DEFAULT 'DRAFT',
    approved_at timestamptz NULL,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_version bigint NOT NULL DEFAULT 1,
    created_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    updated_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    CONSTRAINT pk_invite_batch PRIMARY KEY (invite_batch_pk),
    CONSTRAINT ux_invite_batch_id UNIQUE (batch_id),
    CONSTRAINT ux_invite_batch_owner_pair UNIQUE (invite_batch_pk, owner_member_id)
);

CREATE TABLE IF NOT EXISTS social.invitation (
    invitation_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    invitation_id varchar(64) NOT NULL,
    invite_batch_pk bigint NOT NULL,
    contact_link_pk bigint NOT NULL,
    owner_member_id varchar(64) NOT NULL,
    batch_position smallint NOT NULL,
    token_hash char(64) NOT NULL,
    status varchar(16) NOT NULL DEFAULT 'APPROVED',
    first_opened_at timestamptz NULL,
    accepted_at timestamptz NULL,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_version bigint NOT NULL DEFAULT 1,
    created_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    updated_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    CONSTRAINT pk_invitation PRIMARY KEY (invitation_pk),
    CONSTRAINT ux_invitation_id UNIQUE (invitation_id),
    CONSTRAINT ux_invitation_token_hash UNIQUE (token_hash),
    CONSTRAINT ux_invitation_batch_position UNIQUE (invite_batch_pk, batch_position),
    CONSTRAINT ux_invitation_batch_link UNIQUE (invite_batch_pk, contact_link_pk)
);

-- A confirmed encounter requires one evidence row from each member in the accepted
-- Commit/connection request. Revocation preserves the evidence trail.
CREATE TABLE IF NOT EXISTS social.meeting_confirmation (
    meeting_confirmation_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    confirmation_id varchar(64) NOT NULL,
    connection_request_id varchar(64) NOT NULL,
    confirmer_member_id varchar(64) NOT NULL,
    idempotency_key varchar(128) NOT NULL,
    confirmed_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked_at timestamptz NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_meeting_confirmation PRIMARY KEY (meeting_confirmation_pk),
    CONSTRAINT ux_meeting_confirmation_id UNIQUE (confirmation_id),
    CONSTRAINT ux_meeting_confirmation_member UNIQUE (connection_request_id, confirmer_member_id),
    CONSTRAINT ux_meeting_confirmation_idempotency UNIQUE (confirmer_member_id, idempotency_key)
);

CREATE TABLE IF NOT EXISTS social.contact_link_event (
    contact_link_event_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    link_event_id varchar(64) NOT NULL,
    contact_link_pk bigint NOT NULL,
    venture_pk bigint NULL,
    event_type varchar(32) NOT NULL,
    from_state varchar(20) NULL,
    to_state varchar(20) NULL,
    from_score numeric(5,2) NULL,
    to_score numeric(5,2) NULL,
    from_role varchar(32) NULL,
    to_role varchar(32) NULL,
    details_json jsonb NULL,
    occurred_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_contact_link_event PRIMARY KEY (contact_link_event_pk),
    CONSTRAINT ux_contact_link_event_id UNIQUE (link_event_id)
);

CREATE TABLE IF NOT EXISTS nlp.sci_scoring_config (
    sci_scoring_config_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    scoring_config_id varchar(64) NOT NULL,
    region_code varchar(16) NOT NULL,
    scorer_version varchar(128) NOT NULL,
    semantic_weight numeric(6,5) NOT NULL DEFAULT 0.55,
    taxonomy_weight numeric(6,5) NOT NULL DEFAULT 0.30,
    recency_weight numeric(6,5) NOT NULL DEFAULT 0.15,
    geography_mismatch_multiplier numeric(6,5) NOT NULL DEFAULT 0.60,
    qualification_score_cap numeric(5,2) NOT NULL DEFAULT 9,
    entry_threshold numeric(5,2) NOT NULL DEFAULT 10,
    exit_threshold numeric(5,2) NOT NULL DEFAULT 7,
    exit_consecutive_count smallint NOT NULL DEFAULT 2,
    status varchar(16) NOT NULL DEFAULT 'DRAFT',
    effective_from timestamptz NULL,
    effective_to timestamptz NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_version bigint NOT NULL DEFAULT 1,
    created_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    updated_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    CONSTRAINT pk_sci_scoring_config PRIMARY KEY (sci_scoring_config_pk),
    CONSTRAINT ux_sci_scoring_config_id UNIQUE (scoring_config_id)
);

CREATE TABLE IF NOT EXISTS nlp.sci_calibration (
    sci_calibration_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    calibration_id varchar(64) NOT NULL,
    sci_scoring_config_pk bigint NOT NULL,
    calibration_method varchar(20) NOT NULL,
    f50 numeric(8,7) NULL,
    f99 numeric(8,7) NULL,
    model_payload_json jsonb NULL,
    sample_count int NOT NULL DEFAULT 0,
    status varchar(16) NOT NULL DEFAULT 'DRAFT',
    effective_from timestamptz NULL,
    effective_to timestamptz NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_version bigint NOT NULL DEFAULT 1,
    created_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    updated_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    CONSTRAINT pk_sci_calibration PRIMARY KEY (sci_calibration_pk),
    CONSTRAINT ux_sci_calibration_id UNIQUE (calibration_id)
);

CREATE TABLE IF NOT EXISTS nlp.sci_scoring_job (
    sci_scoring_job_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    job_id varchar(64) NOT NULL,
    owner_member_id varchar(64) NOT NULL,
    venture_pk bigint NOT NULL,
    trigger_member_id varchar(64) NULL,
    trigger_type varchar(32) NOT NULL,
    dedupe_key varchar(256) NOT NULL,
    status varchar(20) NOT NULL DEFAULT 'PENDING',
    after_link_pk bigint NOT NULL DEFAULT 0,
    processed_count int NOT NULL DEFAULT 0,
    attempt_count int NOT NULL DEFAULT 0,
    available_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    locked_until timestamptz NULL,
    error_code varchar(64) NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_version bigint NOT NULL DEFAULT 1,
    created_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    updated_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    CONSTRAINT pk_sci_scoring_job PRIMARY KEY (sci_scoring_job_pk),
    CONSTRAINT ux_sci_scoring_job_id UNIQUE (job_id),
    CONSTRAINT ux_sci_scoring_job_dedupe UNIQUE (dedupe_key)
);

CREATE TABLE IF NOT EXISTS nlp.sci_link_score (
    sci_link_score_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    score_id varchar(64) NOT NULL,
    contact_link_pk bigint NOT NULL,
    venture_pk bigint NOT NULL,
    owner_member_id varchar(64) NOT NULL,
    contact_venture_pk bigint NULL,
    owner_intent_set_pk bigint NOT NULL,
    contact_intent_set_pk bigint NULL,
    sci_scoring_config_pk bigint NOT NULL,
    raw_fit numeric(8,7) NOT NULL,
    calibrated_score numeric(5,2) NOT NULL,
    relationship_role varchar(32) NOT NULL,
    competitor_overlay boolean NOT NULL DEFAULT false,
    qualification_met boolean NOT NULL DEFAULT true,
    placement_state varchar(20) NOT NULL,
    below_exit_count smallint NOT NULL DEFAULT 0,
    is_stale boolean NOT NULL DEFAULT false,
    model_version varchar(128) NOT NULL,
    preprocessing_version varchar(128) NOT NULL,
    scorer_version varchar(128) NOT NULL,
    scored_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_version bigint NOT NULL DEFAULT 1,
    created_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    updated_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    CONSTRAINT pk_sci_link_score PRIMARY KEY (sci_link_score_pk),
    CONSTRAINT ux_sci_link_score_id UNIQUE (score_id),
    CONSTRAINT ux_sci_link_score_link_venture UNIQUE (contact_link_pk, venture_pk)
);

CREATE TABLE IF NOT EXISTS social.sci_rollup (
    sci_rollup_pk bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    rollup_id varchar(64) NOT NULL,
    owner_member_id varchar(64) NOT NULL,
    venture_pk bigint NOT NULL,
    industry_code varchar(64) NOT NULL,
    contact_count int NOT NULL DEFAULT 0,
    emerging_count int NOT NULL DEFAULT 0,
    relevant_count int NOT NULL DEFAULT 0,
    strong_count int NOT NULL DEFAULT 0,
    exact_count int NOT NULL DEFAULT 0,
    refreshed_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_version bigint NOT NULL DEFAULT 1,
    created_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    updated_by varchar(64) NOT NULL DEFAULT ops.current_audit_actor_id(),
    CONSTRAINT pk_sci_rollup PRIMARY KEY (sci_rollup_pk),
    CONSTRAINT ux_sci_rollup_id UNIQUE (rollup_id),
    CONSTRAINT ux_sci_rollup_scope UNIQUE (owner_member_id, venture_pk, industry_code)
);

-- Referential integrity, controlled values, and business invariants.
SELECT ops.add_constraint_if_missing('core', 'venture', 'fk_venture_owner_member',
    $constraint$FOREIGN KEY (owner_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'venture', 'fk_venture_organization',
    $constraint$FOREIGN KEY (organization_id) REFERENCES core.organization (organization_id)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'venture', 'fk_venture_industry',
    $constraint$FOREIGN KEY (industry_code) REFERENCES core.sector (sector_code)$constraint$);
SELECT ops.add_constraint_if_missing('core', 'venture', 'ck_venture_status',
    $constraint$CHECK (status IN ('ACTIVE','INACTIVE','ARCHIVED'))$constraint$);
SELECT ops.add_constraint_if_missing('core', 'venture', 'ck_venture_name',
    $constraint$CHECK (btrim(name) <> '')$constraint$);
CREATE UNIQUE INDEX IF NOT EXISTS ux_venture_owner_key ON core.venture (venture_pk, owner_member_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_venture_owner_active_name
    ON core.venture (owner_member_id, lower(name)) WHERE status = 'ACTIVE';

SELECT ops.add_constraint_if_missing('core', 'venture_geography', 'fk_venture_geography_venture',
    $constraint$FOREIGN KEY (venture_pk) REFERENCES core.venture (venture_pk) ON DELETE CASCADE$constraint$);
SELECT ops.add_constraint_if_missing('core', 'venture_qualification', 'fk_venture_qualification_venture',
    $constraint$FOREIGN KEY (venture_pk) REFERENCES core.venture (venture_pk) ON DELETE CASCADE$constraint$);
SELECT ops.add_constraint_if_missing('core', 'venture_qualification', 'ck_venture_qualification_operator',
    $constraint$CHECK (comparison_operator IN ('EQ','NE','GT','GTE','LT','LTE','IN','CONTAINS'))$constraint$);
SELECT ops.add_constraint_if_missing('core', 'venture_qualification', 'ck_venture_qualification_status',
    $constraint$CHECK (status IN ('ACTIVE','INACTIVE'))$constraint$);
CREATE UNIQUE INDEX IF NOT EXISTS ux_venture_qualification_active_code
    ON core.venture_qualification (venture_pk, qualification_code) WHERE status = 'ACTIVE';

SELECT ops.add_constraint_if_missing('nlp', 'venture_intent_set', 'fk_venture_intent_set_venture_owner',
    $constraint$FOREIGN KEY (venture_pk, owner_member_id) REFERENCES core.venture (venture_pk, owner_member_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'venture_intent_set', 'fk_venture_intent_set_supersedes',
    $constraint$FOREIGN KEY (supersedes_intent_set_pk) REFERENCES nlp.venture_intent_set (venture_intent_set_pk)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'venture_intent_set', 'ck_venture_intent_set_version',
    $constraint$CHECK (intent_version > 0)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'venture_intent_set', 'ck_venture_intent_set_status',
    $constraint$CHECK (status IN ('DRAFT','PROCESSING','ACTIVE','SUPERSEDED','FAILED','EXPIRED'))$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'venture_intent_set', 'ck_venture_intent_set_expiry',
    $constraint$CHECK (valid_until > created_at)$constraint$);
CREATE UNIQUE INDEX IF NOT EXISTS ux_venture_intent_set_version
    ON nlp.venture_intent_set (venture_pk, intent_version);
CREATE UNIQUE INDEX IF NOT EXISTS ux_venture_intent_set_active
    ON nlp.venture_intent_set (venture_pk) WHERE status = 'ACTIVE';
CREATE UNIQUE INDEX IF NOT EXISTS ux_venture_intent_set_owner_key
    ON nlp.venture_intent_set (venture_intent_set_pk, owner_member_id);
SELECT ops.add_constraint_if_missing('nlp', 'nlp_intent', 'fk_nlp_intent_venture_intent_set',
    $constraint$FOREIGN KEY (venture_intent_set_pk) REFERENCES nlp.venture_intent_set (venture_intent_set_pk)$constraint$);
CREATE UNIQUE INDEX IF NOT EXISTS ux_nlp_intent_venture_component
    ON nlp.nlp_intent (venture_intent_set_pk, intent_type) WHERE venture_intent_set_pk IS NOT NULL;

SELECT ops.add_constraint_if_missing('social', 'contact_record', 'fk_contact_record_owner',
    $constraint$FOREIGN KEY (owner_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'contact_record', 'ck_contact_record_source',
    $constraint$CHECK (source_type IN ('PHONE','GOOGLE','LINKEDIN','MANUAL'))$constraint$);
SELECT ops.add_constraint_if_missing('social', 'contact_record', 'ck_contact_record_status',
    $constraint$CHECK (status IN ('ACTIVE','EXPIRED','REMOVED'))$constraint$);
SELECT ops.add_constraint_if_missing('social', 'contact_record', 'ck_contact_record_expiry',
    $constraint$CHECK (expires_at > first_imported_at)$constraint$);
CREATE INDEX IF NOT EXISTS ix_contact_record_owner_status_expiry
    ON social.contact_record (owner_member_id, status, expires_at, contact_record_pk);

SELECT ops.add_constraint_if_missing('social', 'contact_identifier', 'fk_contact_identifier_record_owner',
    $constraint$FOREIGN KEY (contact_record_pk, owner_member_id) REFERENCES social.contact_record (contact_record_pk, owner_member_id) ON DELETE CASCADE$constraint$);
SELECT ops.add_constraint_if_missing('social', 'contact_identifier', 'ck_contact_identifier_type',
    $constraint$CHECK (identifier_type IN ('PHONE','EMAIL'))$constraint$);
CREATE UNIQUE INDEX IF NOT EXISTS ux_contact_identifier_owner_hash
    ON social.contact_identifier (owner_member_id, identifier_type, identifier_hash, hash_key_version);
CREATE INDEX IF NOT EXISTS ix_contact_identifier_lookup
    ON social.contact_identifier (identifier_type, identifier_hash, hash_key_version);

SELECT ops.add_constraint_if_missing('social', 'contact_link', 'fk_contact_link_owner',
    $constraint$FOREIGN KEY (owner_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'contact_link', 'fk_contact_link_record_owner',
    $constraint$FOREIGN KEY (contact_record_pk, owner_member_id) REFERENCES social.contact_record (contact_record_pk, owner_member_id) ON DELETE CASCADE$constraint$);
SELECT ops.add_constraint_if_missing('social', 'contact_link', 'fk_contact_link_contact_member',
    $constraint$FOREIGN KEY (contact_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'contact_link', 'fk_contact_link_connection',
    $constraint$FOREIGN KEY (connection_id) REFERENCES social.connection (connection_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'contact_link', 'ck_contact_link_origin',
    $constraint$CHECK (origin_type IN ('IMPORT','DISCOVERY','ENCOUNTER'))$constraint$);
SELECT ops.add_constraint_if_missing('social', 'contact_link', 'ck_contact_link_state',
    $constraint$CHECK (lifecycle_state IN ('IMPORTED','INVITED','JOINED','CONNECTED','REMOVED'))$constraint$);
SELECT ops.add_constraint_if_missing('social', 'contact_link', 'ck_contact_link_join_state',
    $constraint$CHECK (lifecycle_state NOT IN ('JOINED','CONNECTED') OR contact_member_id IS NOT NULL)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'contact_link', 'ck_contact_link_connected_state',
    $constraint$CHECK (lifecycle_state <> 'CONNECTED' OR (contact_member_id IS NOT NULL AND connection_id IS NOT NULL AND consent_at IS NOT NULL))$constraint$);
SELECT ops.add_constraint_if_missing('social', 'contact_link', 'ck_contact_link_distinct_members',
    $constraint$CHECK (contact_member_id IS NULL OR contact_member_id <> owner_member_id)$constraint$);
CREATE UNIQUE INDEX IF NOT EXISTS ux_contact_link_owner_member
    ON social.contact_link (owner_member_id, contact_member_id) WHERE contact_member_id IS NOT NULL AND lifecycle_state <> 'REMOVED';
CREATE INDEX IF NOT EXISTS ix_contact_link_contact_member
    ON social.contact_link (contact_member_id, contact_link_pk) WHERE contact_member_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_contact_link_owner_state
    ON social.contact_link (owner_member_id, lifecycle_state, contact_link_pk);

SELECT ops.add_constraint_if_missing('social', 'invite_batch', 'fk_invite_batch_owner',
    $constraint$FOREIGN KEY (owner_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'invite_batch', 'fk_invite_batch_venture_owner',
    $constraint$FOREIGN KEY (venture_pk, owner_member_id) REFERENCES core.venture (venture_pk, owner_member_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'invite_batch', 'ck_invite_batch_status',
    $constraint$CHECK (status IN ('DRAFT','APPROVED','CANCELLED','EXPIRED'))$constraint$);
SELECT ops.add_constraint_if_missing('social', 'invite_batch', 'ck_invite_batch_approval',
    $constraint$CHECK ((status = 'APPROVED' AND approved_at IS NOT NULL) OR status <> 'APPROVED')$constraint$);
SELECT ops.add_constraint_if_missing('social', 'invite_batch', 'ck_invite_batch_expiry',
    $constraint$CHECK (expires_at > created_at)$constraint$);

SELECT ops.add_constraint_if_missing('social', 'invitation', 'fk_invitation_batch_owner',
    $constraint$FOREIGN KEY (invite_batch_pk, owner_member_id) REFERENCES social.invite_batch (invite_batch_pk, owner_member_id) ON DELETE CASCADE$constraint$);
SELECT ops.add_constraint_if_missing('social', 'invitation', 'fk_invitation_link_owner',
    $constraint$FOREIGN KEY (contact_link_pk, owner_member_id) REFERENCES social.contact_link (contact_link_pk, owner_member_id) ON DELETE CASCADE$constraint$);
SELECT ops.add_constraint_if_missing('social', 'invitation', 'ck_invitation_batch_position',
    $constraint$CHECK (batch_position BETWEEN 1 AND 20)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'invitation', 'ck_invitation_status',
    $constraint$CHECK (status IN ('APPROVED','OPENED','ACCEPTED','EXPIRED','REVOKED'))$constraint$);
SELECT ops.add_constraint_if_missing('social', 'invitation', 'ck_invitation_acceptance',
    $constraint$CHECK ((status = 'ACCEPTED' AND accepted_at IS NOT NULL) OR status <> 'ACCEPTED')$constraint$);
SELECT ops.add_constraint_if_missing('social', 'invitation', 'ck_invitation_expiry',
    $constraint$CHECK (expires_at > created_at)$constraint$);
CREATE INDEX IF NOT EXISTS ix_invitation_link_status
    ON social.invitation (contact_link_pk, status, expires_at);

SELECT ops.add_constraint_if_missing('social', 'meeting_confirmation', 'fk_meeting_confirmation_request',
    $constraint$FOREIGN KEY (connection_request_id) REFERENCES social.connection_request (connection_request_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'meeting_confirmation', 'fk_meeting_confirmation_member',
    $constraint$FOREIGN KEY (confirmer_member_id) REFERENCES iam.member (member_id)$constraint$);

SELECT ops.add_constraint_if_missing('social', 'contact_link_event', 'fk_contact_link_event_link',
    $constraint$FOREIGN KEY (contact_link_pk) REFERENCES social.contact_link (contact_link_pk) ON DELETE CASCADE$constraint$);
SELECT ops.add_constraint_if_missing('social', 'contact_link_event', 'fk_contact_link_event_venture',
    $constraint$FOREIGN KEY (venture_pk) REFERENCES core.venture (venture_pk)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'contact_link_event', 'ck_contact_link_event_scores',
    $constraint$CHECK ((from_score IS NULL OR from_score BETWEEN 0 AND 100) AND (to_score IS NULL OR to_score BETWEEN 0 AND 100))$constraint$);
CREATE INDEX IF NOT EXISTS ix_contact_link_event_history
    ON social.contact_link_event (contact_link_pk, occurred_at DESC, contact_link_event_pk DESC);

SELECT ops.add_constraint_if_missing('nlp', 'sci_scoring_config', 'ck_sci_scoring_config_weights',
    $constraint$CHECK (semantic_weight BETWEEN 0 AND 1 AND taxonomy_weight BETWEEN 0 AND 1 AND recency_weight BETWEEN 0 AND 1 AND semantic_weight + taxonomy_weight + recency_weight = 1)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_scoring_config', 'ck_sci_scoring_config_thresholds',
    $constraint$CHECK (geography_mismatch_multiplier BETWEEN 0 AND 1 AND qualification_score_cap BETWEEN 0 AND 100 AND exit_threshold >= 0 AND entry_threshold <= 100 AND exit_threshold < entry_threshold AND exit_consecutive_count > 0)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_scoring_config', 'ck_sci_scoring_config_status',
    $constraint$CHECK (status IN ('DRAFT','ACTIVE','RETIRED','ROLLED_BACK') AND (effective_to IS NULL OR effective_from IS NOT NULL AND effective_to > effective_from))$constraint$);
CREATE UNIQUE INDEX IF NOT EXISTS ux_sci_scoring_config_active_region
    ON nlp.sci_scoring_config (region_code) WHERE status = 'ACTIVE';

SELECT ops.add_constraint_if_missing('nlp', 'sci_calibration', 'fk_sci_calibration_config',
    $constraint$FOREIGN KEY (sci_scoring_config_pk) REFERENCES nlp.sci_scoring_config (sci_scoring_config_pk)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_calibration', 'ck_sci_calibration_method',
    $constraint$CHECK (calibration_method IN ('LINEAR','ISOTONIC'))$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_calibration', 'ck_sci_calibration_values',
    $constraint$CHECK (sample_count >= 0 AND (calibration_method <> 'LINEAR' OR status = 'DRAFT' OR (f50 IS NOT NULL AND f99 IS NOT NULL AND f99 > f50)))$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_calibration', 'ck_sci_calibration_status',
    $constraint$CHECK (status IN ('DRAFT','ACTIVE','RETIRED') AND (effective_to IS NULL OR effective_from IS NOT NULL AND effective_to > effective_from))$constraint$);
CREATE UNIQUE INDEX IF NOT EXISTS ux_sci_calibration_active_config
    ON nlp.sci_calibration (sci_scoring_config_pk) WHERE status = 'ACTIVE';

SELECT ops.add_constraint_if_missing('nlp', 'sci_scoring_job', 'fk_sci_scoring_job_owner',
    $constraint$FOREIGN KEY (owner_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_scoring_job', 'fk_sci_scoring_job_venture_owner',
    $constraint$FOREIGN KEY (venture_pk, owner_member_id) REFERENCES core.venture (venture_pk, owner_member_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_scoring_job', 'fk_sci_scoring_job_trigger_member',
    $constraint$FOREIGN KEY (trigger_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_scoring_job', 'ck_sci_scoring_job_status',
    $constraint$CHECK (status IN ('PENDING','RUNNING','SUCCEEDED','FAILED','DEAD'))$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_scoring_job', 'ck_sci_scoring_job_counters',
    $constraint$CHECK (after_link_pk >= 0 AND processed_count >= 0 AND attempt_count >= 0)$constraint$);
CREATE INDEX IF NOT EXISTS ix_sci_scoring_job_due
    ON nlp.sci_scoring_job (status, available_at, sci_scoring_job_pk);

SELECT ops.add_constraint_if_missing('nlp', 'sci_link_score', 'fk_sci_link_score_link_owner',
    $constraint$FOREIGN KEY (contact_link_pk, owner_member_id) REFERENCES social.contact_link (contact_link_pk, owner_member_id) ON DELETE CASCADE$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_link_score', 'fk_sci_link_score_venture_owner',
    $constraint$FOREIGN KEY (venture_pk, owner_member_id) REFERENCES core.venture (venture_pk, owner_member_id)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_link_score', 'fk_sci_link_score_contact_venture',
    $constraint$FOREIGN KEY (contact_venture_pk) REFERENCES core.venture (venture_pk)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_link_score', 'fk_sci_link_score_owner_intent',
    $constraint$FOREIGN KEY (owner_intent_set_pk) REFERENCES nlp.venture_intent_set (venture_intent_set_pk)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_link_score', 'fk_sci_link_score_contact_intent',
    $constraint$FOREIGN KEY (contact_intent_set_pk) REFERENCES nlp.venture_intent_set (venture_intent_set_pk)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_link_score', 'fk_sci_link_score_config',
    $constraint$FOREIGN KEY (sci_scoring_config_pk) REFERENCES nlp.sci_scoring_config (sci_scoring_config_pk)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_link_score', 'ck_sci_link_score_values',
    $constraint$CHECK (raw_fit BETWEEN 0 AND 1 AND calibrated_score BETWEEN 0 AND 100 AND below_exit_count >= 0)$constraint$);
SELECT ops.add_constraint_if_missing('nlp', 'sci_link_score', 'ck_sci_link_score_placement',
    $constraint$CHECK (placement_state IN ('BELOW_GATE','IN_SCI'))$constraint$);
CREATE INDEX IF NOT EXISTS ix_sci_link_score_ranked
    ON nlp.sci_link_score (owner_member_id, venture_pk, placement_state, calibrated_score DESC, contact_link_pk);
CREATE INDEX IF NOT EXISTS ix_sci_link_score_contact_intent
    ON nlp.sci_link_score (contact_intent_set_pk) WHERE contact_intent_set_pk IS NOT NULL;

SELECT ops.add_constraint_if_missing('social', 'sci_rollup', 'fk_sci_rollup_owner',
    $constraint$FOREIGN KEY (owner_member_id) REFERENCES iam.member (member_id)$constraint$);
SELECT ops.add_constraint_if_missing('social', 'sci_rollup', 'fk_sci_rollup_venture_owner',
    $constraint$FOREIGN KEY (venture_pk, owner_member_id) REFERENCES core.venture (venture_pk, owner_member_id) ON DELETE CASCADE$constraint$);
SELECT ops.add_constraint_if_missing('social', 'sci_rollup', 'ck_sci_rollup_counts',
    $constraint$CHECK (contact_count >= 0 AND emerging_count >= 0 AND relevant_count >= 0 AND strong_count >= 0 AND exact_count >= 0 AND emerging_count + relevant_count + strong_count + exact_count <= contact_count)$constraint$);

-- Append-only confirmation evidence can only be recorded by one of the two
-- members on an accepted connection request.
CREATE OR REPLACE FUNCTION social.enforce_meeting_confirmation()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    request_row social.connection_request%ROWTYPE;
BEGIN
    IF TG_OP = 'UPDATE' AND (
        NEW.confirmation_id IS DISTINCT FROM OLD.confirmation_id
        OR NEW.connection_request_id IS DISTINCT FROM OLD.connection_request_id
        OR NEW.confirmer_member_id IS DISTINCT FROM OLD.confirmer_member_id
        OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
        OR NEW.confirmed_at IS DISTINCT FROM OLD.confirmed_at
        OR OLD.revoked_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Meeting confirmation evidence is immutable except for one revocation.' USING ERRCODE = '23514';
    END IF;

    SELECT * INTO request_row
    FROM social.connection_request
    WHERE connection_request_id = NEW.connection_request_id;

    IF NOT FOUND OR request_row.status <> 'ACCEPTED' THEN
        RAISE EXCEPTION 'Meeting confirmation requires an accepted connection request.' USING ERRCODE = '23514';
    END IF;
    IF NEW.confirmer_member_id NOT IN (request_row.sender_member_id, request_row.recipient_member_id) THEN
        RAISE EXCEPTION 'Meeting confirmer must be a member of the accepted request.' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS enforce_meeting_confirmation ON social.meeting_confirmation;
CREATE TRIGGER enforce_meeting_confirmation
BEFORE INSERT OR UPDATE ON social.meeting_confirmation
FOR EACH ROW EXECUTE FUNCTION social.enforce_meeting_confirmation();

-- ENCOUNTER origin is permanent SCI eligibility and therefore requires two-sided
-- meeting evidence linked through the accepted connection.
CREATE OR REPLACE FUNCTION social.enforce_encounter_origin()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    confirmation_count int;
BEGIN
    IF NEW.origin_type <> 'ENCOUNTER' THEN
        RETURN NEW;
    END IF;
    IF NEW.connection_id IS NULL OR NEW.lifecycle_state <> 'CONNECTED' THEN
        RAISE EXCEPTION 'Encounter links require an active connected relationship.' USING ERRCODE = '23514';
    END IF;

    SELECT count(DISTINCT mc.confirmer_member_id)
      INTO confirmation_count
    FROM social.connection c
    JOIN social.meeting_confirmation mc
      ON mc.connection_request_id = c.accepted_request_id
     AND mc.revoked_at IS NULL
    WHERE c.connection_id = NEW.connection_id
      AND c.status = 'ACTIVE';

    IF confirmation_count <> 2 THEN
        RAISE EXCEPTION 'Encounter links require two active meeting confirmations.' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS enforce_encounter_origin ON social.contact_link;
CREATE TRIGGER enforce_encounter_origin
BEFORE INSERT OR UPDATE OF origin_type, connection_id, lifecycle_state ON social.contact_link
FOR EACH ROW EXECUTE FUNCTION social.enforce_encounter_origin();

-- Core enqueues an SCI job in the same database transaction as the venture,
-- contact, consent, or intent change. The NLP worker leases it using the same
-- polling pattern as nlp_processing_job; no additional request queue is needed.
CREATE OR REPLACE FUNCTION nlp.enqueue_sci_scoring_job(
    p_job_id varchar(64),
    p_owner_member_id varchar(64),
    p_venture_id varchar(64),
    p_trigger_member_id varchar(64),
    p_trigger_type varchar(32),
    p_dedupe_key varchar(256),
    p_available_at timestamptz DEFAULT CURRENT_TIMESTAMP
)
RETURNS varchar(64)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, core, iam, nlp
AS $function$
DECLARE
    v_venture_pk bigint;
    v_job_id varchar(64);
BEGIN
    IF p_job_id IS NULL OR btrim(p_job_id) = ''
       OR p_dedupe_key IS NULL OR btrim(p_dedupe_key) = ''
       OR p_trigger_type IS NULL OR btrim(p_trigger_type) = '' THEN
        RAISE EXCEPTION 'SCI job ID, dedupe key, and trigger type are required.' USING ERRCODE = '22023';
    END IF;

    SELECT venture_pk INTO v_venture_pk
    FROM core.venture
    WHERE venture_id = p_venture_id
      AND owner_member_id = p_owner_member_id
      AND status = 'ACTIVE';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active SCI venture was not found for the owner.' USING ERRCODE = '23503';
    END IF;
    IF p_trigger_member_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM iam.member WHERE member_id = p_trigger_member_id) THEN
        RAISE EXCEPTION 'SCI trigger member does not exist.' USING ERRCODE = '23503';
    END IF;

    INSERT INTO nlp.sci_scoring_job (
        job_id, owner_member_id, venture_pk, trigger_member_id,
        trigger_type, dedupe_key, available_at
    ) VALUES (
        p_job_id, p_owner_member_id, v_venture_pk, p_trigger_member_id,
        p_trigger_type, p_dedupe_key, p_available_at
    )
    ON CONFLICT (dedupe_key) DO NOTHING
    RETURNING job_id INTO v_job_id;

    IF v_job_id IS NULL THEN
        SELECT job_id INTO v_job_id
        FROM nlp.sci_scoring_job
        WHERE dedupe_key = p_dedupe_key;
    END IF;
    RETURN v_job_id;
END;
$function$;

-- Eligibility is materialized and capped before exact cosine distance is applied.
-- The lateral selection chooses the contact venture with the strongest directional
-- semantic fit for this scoring pass; the application adds taxonomy, geography,
-- recency, and qualification features using the returned structured intent.
CREATE OR REPLACE FUNCTION nlp.get_sci_scoring_candidates(
    p_owner_member_id varchar(64),
    p_venture_id varchar(64),
    p_after_link_pk bigint DEFAULT 0,
    p_max_rows int DEFAULT 200
)
RETURNS TABLE (
    contact_link_pk bigint,
    link_id varchar(64),
    contact_member_id varchar(64),
    owner_venture_pk bigint,
    owner_intent_set_pk bigint,
    contact_venture_pk bigint,
    contact_venture_id varchar(64),
    contact_intent_set_pk bigint,
    contact_offer_intent_id varchar(64),
    contact_offer_embedding vector(1536),
    contact_want_intent_id varchar(64),
    contact_want_embedding vector(1536),
    client_cosine_distance double precision,
    supplier_cosine_distance double precision,
    contact_structured_intent jsonb,
    contact_valid_until timestamptz,
    model_version varchar(128),
    preprocessing_version varchar(128)
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, core, iam, social, nlp
AS $function$
BEGIN
    IF p_max_rows NOT BETWEEN 50 AND 200 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'max_rows must be between 50 and 200.';
    END IF;
    IF p_after_link_pk < 0 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'after_link_pk cannot be negative.';
    END IF;

    RETURN QUERY
    WITH owner_scope AS MATERIALIZED (
        SELECT v.venture_pk, vis.venture_intent_set_pk,
               offer_embedding.embedding AS offer_embedding,
               want_embedding.embedding AS want_embedding,
               offer_embedding.model_version,
               offer_intent.preprocessing_version
        FROM core.venture v
        JOIN nlp.venture_intent_set vis
          ON vis.venture_pk = v.venture_pk
         AND vis.owner_member_id = v.owner_member_id
         AND vis.status = 'ACTIVE'
         AND vis.valid_until > CURRENT_TIMESTAMP
        JOIN nlp.nlp_intent offer_intent
          ON offer_intent.venture_intent_set_pk = vis.venture_intent_set_pk
         AND offer_intent.intent_type = 'OFFER'
         AND offer_intent.status = 'MATCH_READY'
         AND offer_intent.expires_at > CURRENT_TIMESTAMP
        JOIN nlp.nlp_embedding offer_embedding
          ON offer_embedding.intent_id = offer_intent.intent_id
         AND offer_embedding.status = 'ACTIVE'
         AND offer_embedding.normalized_hash = offer_intent.normalized_hash
        JOIN nlp.nlp_intent want_intent
          ON want_intent.venture_intent_set_pk = vis.venture_intent_set_pk
         AND want_intent.intent_type = 'WANT'
         AND want_intent.status = 'MATCH_READY'
         AND want_intent.expires_at > CURRENT_TIMESTAMP
         AND want_intent.preprocessing_version = offer_intent.preprocessing_version
        JOIN nlp.nlp_embedding want_embedding
          ON want_embedding.intent_id = want_intent.intent_id
         AND want_embedding.status = 'ACTIVE'
         AND want_embedding.normalized_hash = want_intent.normalized_hash
         AND want_embedding.model_version = offer_embedding.model_version
        JOIN nlp.nlp_model_version mv
          ON mv.model_version = offer_embedding.model_version
         AND mv.status = 'ACTIVE'
         AND mv.dimensions = 1536
         AND mv.preprocessing_version = offer_intent.preprocessing_version
        WHERE v.venture_id = p_venture_id
          AND v.owner_member_id = p_owner_member_id
          AND v.status = 'ACTIVE'
        LIMIT 1
    ), eligible_links AS MATERIALIZED (
        SELECT l.contact_link_pk, l.link_id, l.contact_member_id
        FROM social.contact_link l
        CROSS JOIN owner_scope
        JOIN iam.member m ON m.member_id = l.contact_member_id AND m.status = 'ACTIVE'
        JOIN social.connection c ON c.connection_id = l.connection_id AND c.status = 'ACTIVE'
        WHERE l.owner_member_id = p_owner_member_id
          AND l.lifecycle_state = 'CONNECTED'
          AND l.consent_at IS NOT NULL
          AND l.contact_link_pk > p_after_link_pk
          AND NOT EXISTS (
              SELECT 1
              FROM social.member_block b
              WHERE b.removed_at IS NULL
                AND ((b.blocker_member_id = p_owner_member_id AND b.blocked_member_id = l.contact_member_id)
                  OR (b.blocker_member_id = l.contact_member_id AND b.blocked_member_id = p_owner_member_id))
          )
        ORDER BY l.contact_link_pk
        LIMIT p_max_rows
    )
    SELECT links.contact_link_pk, links.link_id, links.contact_member_id,
           owner_scope.venture_pk, owner_scope.venture_intent_set_pk,
           best.contact_venture_pk, best.contact_venture_id, best.contact_intent_set_pk,
           best.offer_intent_id, best.offer_embedding,
           best.want_intent_id, best.want_embedding,
           best.client_distance, best.supplier_distance,
           best.structured_intent_json, best.valid_until,
           owner_scope.model_version, owner_scope.preprocessing_version
    FROM eligible_links links
    CROSS JOIN owner_scope
    JOIN LATERAL (
        SELECT contact_venture.venture_pk AS contact_venture_pk,
               contact_venture.venture_id AS contact_venture_id,
               contact_set.venture_intent_set_pk AS contact_intent_set_pk,
               offer_intent.intent_id AS offer_intent_id,
               offer_embedding.embedding AS offer_embedding,
               want_intent.intent_id AS want_intent_id,
               want_embedding.embedding AS want_embedding,
               (owner_scope.offer_embedding <=> want_embedding.embedding)::double precision AS client_distance,
               (owner_scope.want_embedding <=> offer_embedding.embedding)::double precision AS supplier_distance,
               contact_set.structured_intent_json,
               contact_set.valid_until
        FROM core.venture contact_venture
        JOIN nlp.venture_intent_set contact_set
          ON contact_set.venture_pk = contact_venture.venture_pk
         AND contact_set.owner_member_id = links.contact_member_id
         AND contact_set.status = 'ACTIVE'
         AND contact_set.valid_until > CURRENT_TIMESTAMP
        JOIN nlp.nlp_intent offer_intent
          ON offer_intent.venture_intent_set_pk = contact_set.venture_intent_set_pk
         AND offer_intent.intent_type = 'OFFER'
         AND offer_intent.status = 'MATCH_READY'
         AND offer_intent.expires_at > CURRENT_TIMESTAMP
         AND offer_intent.preprocessing_version = owner_scope.preprocessing_version
        JOIN nlp.nlp_embedding offer_embedding
          ON offer_embedding.intent_id = offer_intent.intent_id
         AND offer_embedding.status = 'ACTIVE'
         AND offer_embedding.normalized_hash = offer_intent.normalized_hash
         AND offer_embedding.model_version = owner_scope.model_version
        JOIN nlp.nlp_intent want_intent
          ON want_intent.venture_intent_set_pk = contact_set.venture_intent_set_pk
         AND want_intent.intent_type = 'WANT'
         AND want_intent.status = 'MATCH_READY'
         AND want_intent.expires_at > CURRENT_TIMESTAMP
         AND want_intent.preprocessing_version = owner_scope.preprocessing_version
        JOIN nlp.nlp_embedding want_embedding
          ON want_embedding.intent_id = want_intent.intent_id
         AND want_embedding.status = 'ACTIVE'
         AND want_embedding.normalized_hash = want_intent.normalized_hash
         AND want_embedding.model_version = owner_scope.model_version
        WHERE contact_venture.owner_member_id = links.contact_member_id
          AND contact_venture.status = 'ACTIVE'
        ORDER BY LEAST(owner_scope.offer_embedding <=> want_embedding.embedding,
                       owner_scope.want_embedding <=> offer_embedding.embedding),
                 contact_set.updated_at DESC,
                 contact_set.venture_intent_set_pk
        LIMIT 1
    ) best ON true
    ORDER BY links.contact_link_pk;
END;
$function$;

-- One controlled mutation owns qualification capping, entry/exit hysteresis,
-- encounter permanence, immutable history, and the completion outbox event.
CREATE OR REPLACE FUNCTION nlp.apply_sci_link_score(
    p_score_id varchar(64),
    p_contact_link_pk bigint,
    p_venture_pk bigint,
    p_contact_venture_pk bigint,
    p_owner_intent_set_pk bigint,
    p_contact_intent_set_pk bigint,
    p_scoring_config_id varchar(64),
    p_raw_fit numeric,
    p_calibrated_score numeric,
    p_relationship_role varchar(32),
    p_competitor_overlay boolean,
    p_qualification_met boolean,
    p_model_version varchar(128),
    p_preprocessing_version varchar(128),
    p_scorer_version varchar(128),
    p_scored_at timestamptz,
    p_outbox_event_id varchar(64)
)
RETURNS TABLE (placement_state varchar(20), below_exit_count smallint, state_changed boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, core, iam, social, nlp, ops
AS $function$
DECLARE
    link_row social.contact_link%ROWTYPE;
    config_row nlp.sci_scoring_config%ROWTYPE;
    existing_row nlp.sci_link_score%ROWTYPE;
    v_score numeric(5,2);
    v_state varchar(20);
    v_below_count smallint := 0;
    v_changed boolean;
    v_event_type varchar(32);
BEGIN
    IF p_score_id IS NULL OR btrim(p_score_id) = '' OR p_outbox_event_id IS NULL OR btrim(p_outbox_event_id) = '' THEN
        RAISE EXCEPTION 'Score and outbox event IDs are required.' USING ERRCODE = '22023';
    END IF;
    IF p_raw_fit NOT BETWEEN 0 AND 1 OR p_calibrated_score NOT BETWEEN 0 AND 100 THEN
        RAISE EXCEPTION 'SCI score values are outside their supported range.' USING ERRCODE = '22023';
    END IF;

    -- A retried worker delivery must not advance the two-strike exit counter twice.
    IF EXISTS (SELECT 1 FROM ops.outbox_event WHERE outbox_event_id = p_outbox_event_id) THEN
        SELECT * INTO existing_row
        FROM nlp.sci_link_score
        WHERE contact_link_pk = p_contact_link_pk AND venture_pk = p_venture_pk;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'SCI score replay has an outbox event but no persisted score.' USING ERRCODE = '23514';
        END IF;
        RETURN QUERY SELECT existing_row.placement_state, existing_row.below_exit_count, false;
        RETURN;
    END IF;

    SELECT * INTO link_row
    FROM social.contact_link
    WHERE contact_link_pk = p_contact_link_pk
    FOR UPDATE;
    IF NOT FOUND OR link_row.lifecycle_state <> 'CONNECTED' OR link_row.consent_at IS NULL THEN
        RAISE EXCEPTION 'SCI scoring requires a consented connected contact link.' USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.venture v
        WHERE v.venture_pk = p_venture_pk
          AND v.owner_member_id = link_row.owner_member_id
          AND v.status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'SCI venture does not belong to the link owner or is inactive.' USING ERRCODE = '23514';
    END IF;

    SELECT * INTO config_row
    FROM nlp.sci_scoring_config
    WHERE scoring_config_id = p_scoring_config_id
      AND status = 'ACTIVE'
      AND effective_from <= p_scored_at
      AND (effective_to IS NULL OR effective_to > p_scored_at);
    IF NOT FOUND OR config_row.scorer_version <> p_scorer_version THEN
        RAISE EXCEPTION 'Active SCI scoring configuration was not found for scorer version %.', p_scorer_version USING ERRCODE = '23514';
    END IF;

    SELECT * INTO existing_row
    FROM nlp.sci_link_score
    WHERE contact_link_pk = p_contact_link_pk AND venture_pk = p_venture_pk
    FOR UPDATE;

    v_score := round((CASE WHEN p_qualification_met THEN p_calibrated_score ELSE LEAST(p_calibrated_score, config_row.qualification_score_cap) END)::numeric, 2);

    IF link_row.origin_type = 'ENCOUNTER' OR v_score >= config_row.entry_threshold THEN
        v_state := 'IN_SCI';
        v_below_count := 0;
    ELSIF existing_row.sci_link_score_pk IS NOT NULL AND existing_row.placement_state = 'IN_SCI' THEN
        IF v_score < config_row.exit_threshold THEN
            v_below_count := existing_row.below_exit_count + 1;
            v_state := CASE WHEN v_below_count >= config_row.exit_consecutive_count THEN 'BELOW_GATE' ELSE 'IN_SCI' END;
        ELSE
            v_state := 'IN_SCI';
            v_below_count := 0;
        END IF;
    ELSE
        v_state := 'BELOW_GATE';
        v_below_count := 0;
    END IF;

    v_changed := existing_row.sci_link_score_pk IS NULL
        OR existing_row.placement_state IS DISTINCT FROM v_state
        OR existing_row.calibrated_score IS DISTINCT FROM v_score
        OR existing_row.relationship_role IS DISTINCT FROM p_relationship_role
        OR existing_row.competitor_overlay IS DISTINCT FROM p_competitor_overlay
        OR existing_row.is_stale;

    INSERT INTO nlp.sci_link_score (
        score_id, contact_link_pk, venture_pk, owner_member_id, contact_venture_pk,
        owner_intent_set_pk, contact_intent_set_pk, sci_scoring_config_pk,
        raw_fit, calibrated_score, relationship_role, competitor_overlay,
        qualification_met, placement_state, below_exit_count, is_stale,
        model_version, preprocessing_version, scorer_version, scored_at
    ) VALUES (
        p_score_id, p_contact_link_pk, p_venture_pk, link_row.owner_member_id, p_contact_venture_pk,
        p_owner_intent_set_pk, p_contact_intent_set_pk, config_row.sci_scoring_config_pk,
        p_raw_fit, v_score, p_relationship_role, p_competitor_overlay,
        p_qualification_met, v_state, v_below_count, false,
        p_model_version, p_preprocessing_version, p_scorer_version, p_scored_at
    )
    ON CONFLICT (contact_link_pk, venture_pk) DO UPDATE SET
        contact_venture_pk = EXCLUDED.contact_venture_pk,
        owner_intent_set_pk = EXCLUDED.owner_intent_set_pk,
        contact_intent_set_pk = EXCLUDED.contact_intent_set_pk,
        sci_scoring_config_pk = EXCLUDED.sci_scoring_config_pk,
        raw_fit = EXCLUDED.raw_fit,
        calibrated_score = EXCLUDED.calibrated_score,
        relationship_role = EXCLUDED.relationship_role,
        competitor_overlay = EXCLUDED.competitor_overlay,
        qualification_met = EXCLUDED.qualification_met,
        placement_state = EXCLUDED.placement_state,
        below_exit_count = EXCLUDED.below_exit_count,
        is_stale = false,
        model_version = EXCLUDED.model_version,
        preprocessing_version = EXCLUDED.preprocessing_version,
        scorer_version = EXCLUDED.scorer_version,
        scored_at = EXCLUDED.scored_at,
        updated_at = CURRENT_TIMESTAMP;

    IF v_changed THEN
        v_event_type := CASE
            WHEN existing_row.sci_link_score_pk IS NULL AND v_state = 'IN_SCI' THEN 'ENTERED_SCI'
            WHEN existing_row.placement_state = 'BELOW_GATE' AND v_state = 'IN_SCI' THEN 'ENTERED_SCI'
            WHEN existing_row.placement_state = 'IN_SCI' AND v_state = 'BELOW_GATE' THEN 'LEFT_SCI'
            WHEN existing_row.relationship_role IS DISTINCT FROM p_relationship_role THEN 'ROLE_CHANGED'
            ELSE 'SCORE_CHANGED'
        END;

        INSERT INTO social.contact_link_event (
            link_event_id, contact_link_pk, venture_pk, event_type,
            from_state, to_state, from_score, to_score, from_role, to_role,
            details_json, occurred_at
        ) VALUES (
            p_outbox_event_id, p_contact_link_pk, p_venture_pk, v_event_type,
            existing_row.placement_state, v_state, existing_row.calibrated_score, v_score,
            existing_row.relationship_role, p_relationship_role,
            jsonb_build_object('competitor_overlay', p_competitor_overlay, 'scorer_version', p_scorer_version),
            p_scored_at
        ) ON CONFLICT (link_event_id) DO NOTHING;

        INSERT INTO ops.outbox_event (
            outbox_event_id, aggregate_type, aggregate_id, event_type, payload_json, occurred_at
        ) VALUES (
            p_outbox_event_id, 'SCI_LINK', link_row.link_id, 'SciLinkScoreChanged.v1',
            jsonb_build_object(
                'link_id', link_row.link_id,
                'venture_pk', p_venture_pk,
                'owner_member_id', link_row.owner_member_id,
                'placement_state', v_state,
                'score', v_score,
                'relationship_role', p_relationship_role,
                'event_type', v_event_type,
                'scorer_version', p_scorer_version
            ),
            p_scored_at
        ) ON CONFLICT (outbox_event_id) DO NOTHING;
    END IF;

    RETURN QUERY SELECT v_state, v_below_count, v_changed;
END;
$function$;

-- Intent expiry freezes the last score and placement. It never consumes an exit
-- strike and never demotes a link solely because the intent became stale.
CREATE OR REPLACE FUNCTION nlp.mark_sci_scores_stale(
    p_intent_set_pk bigint,
    p_scope varchar(16),
    p_outbox_event_id varchar(64),
    p_occurred_at timestamptz DEFAULT CURRENT_TIMESTAMP
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, nlp, ops
AS $function$
DECLARE
    v_count int;
BEGIN
    IF p_scope NOT IN ('OWNER','CONTACT') THEN
        RAISE EXCEPTION 'SCI stale scope must be OWNER or CONTACT.' USING ERRCODE = '22023';
    END IF;
    IF p_outbox_event_id IS NULL OR btrim(p_outbox_event_id) = '' THEN
        RAISE EXCEPTION 'SCI stale outbox event ID is required.' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM ops.outbox_event WHERE outbox_event_id = p_outbox_event_id) THEN
        RETURN 0;
    END IF;

    UPDATE nlp.sci_link_score
       SET is_stale = true,
           updated_at = CURRENT_TIMESTAMP
     WHERE NOT is_stale
       AND ((p_scope = 'OWNER' AND owner_intent_set_pk = p_intent_set_pk)
         OR (p_scope = 'CONTACT' AND contact_intent_set_pk = p_intent_set_pk));
    GET DIAGNOSTICS v_count = ROW_COUNT;

    INSERT INTO ops.outbox_event (
        outbox_event_id, aggregate_type, aggregate_id, event_type, payload_json, occurred_at
    ) VALUES (
        p_outbox_event_id, 'SCI_INTENT_SET', p_intent_set_pk::text, 'SciScoresMarkedStale.v1',
        jsonb_build_object('intent_set_pk', p_intent_set_pk, 'scope', p_scope, 'affected_count', v_count),
        p_occurred_at
    );
    RETURN v_count;
END;
$function$;

-- Owner-scoped read model. APIs must always predicate owner_member_id and use
-- opaque cursor pagination over (calibrated_score, contact_link_pk).
CREATE OR REPLACE VIEW social.vw_sci_contact
AS
SELECT l.owner_member_id,
       v.venture_id,
       l.contact_link_pk,
       l.link_id,
       l.contact_member_id,
       r.contact_record_id,
       r.label_ciphertext,
       s.calibrated_score,
       s.relationship_role,
       s.competitor_overlay,
       s.is_stale,
       l.origin_type,
       l.hidden_at,
       l.pinned_at,
       s.scored_at,
       s.row_version AS score_row_version
FROM nlp.sci_link_score s
JOIN social.contact_link l ON l.contact_link_pk = s.contact_link_pk
JOIN social.contact_record r ON r.contact_record_pk = l.contact_record_pk
JOIN core.venture v ON v.venture_pk = s.venture_pk
WHERE s.placement_state = 'IN_SCI'
  AND l.lifecycle_state = 'CONNECTED'
  AND l.consent_at IS NOT NULL;

-- All mutable SCI resources use the shared audit and row-version triggers even
-- when this module is applied after the original full setup.
DO $audit_triggers$
DECLARE
    target regclass;
BEGIN
    FOREACH target IN ARRAY ARRAY[
        'core.venture'::regclass,
        'core.venture_qualification'::regclass,
        'nlp.venture_intent_set'::regclass,
        'social.contact_record'::regclass,
        'social.contact_link'::regclass,
        'social.invite_batch'::regclass,
        'social.invitation'::regclass,
        'nlp.sci_scoring_config'::regclass,
        'nlp.sci_calibration'::regclass,
        'nlp.sci_scoring_job'::regclass,
        'nlp.sci_link_score'::regclass,
        'social.sci_rollup'::regclass
    ]
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS set_audit_actor ON %s', target);
        EXECUTE format('CREATE TRIGGER set_audit_actor BEFORE INSERT OR UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION ops.set_audit_actor()', target);
        EXECUTE format('DROP TRIGGER IF EXISTS set_row_version ON %s', target);
        EXECUTE format('CREATE TRIGGER set_row_version BEFORE UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION ops.set_row_version()', target);
    END LOOP;
END;
$audit_triggers$;

-- Business defaults are deployment-managed and remain DRAFT until a reviewed
-- calibration row is available. Activating a config is an explicit release step.
INSERT INTO nlp.sci_scoring_config (
    scoring_config_id, region_code, scorer_version,
    semantic_weight, taxonomy_weight, recency_weight,
    geography_mismatch_multiplier, qualification_score_cap,
    entry_threshold, exit_threshold, exit_consecutive_count, status
) VALUES (
    'SCI_GLOBAL_V1', 'GLOBAL', 'sci-v1',
    0.55, 0.30, 0.15,
    0.60, 9,
    10, 7, 2, 'DRAFT'
) ON CONFLICT (scoring_config_id) DO NOTHING;

REVOKE EXECUTE ON FUNCTION nlp.get_sci_scoring_candidates(varchar, varchar, bigint, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION nlp.enqueue_sci_scoring_job(varchar, varchar, varchar, varchar, varchar, varchar, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION nlp.apply_sci_link_score(varchar, bigint, bigint, bigint, bigint, bigint, varchar, numeric, numeric, varchar, boolean, boolean, varchar, varchar, varchar, timestamptz, varchar) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION nlp.mark_sci_scores_stale(bigint, varchar, varchar, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION social.enforce_meeting_confirmation() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION social.enforce_encounter_origin() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION nlp.get_sci_scoring_candidates(varchar, varchar, bigint, int) TO olga_dml_writer, olga_nlp_worker;
GRANT EXECUTE ON FUNCTION nlp.enqueue_sci_scoring_job(varchar, varchar, varchar, varchar, varchar, varchar, timestamptz) TO olga_dml_writer;
GRANT EXECUTE ON FUNCTION nlp.apply_sci_link_score(varchar, bigint, bigint, bigint, bigint, bigint, varchar, numeric, numeric, varchar, boolean, boolean, varchar, varchar, varchar, timestamptz, varchar) TO olga_dml_writer, olga_nlp_worker;
GRANT EXECUTE ON FUNCTION nlp.mark_sci_scores_stale(bigint, varchar, varchar, timestamptz) TO olga_dml_writer, olga_nlp_worker;

-- The NLP worker receives only controlled candidate access and its SCI job/score
-- state. It cannot read imported identifiers, labels, invitations, or connections.
REVOKE ALL PRIVILEGES ON
    social.contact_record, social.contact_identifier, social.contact_link,
    social.invite_batch, social.invitation, social.meeting_confirmation,
    social.contact_link_event, social.sci_rollup
FROM olga_nlp_worker;
GRANT SELECT ON
    nlp.venture_intent_set, nlp.sci_scoring_config, nlp.sci_calibration,
    nlp.sci_scoring_job, nlp.sci_link_score
TO olga_nlp_worker;
GRANT SELECT (venture_pk, venture_id) ON core.venture TO olga_nlp_worker;
GRANT UPDATE (status, after_link_pk, processed_count, attempt_count, available_at, locked_until, error_code, updated_at)
    ON nlp.sci_scoring_job TO olga_nlp_worker;

GRANT SELECT ON social.vw_sci_contact TO olga_dml_writer, olga_reader;
REVOKE UPDATE, DELETE ON social.contact_link_event FROM olga_dml_writer;
GRANT SELECT, INSERT ON social.contact_link_event TO olga_dml_writer;

DO $sci_verify$
DECLARE
    target regclass;
BEGIN
    FOREACH target IN ARRAY ARRAY[
        'core.venture'::regclass,
        'core.venture_qualification'::regclass,
        'nlp.venture_intent_set'::regclass,
        'social.contact_record'::regclass,
        'social.contact_link'::regclass,
        'social.invite_batch'::regclass,
        'social.invitation'::regclass,
        'nlp.sci_scoring_config'::regclass,
        'nlp.sci_calibration'::regclass,
        'nlp.sci_scoring_job'::regclass,
        'nlp.sci_link_score'::regclass,
        'social.sci_rollup'::regclass
    ]
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_trigger
            WHERE tgrelid = target AND tgname = 'set_row_version' AND tgenabled <> 'D'
        ) THEN
            RAISE EXCEPTION 'SCI row-version trigger is missing for %.', target;
        END IF;
    END LOOP;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'social.invitation'::regclass
          AND conname = 'ck_invitation_batch_position'
          AND contype = 'c'
          AND convalidated
    ) THEN
        RAISE EXCEPTION 'The database-enforced invitation batch cap is missing.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM nlp.sci_scoring_config
        WHERE scoring_config_id = 'SCI_GLOBAL_V1'
    ) THEN
        RAISE EXCEPTION 'The review-gated SCI scoring configuration seed is missing.';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'nlp.get_sci_scoring_candidates(varchar,varchar,bigint,integer)'::regprocedure)
       OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'nlp.enqueue_sci_scoring_job(varchar,varchar,varchar,varchar,varchar,varchar,timestamp with time zone)'::regprocedure)
       OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'nlp.apply_sci_link_score(varchar,bigint,bigint,bigint,bigint,bigint,varchar,numeric,numeric,varchar,boolean,boolean,varchar,varchar,varchar,timestamp with time zone,varchar)'::regprocedure)
       OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'nlp.mark_sci_scores_stale(bigint,varchar,varchar,timestamp with time zone)'::regprocedure) THEN
        RAISE EXCEPTION 'SCI controlled functions must remain SECURITY DEFINER.';
    END IF;
    IF NOT has_function_privilege('olga_nlp_worker', 'nlp.get_sci_scoring_candidates(varchar,varchar,bigint,integer)', 'EXECUTE')
       OR NOT has_function_privilege('olga_nlp_worker', 'nlp.apply_sci_link_score(varchar,bigint,bigint,bigint,bigint,bigint,varchar,numeric,numeric,varchar,boolean,boolean,varchar,varchar,varchar,timestamp with time zone,varchar)', 'EXECUTE')
       OR NOT has_function_privilege('olga_nlp_worker', 'nlp.mark_sci_scores_stale(bigint,varchar,varchar,timestamp with time zone)', 'EXECUTE')
       OR has_function_privilege('olga_nlp_worker', 'nlp.enqueue_sci_scoring_job(varchar,varchar,varchar,varchar,varchar,varchar,timestamp with time zone)', 'EXECUTE')
       OR has_table_privilege('olga_nlp_worker', 'social.contact_identifier', 'SELECT')
       OR has_table_privilege('olga_nlp_worker', 'social.contact_record', 'SELECT') THEN
        RAISE EXCEPTION 'SCI NLP-worker privileges are missing or exceed the approved boundary.';
    END IF;
END;
$sci_verify$;

DROP FUNCTION ops.add_constraint_if_missing(name, name, name, text);
COMMENT ON SCHEMA ops IS 'OLGA.SchemaVersion=2.9';
RESET ROLE;
COMMIT;
