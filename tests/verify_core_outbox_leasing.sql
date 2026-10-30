-- Run after migration 004 with a migration-owner test connection. The script is
-- self-contained and rolls back its fixture rows. Any unexpected result aborts.
BEGIN;

DO $schema_checks$
DECLARE
    claim_index_definition text;
BEGIN
    IF EXISTS (
        SELECT 1
        FROM ops.outbox_event
        WHERE attempt_count < 0
           OR ((lease_id IS NULL) <> (leased_until IS NULL))
           OR (published_at IS NOT NULL AND lease_id IS NOT NULL)
           OR (exhausted_at IS NOT NULL AND published_at IS NOT NULL)
    ) THEN
        RAISE EXCEPTION 'An existing outbox row is invalid after migration.';
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

    SELECT indexdef INTO claim_index_definition
    FROM pg_indexes
    WHERE schemaname = 'ops' AND indexname = 'ix_outbox_event_core_claim';

    IF claim_index_definition IS NULL
       OR claim_index_definition NOT LIKE '%(next_attempt_at, leased_until, occurred_at, outbox_event_id)%'
       OR claim_index_definition NOT LIKE '%WHERE ((published_at IS NULL) AND (exhausted_at IS NULL))%' THEN
        RAISE EXCEPTION 'Core claim query does not have the required partial eligibility index.';
    END IF;

    IF to_regclass('chat.conversation') IS NULL
       OR to_regclass('chat.conversation_participant') IS NULL
       OR to_regclass('chat.message') IS NULL
       OR to_regclass('chat.message_receipt') IS NULL
       OR NOT EXISTS (
           SELECT 1
           FROM pg_proc procedure
           JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
           WHERE namespace.nspname = 'chat'
             AND procedure.proname = 'save_message'
             AND procedure.pronargs = 10
       ) THEN
        RAISE EXCEPTION 'An existing chat object is missing.';
    END IF;
END;
$schema_checks$;

INSERT INTO ops.outbox_event (
    outbox_event_id, aggregate_type, aggregate_id, event_type, payload_json, occurred_at
) VALUES (
    'test-core-outbox-leasing', 'MESSAGE', 'test-core-outbox-leasing',
    'TestEvent.v1', '{"message_id":"test-core-outbox-leasing"}'::jsonb,
    CURRENT_TIMESTAMP - interval '1 minute'
);

DO $constraint_checks$
BEGIN
    BEGIN
        UPDATE ops.outbox_event SET attempt_count = -1
        WHERE outbox_event_id = 'test-core-outbox-leasing';
        RAISE EXCEPTION 'Expected negative attempt_count rejection.';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE ops.outbox_event SET lease_id = 'invalid-unpaired-lease'
        WHERE outbox_event_id = 'test-core-outbox-leasing';
        RAISE EXCEPTION 'Expected unpaired lease rejection.';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE ops.outbox_event SET last_error_summary = E'unsafe\nstack trace'
        WHERE outbox_event_id = 'test-core-outbox-leasing';
        RAISE EXCEPTION 'Expected unsafe error summary rejection.';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE ops.outbox_event
        SET lease_id = 'invalid-published-lease',
            leased_until = CURRENT_TIMESTAMP + interval '1 minute',
            published_at = CURRENT_TIMESTAMP
        WHERE outbox_event_id = 'test-core-outbox-leasing';
        RAISE EXCEPTION 'Expected published-and-leased state rejection.';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE ops.outbox_event
        SET exhausted_at = CURRENT_TIMESTAMP,
            published_at = CURRENT_TIMESTAMP
        WHERE outbox_event_id = 'test-core-outbox-leasing';
        RAISE EXCEPTION 'Expected published-and-exhausted state rejection.';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END;
$constraint_checks$;

-- Worker one claims and commits this state before publishing. A production claim
-- uses the same CTE with parameters for :now, :lease_id, :leased_until and :batch_size.
WITH candidates AS (
    SELECT outbox_event_id
    FROM ops.outbox_event
    WHERE published_at IS NULL
      AND exhausted_at IS NULL
      AND (next_attempt_at IS NULL OR next_attempt_at <= CURRENT_TIMESTAMP)
      AND (leased_until IS NULL OR leased_until <= CURRENT_TIMESTAMP)
    ORDER BY occurred_at, outbox_event_id
    FOR UPDATE SKIP LOCKED
    LIMIT 50
)
UPDATE ops.outbox_event AS event
SET lease_id = 'test-worker-one-lease',
    leased_until = CURRENT_TIMESTAMP + interval '5 minutes',
    last_attempt_at = CURRENT_TIMESTAMP,
    attempt_count = event.attempt_count + 1
FROM candidates
WHERE event.outbox_event_id = candidates.outbox_event_id;

DO $active_lease_checks$
DECLARE
    second_worker_candidates integer;
    version_before bigint;
    version_after bigint;
BEGIN
    SELECT count(*) INTO second_worker_candidates
    FROM ops.outbox_event
    WHERE outbox_event_id = 'test-core-outbox-leasing'
      AND published_at IS NULL
      AND exhausted_at IS NULL
      AND (next_attempt_at IS NULL OR next_attempt_at <= CURRENT_TIMESTAMP)
      AND (leased_until IS NULL OR leased_until <= CURRENT_TIMESTAMP);

    IF second_worker_candidates <> 0 THEN
        RAISE EXCEPTION 'A second worker could claim an actively leased event.';
    END IF;

    SELECT row_version INTO version_before FROM ops.outbox_event
    WHERE outbox_event_id = 'test-core-outbox-leasing';
    UPDATE ops.outbox_event SET last_attempt_at = CURRENT_TIMESTAMP
    WHERE outbox_event_id = 'test-core-outbox-leasing';
    SELECT row_version INTO version_after FROM ops.outbox_event
    WHERE outbox_event_id = 'test-core-outbox-leasing';

    IF version_after <> version_before + 1 THEN
        RAISE EXCEPTION 'row_version did not increment on update.';
    END IF;
END;
$active_lease_checks$;

-- Simulate lease expiry, then reclaim with a new token.
UPDATE ops.outbox_event
SET leased_until = CURRENT_TIMESTAMP - interval '1 second'
WHERE outbox_event_id = 'test-core-outbox-leasing';

WITH candidates AS (
    SELECT outbox_event_id
    FROM ops.outbox_event
    WHERE published_at IS NULL
      AND exhausted_at IS NULL
      AND (next_attempt_at IS NULL OR next_attempt_at <= CURRENT_TIMESTAMP)
      AND (leased_until IS NULL OR leased_until <= CURRENT_TIMESTAMP)
    ORDER BY occurred_at, outbox_event_id
    FOR UPDATE SKIP LOCKED
    LIMIT 50
)
UPDATE ops.outbox_event AS event
SET lease_id = 'test-worker-two-lease',
    leased_until = CURRENT_TIMESTAMP + interval '5 minutes',
    last_attempt_at = CURRENT_TIMESTAMP,
    attempt_count = event.attempt_count + 1
FROM candidates
WHERE event.outbox_event_id = candidates.outbox_event_id;

DO $stale_worker_checks$
DECLARE
    affected integer;
BEGIN
    UPDATE ops.outbox_event
    SET published_at = CURRENT_TIMESTAMP, lease_id = NULL, leased_until = NULL
    WHERE outbox_event_id = 'test-core-outbox-leasing'
      AND lease_id = 'test-worker-one-lease';
    GET DIAGNOSTICS affected = ROW_COUNT;
    IF affected <> 0 THEN
        RAISE EXCEPTION 'A stale lease completed a reclaimed event.';
    END IF;

    UPDATE ops.outbox_event
    SET next_attempt_at = CURRENT_TIMESTAMP + interval '1 minute',
        last_error_code = 'STALE', last_error_summary = 'Stale worker',
        lease_id = NULL, leased_until = NULL
    WHERE outbox_event_id = 'test-core-outbox-leasing'
      AND lease_id = 'test-worker-one-lease';
    GET DIAGNOSTICS affected = ROW_COUNT;
    IF affected <> 0 THEN
        RAISE EXCEPTION 'A stale lease failed a reclaimed event.';
    END IF;
END;
$stale_worker_checks$;

-- Current worker schedules a retry and releases the event.
UPDATE ops.outbox_event
SET next_attempt_at = CURRENT_TIMESTAMP + interval '5 minutes',
    last_error_code = 'SERVICE_BUSY',
    last_error_summary = 'Broker temporarily unavailable',
    lease_id = NULL,
    leased_until = NULL
WHERE outbox_event_id = 'test-core-outbox-leasing'
  AND lease_id = 'test-worker-two-lease';

DO $retry_check$
BEGIN
    IF EXISTS (
        SELECT 1 FROM ops.outbox_event
        WHERE outbox_event_id = 'test-core-outbox-leasing'
          AND published_at IS NULL
          AND exhausted_at IS NULL
          AND (next_attempt_at IS NULL OR next_attempt_at <= CURRENT_TIMESTAMP)
          AND (leased_until IS NULL OR leased_until <= CURRENT_TIMESTAMP)
    ) THEN
        RAISE EXCEPTION 'A retry was eligible before next_attempt_at.';
    END IF;
END;
$retry_check$;

-- Make the retry due, claim it, and complete it with the current lease token.
UPDATE ops.outbox_event
SET next_attempt_at = CURRENT_TIMESTAMP - interval '1 second'
WHERE outbox_event_id = 'test-core-outbox-leasing';

UPDATE ops.outbox_event
SET lease_id = 'test-worker-three-lease',
    leased_until = CURRENT_TIMESTAMP + interval '5 minutes',
    last_attempt_at = CURRENT_TIMESTAMP,
    attempt_count = attempt_count + 1
WHERE outbox_event_id = 'test-core-outbox-leasing'
  AND published_at IS NULL
  AND exhausted_at IS NULL
  AND (next_attempt_at IS NULL OR next_attempt_at <= CURRENT_TIMESTAMP)
  AND (leased_until IS NULL OR leased_until <= CURRENT_TIMESTAMP);

UPDATE ops.outbox_event
SET published_at = CURRENT_TIMESTAMP,
    lease_id = NULL,
    leased_until = NULL,
    next_attempt_at = NULL,
    last_error_code = NULL,
    last_error_summary = NULL
WHERE outbox_event_id = 'test-core-outbox-leasing'
  AND lease_id = 'test-worker-three-lease';

DO $completion_checks$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM ops.outbox_event
        WHERE outbox_event_id = 'test-core-outbox-leasing'
          AND published_at IS NOT NULL
          AND lease_id IS NULL
          AND leased_until IS NULL
          AND octet_length(outbox_event_id) <= 64
    ) THEN
        RAISE EXCEPTION 'Successful completion or Service Bus MessageId compatibility failed.';
    END IF;
END;
$completion_checks$;

INSERT INTO ops.outbox_event (
    outbox_event_id, aggregate_type, aggregate_id, event_type, payload_json,
    attempt_count, lease_id, leased_until, last_attempt_at
) VALUES (
    'test-core-outbox-exhausted', 'MESSAGE', 'test-core-outbox-exhausted',
    'TestEvent.v1', '{"message_id":"test-core-outbox-exhausted"}'::jsonb,
    10, 'test-worker-exhaustion-lease', CURRENT_TIMESTAMP + interval '5 minutes',
    CURRENT_TIMESTAMP
);

UPDATE ops.outbox_event
SET exhausted_at = CURRENT_TIMESTAMP,
    next_attempt_at = NULL,
    last_error_code = 'MAX_ATTEMPTS',
    last_error_summary = 'Maximum publish attempts reached',
    lease_id = NULL,
    leased_until = NULL
WHERE outbox_event_id = 'test-core-outbox-exhausted'
  AND lease_id = 'test-worker-exhaustion-lease';

DO $exhaustion_checks$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM ops.outbox_event
        WHERE outbox_event_id = 'test-core-outbox-exhausted'
          AND exhausted_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Exhausted event was not retained.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM ops.outbox_event
        WHERE outbox_event_id = 'test-core-outbox-exhausted'
          AND published_at IS NULL
          AND exhausted_at IS NULL
          AND (next_attempt_at IS NULL OR next_attempt_at <= CURRENT_TIMESTAMP)
          AND (leased_until IS NULL OR leased_until <= CURRENT_TIMESTAMP)
    ) THEN
        RAISE EXCEPTION 'Exhausted event remained claimable.';
    END IF;
END;
$exhaustion_checks$;

ROLLBACK;
