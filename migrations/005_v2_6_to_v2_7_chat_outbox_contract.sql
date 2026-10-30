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
