-- Run after the baseline with a migration-owner test connection. This test is self-contained
-- and rolls back all fixture rows. Any unexpected result aborts with an exception.
BEGIN;
SET CONSTRAINTS ALL DEFERRED;
SELECT ops.set_audit_context('test-chat-atomicity');

INSERT INTO core.community(community_id, name)
VALUES ('test-community-atomicity', 'Test Community Atomicity');
INSERT INTO iam.member(member_id, community_id, status)
VALUES
    ('test-member-sender', 'test-community-atomicity', 'ACTIVE'),
    ('test-member-recipient', 'test-community-atomicity', 'ACTIVE'),
    ('test-member-outsider', 'test-community-atomicity', 'ACTIVE');
INSERT INTO social.connection_request(
    connection_request_id, sender_member_id, recipient_member_id, status, expires_at
) VALUES (
    'test-request-atomicity', 'test-member-sender', 'test-member-recipient',
    'PENDING', CURRENT_TIMESTAMP + interval '1 hour'
);

SELECT * FROM social.accept_connection_request(
    'test-request-atomicity', 'test-member-recipient', 'test-connection-atomicity',
    'test-conversation-atomicity', 'test-accept-key', repeat('a', 64)::char(64),
    CURRENT_TIMESTAMP + interval '1 day', CURRENT_TIMESTAMP + interval '30 days'
);
-- Exact replay must not duplicate any ledger records.
SELECT * FROM social.accept_connection_request(
    'test-request-atomicity', 'test-member-recipient', 'test-connection-atomicity',
    'test-conversation-atomicity', 'test-accept-key', repeat('a', 64)::char(64),
    CURRENT_TIMESTAMP + interval '1 day', CURRENT_TIMESTAMP + interval '30 days'
);

DO $$
BEGIN
    IF (SELECT count(*) FROM chat.conversation_participant WHERE conversation_id = 'test-conversation-atomicity') <> 2 THEN
        RAISE EXCEPTION 'Connection acceptance did not create exactly two participants.';
    END IF;
    IF (SELECT count(*) FROM ops.outbox_event WHERE aggregate_id = 'test-connection-atomicity' AND event_type = 'connection.accepted') <> 1 THEN
        RAISE EXCEPTION 'Connection acceptance outbox event was not exactly-once.';
    END IF;
    IF (SELECT count(*) FROM ops.sync_change WHERE resource_id IN ('test-request-atomicity','test-conversation-atomicity')) <> 4 THEN
        RAISE EXCEPTION 'Connection acceptance did not create four member-scoped sync changes.';
    END IF;
    IF (SELECT count(*) FROM ops.idempotency_record WHERE scope = 'social.accept_connection_request' AND actor_id = 'test-member-recipient' AND idempotency_key = 'test-accept-key' AND status_code = 200) <> 1 THEN
        RAISE EXCEPTION 'Connection acceptance idempotency result is missing.';
    END IF;

    BEGIN
        INSERT INTO chat.conversation_participant(conversation_id, member_id)
        VALUES ('test-conversation-atomicity', 'test-member-outsider');
        RAISE EXCEPTION 'Expected outsider participant rejection.';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
END;
$$;

SELECT * FROM chat.save_message(
    'test-message-atomicity', 'test-conversation-atomicity', 'test-member-sender',
    'TEXT', 'transactional test', NULL::timestamptz,
    'test-message-key', repeat('b', 64)::char(64),
    CURRENT_TIMESTAMP + interval '1 day', CURRENT_TIMESTAMP + interval '30 days'
);
SELECT * FROM chat.save_message(
    'test-message-atomicity', 'test-conversation-atomicity', 'test-member-sender',
    'TEXT', 'transactional test', NULL::timestamptz,
    'test-message-key', repeat('b', 64)::char(64),
    CURRENT_TIMESTAMP + interval '1 day', CURRENT_TIMESTAMP + interval '30 days'
);

SELECT * FROM chat.save_message_receipt(
    'test-message-atomicity', 'test-member-recipient', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP,
    'test-receipt-key', repeat('c', 64)::char(64),
    CURRENT_TIMESTAMP + interval '1 day', CURRENT_TIMESTAMP + interval '30 days'
);
SELECT * FROM chat.save_message_receipt(
    'test-message-atomicity', 'test-member-recipient', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP,
    'test-receipt-key', repeat('c', 64)::char(64),
    CURRENT_TIMESTAMP + interval '1 day', CURRENT_TIMESTAMP + interval '30 days'
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM ops.outbox_event outbox
        JOIN chat.message msg
          ON msg.message_id = outbox.aggregate_id
        WHERE outbox.aggregate_id = 'test-message-atomicity'
          AND outbox.event_type = 'MessageCreated.v1'
          AND outbox.payload_json = jsonb_build_object(
              'message_id', 'test-message-atomicity',
              'conversation_id', 'test-conversation-atomicity',
              'sender_member_id', 'test-member-sender',
              'recipient_member_id', 'test-member-recipient',
              'server_sequence', msg.server_sequence
          )
    ) THEN
        RAISE EXCEPTION 'Canonical message-created outbox event is missing or has an invalid payload.';
    END IF;
    IF (SELECT count(*) FROM ops.outbox_event WHERE aggregate_id = 'test-message-atomicity') <> 1 THEN
        RAISE EXCEPTION 'Message creation and receipt replay produced an unexpected outbox event count.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM chat.message_receipt
        WHERE message_id = 'test-message-atomicity'
          AND member_id = 'test-member-recipient'
          AND delivered_at IS NOT NULL
          AND read_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Receipt state was not persisted.';
    END IF;
    IF (SELECT count(*) FROM ops.sync_change WHERE resource_id = 'test-message-atomicity') <> 4 THEN
        RAISE EXCEPTION 'Message and receipt did not each create two member-scoped sync changes.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM chat.conversation_participant
        WHERE conversation_id = 'test-conversation-atomicity'
          AND member_id = 'test-member-recipient'
          AND last_read_message_id = 'test-message-atomicity'
    ) THEN
        RAISE EXCEPTION 'Receipt did not advance the recipient read cursor.';
    END IF;

    BEGIN
        INSERT INTO chat.message_receipt(message_id, member_id, delivered_at)
        VALUES ('test-message-atomicity', 'test-member-sender', CURRENT_TIMESTAMP);
        RAISE EXCEPTION 'Expected sender receipt rejection.';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    BEGIN
        UPDATE chat.message_receipt
        SET delivered_at = delivered_at + interval '1 second'
        WHERE message_id = 'test-message-atomicity' AND member_id = 'test-member-recipient';
        RAISE EXCEPTION 'Expected immutable delivery timestamp rejection.';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
END;
$$;

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
