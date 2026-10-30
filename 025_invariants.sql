-- Polymorphic file links remain referentially safe even though one FK cannot target four tables.
CREATE OR REPLACE FUNCTION storage.enforce_file_asset_link_resource()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF (NEW.resource_type = 'MESSAGE' AND NOT EXISTS (SELECT 1 FROM chat.message WHERE message_id = NEW.resource_id))
       OR (NEW.resource_type = 'MEMBER_VERIFICATION' AND NOT EXISTS (SELECT 1 FROM core.member_verification WHERE verification_id = NEW.resource_id))
       OR (NEW.resource_type = 'PRIVACY_REQUEST' AND NOT EXISTS (SELECT 1 FROM consent.privacy_request WHERE privacy_request_id = NEW.resource_id))
       OR (NEW.resource_type = 'EVALUATION_RUN' AND NOT EXISTS (SELECT 1 FROM nlp.evaluation_run WHERE evaluation_run_id = NEW.resource_id)) THEN
        RAISE EXCEPTION USING ERRCODE = '23503', MESSAGE = 'FileAssetLink resource does not exist in its owning domain.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_file_asset_link_resource ON storage.file_asset_link;
CREATE TRIGGER enforce_file_asset_link_resource
BEFORE INSERT OR UPDATE ON storage.file_asset_link
FOR EACH ROW EXECUTE FUNCTION storage.enforce_file_asset_link_resource();

-- Active Live Mode sessions must be event-bounded and backed by the same member's
-- latest effective, unwithdrawn LIVE_MODE grant. This prevents an unrelated consent
-- row from satisfying the foreign key and makes session creation fail closed.
CREATE OR REPLACE FUNCTION event.enforce_live_mode_session_consent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, event, iam, consent
AS $$
DECLARE
    v_event_ends_at timestamptz;
BEGIN
    IF NEW.status <> 'ACTIVE' THEN
        RETURN NEW;
    END IF;

    SELECT e.ends_at
    INTO v_event_ends_at
    FROM event.event e
    JOIN iam.member m
      ON m.member_id = NEW.member_id
     AND m.community_id = e.community_id
     AND m.status = 'ACTIVE'
    WHERE e.event_id = NEW.event_id
      AND e.status = 'ACTIVE'
      AND e.live_mode_enabled
      AND CURRENT_TIMESTAMP >= e.starts_at
      AND CURRENT_TIMESTAMP < e.ends_at;

    IF v_event_ends_at IS NULL OR NEW.active_until > v_event_ends_at
       OR NEW.active_until <= CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Active Live Mode session requires an active same-community event and an event-bounded future expiry.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM consent.member_consent mc
        JOIN consent.consent_policy cp ON cp.policy_id = mc.policy_id
        WHERE mc.member_consent_id = NEW.consent_record_id
          AND mc.member_id = NEW.member_id
          AND mc.decision = 'GRANTED'
          AND mc.withdrawn_at IS NULL
          AND cp.purpose_code = 'LIVE_MODE'
          AND cp.effective_from <= CURRENT_TIMESTAMP
          AND cp.retired_at IS NULL
          AND NOT EXISTS (
              SELECT 1
              FROM consent.member_consent newer
              JOIN consent.consent_policy newer_policy ON newer_policy.policy_id = newer.policy_id
              WHERE newer.member_id = mc.member_id
                AND newer_policy.purpose_code = 'LIVE_MODE'
                AND newer_policy.effective_from <= CURRENT_TIMESTAMP
                AND newer_policy.retired_at IS NULL
                AND (newer.captured_at, newer.member_consent_id) > (mc.captured_at, mc.member_consent_id)
          )
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Active Live Mode session requires the member''s latest effective LIVE_MODE grant.';
    END IF;

    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_live_mode_session_consent ON event.live_mode_session;
CREATE TRIGGER enforce_live_mode_session_consent
BEFORE INSERT OR UPDATE ON event.live_mode_session
FOR EACH ROW EXECUTE FUNCTION event.enforce_live_mode_session_consent();

-- When suppression dimensions are combined, they must describe the same intent.
CREATE OR REPLACE FUNCTION nlp.enforce_match_suppression_target()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.intent_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM nlp.nlp_intent i
        WHERE i.intent_id = NEW.intent_id
          AND (NEW.member_id IS NULL OR i.member_id = NEW.member_id)
          AND (NEW.context_id IS NULL OR i.context_id = NEW.context_id)
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Match suppression member, intent and context targets are inconsistent.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_match_suppression_target ON nlp.match_suppression;
CREATE TRIGGER enforce_match_suppression_target
BEFORE INSERT OR UPDATE ON nlp.match_suppression
FOR EACH ROW EXECUTE FUNCTION nlp.enforce_match_suppression_target();

-- A connection must represent exactly the two members from its accepted request.
CREATE OR REPLACE FUNCTION social.enforce_connection_request_pair()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_sender_member_id varchar(64);
    v_recipient_member_id varchar(64);
BEGIN
    SELECT sender_member_id, recipient_member_id
    INTO v_sender_member_id, v_recipient_member_id
    FROM social.connection_request
    WHERE connection_request_id = NEW.accepted_request_id
      AND status = 'ACCEPTED';

    IF v_sender_member_id IS NULL
       OR NEW.member_low_id <> LEAST(v_sender_member_id, v_recipient_member_id)
       OR NEW.member_high_id <> GREATEST(v_sender_member_id, v_recipient_member_id) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Connection members must exactly match the accepted connection request.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_connection_request_pair ON social.connection;
CREATE TRIGGER enforce_connection_request_pair
BEFORE INSERT OR UPDATE OF member_low_id, member_high_id, accepted_request_id ON social.connection
FOR EACH ROW EXECUTE FUNCTION social.enforce_connection_request_pair();

CREATE OR REPLACE FUNCTION social.validate_accepted_request_connection()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_connection_request_id varchar(64);
    v_new_connection_request_id varchar(64);
    v_connection_request_id varchar(64);
    v_old_row jsonb;
    v_new_row jsonb;
BEGIN
    IF TG_TABLE_SCHEMA <> 'social'
       OR TG_TABLE_NAME NOT IN ('connection_request', 'connection') THEN
        RAISE EXCEPTION 'Unexpected relation for accepted-request validation: %.%.',
            TG_TABLE_SCHEMA, TG_TABLE_NAME USING ERRCODE = '55000';
    END IF;

    -- Convert the relation-specific trigger records before extracting fields. Direct references
    -- to fields from both relations in one CASE expression are resolved by PostgreSQL even when
    -- that branch is not selected, causing undefined-column errors.
    IF TG_OP <> 'INSERT' THEN
        v_old_row := to_jsonb(OLD);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new_row := to_jsonb(NEW);
    END IF;

    IF TG_TABLE_NAME = 'connection_request' THEN
        v_old_connection_request_id := v_old_row ->> 'connection_request_id';
        v_new_connection_request_id := v_new_row ->> 'connection_request_id';
    ELSE
        v_old_connection_request_id := v_old_row ->> 'accepted_request_id';
        v_new_connection_request_id := v_new_row ->> 'accepted_request_id';
    END IF;

    FOR v_connection_request_id IN
        SELECT DISTINCT affected_id
        FROM unnest(ARRAY[
            v_old_connection_request_id, v_new_connection_request_id
        ]) AS affected(affected_id)
        WHERE affected_id IS NOT NULL
    LOOP
        IF EXISTS (
            SELECT 1 FROM social.connection_request cr
            WHERE cr.connection_request_id = v_connection_request_id AND cr.status = 'ACCEPTED'
        ) AND NOT EXISTS (
            SELECT 1 FROM social.connection c
            WHERE c.accepted_request_id = v_connection_request_id
        ) THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = 'An accepted connection request must have its canonical connection in the same transaction.';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS validate_accepted_request_connection_on_request ON social.connection_request;
CREATE CONSTRAINT TRIGGER validate_accepted_request_connection_on_request
AFTER INSERT OR UPDATE OR DELETE ON social.connection_request
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION social.validate_accepted_request_connection();
DROP TRIGGER IF EXISTS validate_accepted_request_connection_on_connection ON social.connection;
CREATE CONSTRAINT TRIGGER validate_accepted_request_connection_on_connection
AFTER INSERT OR UPDATE OR DELETE ON social.connection
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION social.validate_accepted_request_connection();

-- Participant rows may contain only the two members of the underlying connection.
-- Read cursors must point into the same conversation and may never move backwards.
CREATE OR REPLACE FUNCTION chat.enforce_conversation_participant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, chat, social
AS $$
DECLARE
    v_member_low_id varchar(64);
    v_member_high_id varchar(64);
    v_new_sequence bigint;
    v_old_sequence bigint;
BEGIN
    IF TG_OP = 'UPDATE' AND (
        NEW.conversation_id IS DISTINCT FROM OLD.conversation_id
        OR NEW.member_id IS DISTINCT FROM OLD.member_id
        OR NEW.joined_at IS DISTINCT FROM OLD.joined_at
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Conversation participant identity and join time are immutable.';
    END IF;

    SELECT cn.member_low_id, cn.member_high_id
    INTO v_member_low_id, v_member_high_id
    FROM chat.conversation c
    JOIN social.connection cn ON cn.connection_id = c.connection_id
    WHERE c.conversation_id = NEW.conversation_id;

    IF v_member_low_id IS NULL OR NEW.member_id NOT IN (v_member_low_id, v_member_high_id) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Conversation participant must be a member of the underlying connection.';
    END IF;

    IF NEW.last_read_message_id IS NOT NULL THEN
        SELECT server_sequence INTO v_new_sequence
        FROM chat.message
        WHERE message_id = NEW.last_read_message_id
          AND conversation_id = NEW.conversation_id;
        IF v_new_sequence IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = '23514',
                MESSAGE = 'Last-read message must belong to the participant conversation.';
        END IF;
        IF TG_OP = 'UPDATE' AND OLD.last_read_message_id IS NOT NULL
           AND NEW.last_read_message_id IS DISTINCT FROM OLD.last_read_message_id THEN
            SELECT server_sequence INTO v_old_sequence
            FROM chat.message
            WHERE message_id = OLD.last_read_message_id
              AND conversation_id = OLD.conversation_id;
            IF v_old_sequence IS NULL OR v_new_sequence < v_old_sequence THEN
                RAISE EXCEPTION USING ERRCODE = '23514',
                    MESSAGE = 'Last-read message cursor cannot move backwards.';
            END IF;
        END IF;
    ELSIF TG_OP = 'UPDATE' AND OLD.last_read_message_id IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Last-read message cursor cannot be cleared.';
    END IF;

    IF TG_OP = 'UPDATE' AND OLD.left_at IS NOT NULL
       AND NEW.left_at IS DISTINCT FROM OLD.left_at THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Participant leave time is immutable once set.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_conversation_participant ON chat.conversation_participant;
CREATE TRIGGER enforce_conversation_participant
BEFORE INSERT OR UPDATE ON chat.conversation_participant
FOR EACH ROW EXECUTE FUNCTION chat.enforce_conversation_participant();

-- Deferred validation permits the two participants to be inserted in separate statements
-- while guaranteeing that every conversation has exactly the connection pair at commit.
CREATE OR REPLACE FUNCTION chat.validate_conversation_participant_set()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, chat, social
AS $$
DECLARE
    v_conversation_id varchar(64);
    v_member_low_id varchar(64);
    v_member_high_id varchar(64);
    v_participant_count int;
BEGIN
    v_conversation_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.conversation_id ELSE NEW.conversation_id END;

    SELECT cn.member_low_id, cn.member_high_id
    INTO v_member_low_id, v_member_high_id
    FROM chat.conversation c
    JOIN social.connection cn ON cn.connection_id = c.connection_id
    WHERE c.conversation_id = v_conversation_id;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT count(*) INTO v_participant_count
    FROM chat.conversation_participant cp
    WHERE cp.conversation_id = v_conversation_id
      AND cp.member_id IN (v_member_low_id, v_member_high_id);

    IF v_participant_count <> 2 OR EXISTS (
        SELECT 1 FROM chat.conversation_participant cp
        WHERE cp.conversation_id = v_conversation_id
          AND cp.member_id NOT IN (v_member_low_id, v_member_high_id)
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Conversation must contain exactly the two members of its connection.';
    END IF;
    RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS validate_conversation_participant_set_on_conversation ON chat.conversation;
CREATE CONSTRAINT TRIGGER validate_conversation_participant_set_on_conversation
AFTER INSERT OR UPDATE ON chat.conversation
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION chat.validate_conversation_participant_set();
DROP TRIGGER IF EXISTS validate_conversation_participant_set_on_participant ON chat.conversation_participant;
CREATE CONSTRAINT TRIGGER validate_conversation_participant_set_on_participant
AFTER INSERT OR UPDATE OR DELETE ON chat.conversation_participant
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION chat.validate_conversation_participant_set();

-- Direct message writes cannot bypass participant/connection/block authorization.
CREATE OR REPLACE FUNCTION chat.enforce_message_sender()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND (
        NEW.message_id IS DISTINCT FROM OLD.message_id
        OR NEW.conversation_id IS DISTINCT FROM OLD.conversation_id
        OR NEW.sender_member_id IS DISTINCT FROM OLD.sender_member_id
        OR NEW.server_sequence IS DISTINCT FROM OLD.server_sequence
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Message identity, conversation, sender and server sequence are immutable.';
    END IF;
    IF TG_OP = 'INSERT' AND NOT EXISTS (
        SELECT 1 FROM chat.vw_authorized_conversation authorized
        WHERE authorized.conversation_id = NEW.conversation_id
          AND authorized.member_id = NEW.sender_member_id
          AND authorized.can_send
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '42501',
            MESSAGE = 'Message sender is not authorized for the conversation.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_message_sender ON chat.message;
CREATE TRIGGER enforce_message_sender
BEFORE INSERT OR UPDATE ON chat.message
FOR EACH ROW EXECUTE FUNCTION chat.enforce_message_sender();

-- Receipts belong to the non-sending participant and first-delivered/read timestamps
-- are monotonic, immutable evidence.
CREATE OR REPLACE FUNCTION chat.enforce_message_receipt()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_conversation_id varchar(64);
    v_sender_member_id varchar(64);
BEGIN
    IF TG_OP = 'UPDATE' AND (
        NEW.message_id IS DISTINCT FROM OLD.message_id
        OR NEW.member_id IS DISTINCT FROM OLD.member_id
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Message receipt identity is immutable.';
    END IF;

    SELECT conversation_id, sender_member_id
    INTO v_conversation_id, v_sender_member_id
    FROM chat.message
    WHERE message_id = NEW.message_id;

    IF v_conversation_id IS NULL OR NEW.member_id = v_sender_member_id OR NOT EXISTS (
        SELECT 1 FROM chat.conversation_participant cp
        WHERE cp.conversation_id = v_conversation_id AND cp.member_id = NEW.member_id
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Message receipt must belong to the non-sending conversation participant.';
    END IF;

    IF NEW.read_at IS NOT NULL AND (NEW.delivered_at IS NULL OR NEW.read_at < NEW.delivered_at) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Read time cannot precede delivery time.';
    END IF;
    IF TG_OP = 'UPDATE' AND (
        (OLD.delivered_at IS NOT NULL AND NEW.delivered_at IS DISTINCT FROM OLD.delivered_at)
        OR (OLD.read_at IS NOT NULL AND NEW.read_at IS DISTINCT FROM OLD.read_at)
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'Delivered and read timestamps are immutable once recorded.';
    END IF;
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_message_receipt ON chat.message_receipt;
CREATE TRIGGER enforce_message_receipt
BEFORE INSERT OR UPDATE ON chat.message_receipt
FOR EACH ROW EXECUTE FUNCTION chat.enforce_message_receipt();

-- A privacy request is terminal only after its explicit domain work is terminal and evidenced.
CREATE OR REPLACE FUNCTION consent.enforce_privacy_request_completion()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.status = 'COMPLETED' AND NEW.status <> 'COMPLETED' THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'A completed PrivacyRequest cannot return to a mutable state.';
    END IF;
    IF NEW.status = 'COMPLETED' AND (
        NOT EXISTS (SELECT 1 FROM consent.privacy_request_task WHERE privacy_request_id = NEW.privacy_request_id)
        OR EXISTS (
            SELECT 1 FROM consent.privacy_request_task
            WHERE privacy_request_id = NEW.privacy_request_id
              AND (status NOT IN ('COMPLETED','EXEMPTED') OR evidence_code IS NULL OR completed_at IS NULL)
        )
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'PrivacyRequest cannot complete until every required task is completed or evidenced as exempt.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS enforce_privacy_request_completion ON consent.privacy_request;
CREATE TRIGGER enforce_privacy_request_completion
BEFORE INSERT OR UPDATE ON consent.privacy_request
FOR EACH ROW EXECUTE FUNCTION consent.enforce_privacy_request_completion();

CREATE OR REPLACE FUNCTION consent.protect_completed_privacy_request_tasks()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM consent.privacy_request
        WHERE privacy_request_id = OLD.privacy_request_id AND status = 'COMPLETED'
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Tasks and evidence for a completed PrivacyRequest are immutable.';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS protect_completed_privacy_request_tasks ON consent.privacy_request_task;
CREATE TRIGGER protect_completed_privacy_request_tasks
BEFORE UPDATE OR DELETE ON consent.privacy_request_task
FOR EACH ROW EXECUTE FUNCTION consent.protect_completed_privacy_request_tasks();

-- Active retention versions are immutable except for the ACTIVE-to-RETIRED transition.
CREATE OR REPLACE FUNCTION ops.protect_active_retention_policy()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status = 'ACTIVE' AND (
        NEW.resource_type IS DISTINCT FROM OLD.resource_type
        OR NEW.policy_version IS DISTINCT FROM OLD.policy_version
        OR NEW.retention_days IS DISTINCT FROM OLD.retention_days
        OR NEW.disposition_action IS DISTINCT FROM OLD.disposition_action
        OR NEW.legal_hold_supported IS DISTINCT FROM OLD.legal_hold_supported
        OR NEW.effective_from IS DISTINCT FROM OLD.effective_from
        OR NEW.approved_by IS DISTINCT FROM OLD.approved_by
        OR NEW.status NOT IN ('ACTIVE','RETIRED')
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'An active retention policy version is immutable and may only be retired.';
    END IF;
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS protect_active_retention_policy ON ops.retention_policy;
CREATE TRIGGER protect_active_retention_policy
BEFORE UPDATE ON ops.retention_policy
FOR EACH ROW EXECUTE FUNCTION ops.protect_active_retention_policy();
