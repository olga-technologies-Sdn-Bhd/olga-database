CREATE OR REPLACE FUNCTION nlp.get_requester_intent(
    p_member_id varchar(64), p_intent_id varchar(64), p_context_id varchar(64)
)
RETURNS TABLE (
    intent_id varchar(64), member_id varchar(64), context_id varchar(64), intent_type varchar(16),
    normalized_text varchar(4000), category varchar(128), industry varchar(128), geography varchar(128),
    updated_at timestamptz, model_version varchar(128), dimensions int, embedding_hash char(64), embedding vector(1536)
)
LANGUAGE sql
STABLE
AS $$
    SELECT i.intent_id, i.member_id, i.context_id, i.intent_type, i.normalized_text,
           i.category, i.industry, i.geography, i.updated_at,
           e.model_version, e.dimensions, e.normalized_hash, e.embedding
    FROM nlp.nlp_intent i
    JOIN nlp.nlp_embedding e
      ON e.intent_id = i.intent_id
     AND e.status = 'ACTIVE'
     AND e.normalized_hash = i.normalized_hash
    JOIN nlp.nlp_model_version mv
      ON mv.model_version = e.model_version
     AND mv.status = 'ACTIVE'
     AND mv.dimensions = e.dimensions
     AND mv.preprocessing_version = i.preprocessing_version
    WHERE i.intent_id = p_intent_id AND i.member_id = p_member_id AND i.context_id = p_context_id
      AND i.status = 'MATCH_READY' AND i.expires_at > CURRENT_TIMESTAMP;
$$;

CREATE OR REPLACE FUNCTION nlp.get_eligible_candidates(
    p_requester_id varchar(64), p_context_id varchar(64), p_max_rows int DEFAULT 200
)
RETURNS TABLE (
    intent_id varchar(64), member_id varchar(64), context_id varchar(64), intent_type varchar(16),
    normalized_text varchar(4000), category varchar(128), industry varchar(128), geography varchar(128),
    updated_at timestamptz, model_version varchar(128), dimensions int, embedding_hash char(64),
    embedding vector(1536), cosine_distance double precision
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_max_rows NOT BETWEEN 50 AND 200 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'max_rows must be between 50 and 200.';
    END IF;
    RETURN QUERY
    WITH requester_scope AS MATERIALIZED (
        SELECT eligibility.community_id
        FROM nlp.vw_member_context_eligibility eligibility
        WHERE eligibility.member_id = p_requester_id
          AND eligibility.context_id = p_context_id
          AND eligibility.is_live
          AND eligibility.is_visible
          AND eligibility.has_consent
          AND NOT eligibility.is_suspended
          AND NOT eligibility.is_deleted
        LIMIT 1
    ), requester_embedding AS MATERIALIZED (
        SELECT i.intent_id, e.embedding
        FROM nlp.nlp_intent i
        CROSS JOIN requester_scope
        JOIN nlp.nlp_embedding e
          ON e.intent_id = i.intent_id
         AND e.status = 'ACTIVE'
         AND e.normalized_hash = i.normalized_hash
        JOIN nlp.nlp_model_version mv
          ON mv.model_version = e.model_version
         AND mv.status = 'ACTIVE'
         AND mv.dimensions = e.dimensions
         AND mv.preprocessing_version = i.preprocessing_version
        WHERE i.member_id = p_requester_id AND i.context_id = p_context_id
          AND i.intent_type = 'WANT' AND i.status = 'MATCH_READY' AND i.expires_at > CURRENT_TIMESTAMP
        ORDER BY i.updated_at DESC, i.intent_id
        LIMIT 1
    ), matching_policy AS MATERIALIZED (
        SELECT p.proximity_mode, p.max_presence_age_minutes
        FROM event.event_matching_policy p
        WHERE p.event_id = p_context_id AND p.status = 'ACTIVE'
          AND p.effective_from <= CURRENT_TIMESTAMP
          AND (p.effective_to IS NULL OR p.effective_to > CURRENT_TIMESTAMP)
        ORDER BY p.policy_version DESC
        LIMIT 1
    ), eligible_members AS MATERIALIZED (
        SELECT m.member_id
        FROM nlp.vw_member_context_eligibility m
        JOIN requester_scope requester ON requester.community_id = m.community_id
        WHERE m.context_id = p_context_id AND m.member_id <> p_requester_id
          AND m.is_live AND m.is_visible AND m.has_consent AND NOT m.is_suspended AND NOT m.is_deleted
          AND NOT EXISTS (
              SELECT 1 FROM nlp.vw_member_relationship r
              WHERE r.context_id = 'GLOBAL' AND r.member_id = p_requester_id AND r.other_member_id = m.member_id
                AND (r.is_blocked OR r.is_connected)
          )
          AND (
              NOT EXISTS (SELECT 1 FROM matching_policy p WHERE p.proximity_mode = 'COARSE_CELL')
              OR EXISTS (
                  SELECT 1
                  FROM matching_policy p
                  JOIN event.live_mode_session requester_session
                    ON requester_session.event_id = p_context_id AND requester_session.member_id = p_requester_id
                   AND requester_session.status = 'ACTIVE' AND requester_session.active_until > CURRENT_TIMESTAMP
                  JOIN event.event_presence requester_presence
                    ON requester_presence.live_session_id = requester_session.live_session_id
                   AND requester_presence.observed_at >= CURRENT_TIMESTAMP - make_interval(mins => p.max_presence_age_minutes)
                   AND requester_presence.expires_at > CURRENT_TIMESTAMP
                  JOIN event.live_mode_session candidate_session
                    ON candidate_session.event_id = p_context_id AND candidate_session.member_id = m.member_id
                   AND candidate_session.status = 'ACTIVE' AND candidate_session.active_until > CURRENT_TIMESTAMP
                  JOIN event.event_presence candidate_presence
                    ON candidate_presence.live_session_id = candidate_session.live_session_id
                   AND candidate_presence.coarse_cell = requester_presence.coarse_cell
                   AND candidate_presence.observed_at >= CURRENT_TIMESTAMP - make_interval(mins => p.max_presence_age_minutes)
                   AND candidate_presence.expires_at > CURRENT_TIMESTAMP
                  WHERE p.proximity_mode = 'COARSE_CELL'
              )
          )
    ), eligible_candidates AS MATERIALIZED (
        SELECT i.intent_id, i.member_id, i.context_id, i.intent_type, i.normalized_text,
               i.category, i.industry, i.geography, i.updated_at,
               e.model_version, e.dimensions, e.normalized_hash AS embedding_hash, e.embedding
        FROM eligible_members m
        JOIN nlp.nlp_intent i ON i.member_id = m.member_id AND i.context_id = p_context_id
        JOIN nlp.nlp_embedding e
          ON e.intent_id = i.intent_id
         AND e.status = 'ACTIVE'
         AND e.normalized_hash = i.normalized_hash
        JOIN nlp.nlp_model_version mv
          ON mv.model_version = e.model_version
         AND mv.status = 'ACTIVE'
         AND mv.dimensions = e.dimensions
         AND mv.preprocessing_version = i.preprocessing_version
        CROSS JOIN requester_embedding requester
        WHERE i.intent_type = 'OFFER' AND i.status = 'MATCH_READY' AND i.expires_at > CURRENT_TIMESTAMP
          AND NOT EXISTS (
              SELECT 1
              FROM nlp.match_suppression s
              WHERE s.starts_at <= CURRENT_TIMESTAMP
                AND (s.ends_at IS NULL OR s.ends_at > CURRENT_TIMESTAMP)
                AND (s.member_id IS NULL OR s.member_id IN (p_requester_id, m.member_id))
                AND (s.context_id IS NULL OR s.context_id = p_context_id)
                AND (s.intent_id IS NULL OR s.intent_id IN (requester.intent_id, i.intent_id))
          )
        ORDER BY i.updated_at DESC, i.intent_id
        LIMIT p_max_rows
    )
    -- MATERIALIZED eligibility bounds the exact vector scan before cosine ranking.
    SELECT c.intent_id, c.member_id, c.context_id, c.intent_type, c.normalized_text,
           c.category, c.industry, c.geography, c.updated_at,
           c.model_version, c.dimensions, c.embedding_hash, c.embedding,
           (c.embedding <=> r.embedding)::double precision
    FROM eligible_candidates c
    CROSS JOIN requester_embedding r
    ORDER BY c.embedding <=> r.embedding, c.updated_at DESC, c.intent_id;
END;
$$;

CREATE OR REPLACE FUNCTION nlp.save_match_results(
    p_request_id varchar(64), p_requester_id varchar(64), p_results jsonb
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_request_id varchar(64);
BEGIN
    IF jsonb_typeof(p_results) <> 'array' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'results must be a JSON array.';
    END IF;
    SELECT request_id INTO v_request_id
    FROM nlp.match_request
    WHERE request_id = p_request_id AND requester_id = p_requester_id
    FOR UPDATE;
    IF v_request_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Match request not found for requester.';
    END IF;
    INSERT INTO nlp.nlp_match_result(
        request_id, requester_id, candidate_id, rank, semantic_score, reciprocal_score, final_score,
        label, reason_codes, reason_text, model_version, preprocessing_version, ranking_version, policy_status
    )
    SELECT p_request_id, p_requester_id, x.candidate_id, x.rank, x.semantic_score, x.reciprocal_score,
           x.final_score, x.label, x.reason_codes, x.reason_text, x.model_version,
           x.preprocessing_version, x.ranking_version, COALESCE(x.policy_status, 'ELIGIBLE')
    FROM jsonb_to_recordset(p_results) AS x(
        candidate_id varchar(64), rank smallint, semantic_score numeric(8,7), reciprocal_score numeric(8,7),
        final_score numeric(8,7), label varchar(32), reason_codes jsonb, reason_text varchar(2000),
        model_version varchar(128), preprocessing_version varchar(128), ranking_version varchar(128), policy_status varchar(24)
    )
    ON CONFLICT (request_id, candidate_id) DO NOTHING;
    UPDATE nlp.match_request
    SET status = 'COMPLETED',
        candidate_count = (SELECT count(*) FROM nlp.nlp_match_result WHERE request_id = p_request_id),
        completed_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE request_id = p_request_id;
END;
$$;

CREATE OR REPLACE FUNCTION nlp.save_feedback(
    p_match_result_id bigint, p_requester_id varchar(64), p_label varchar(64),
    p_reason_code varchar(64) DEFAULT NULL, p_reason varchar(1000) DEFAULT NULL,
    p_supersedes_feedback_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_request_id varchar(64);
    v_candidate_id varchar(64);
    v_feedback_id bigint;
BEGIN
    IF p_label NOT IN ('USEFUL','NOT_USEFUL','INAPPROPRIATE') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Unsupported feedback label.';
    END IF;
    SELECT request_id, candidate_id INTO v_request_id, v_candidate_id
    FROM nlp.nlp_match_result
    WHERE match_result_id = p_match_result_id AND requester_id = p_requester_id;
    IF v_request_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Match result not found for requester.';
    END IF;
    IF p_supersedes_feedback_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM nlp.nlp_feedback
        WHERE feedback_id = p_supersedes_feedback_id
          AND requester_id = p_requester_id AND match_result_id = p_match_result_id
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Feedback correction does not reference the same requester and match result.';
    END IF;
    INSERT INTO nlp.nlp_feedback(
        supersedes_feedback_id, match_result_id, request_id, requester_id, candidate_id, label, reason_code, reason
    ) VALUES (
        p_supersedes_feedback_id, p_match_result_id, v_request_id, p_requester_id, v_candidate_id, p_label, p_reason_code, p_reason
    ) RETURNING feedback_id INTO v_feedback_id;
    RETURN v_feedback_id;
END;
$$;

DROP FUNCTION IF EXISTS social.accept_connection_request(varchar, varchar, varchar, varchar);
CREATE OR REPLACE FUNCTION social.accept_connection_request(
    p_connection_request_id varchar(64), p_recipient_member_id varchar(64),
    p_connection_id varchar(64), p_conversation_id varchar(64),
    p_idempotency_key varchar(128), p_request_hash char(64),
    p_idempotency_expires_at timestamptz, p_sync_expires_at timestamptz
)
RETURNS TABLE (connection_id varchar(64), conversation_id varchar(64))
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, social, chat, ops, iam
AS $$
DECLARE
    v_sender_id varchar(64);
    v_community_id varchar(64);
    v_request_version bigint;
    v_existing_connection_id varchar(64);
    v_existing_conversation_id varchar(64);
    v_existing_hash char(64);
    v_idempotency_status smallint;
    v_claimed boolean := false;
BEGIN
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' OR p_request_hash IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Idempotency key and request hash are required.';
    END IF;
    IF p_idempotency_expires_at <= CURRENT_TIMESTAMP OR p_sync_expires_at <= CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Idempotency and sync expiry must be in the future.';
    END IF;

    INSERT INTO ops.idempotency_record(scope, idempotency_key, actor_id, request_hash, expires_at)
    VALUES ('social.accept_connection_request', p_idempotency_key, p_recipient_member_id, p_request_hash, p_idempotency_expires_at)
    ON CONFLICT (scope, actor_id, idempotency_key) DO NOTHING
    RETURNING true INTO v_claimed;

    SELECT request_hash, status_code
    INTO v_existing_hash, v_idempotency_status
    FROM ops.idempotency_record
    WHERE scope = 'social.accept_connection_request'
      AND actor_id = p_recipient_member_id
      AND idempotency_key = p_idempotency_key
    FOR UPDATE;

    IF v_existing_hash IS DISTINCT FROM p_request_hash THEN
        RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'Idempotency key was already used with a different request.';
    END IF;
    IF NOT COALESCE(v_claimed, false) THEN
        IF v_idempotency_status IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = '55P03', MESSAGE = 'Idempotent operation is still in progress.';
        END IF;
        SELECT c.connection_id, cv.conversation_id
        INTO v_existing_connection_id, v_existing_conversation_id
        FROM social.connection c
        JOIN chat.conversation cv ON cv.connection_id = c.connection_id
        WHERE c.accepted_request_id = p_connection_request_id
          AND p_recipient_member_id IN (c.member_low_id, c.member_high_id);
        IF v_existing_connection_id = p_connection_id AND v_existing_conversation_id = p_conversation_id THEN
            RETURN QUERY SELECT v_existing_connection_id, v_existing_conversation_id;
            RETURN;
        END IF;
        RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'Idempotency result does not match the requested resource identifiers.';
    END IF;

    SELECT cr.sender_member_id, sender.community_id
    INTO v_sender_id, v_community_id
    FROM social.connection_request cr
    JOIN iam.member sender ON sender.member_id = cr.sender_member_id AND sender.status = 'ACTIVE'
    JOIN iam.member recipient
      ON recipient.member_id = cr.recipient_member_id
     AND recipient.status = 'ACTIVE'
     AND recipient.community_id = sender.community_id
    WHERE cr.connection_request_id = p_connection_request_id
      AND cr.recipient_member_id = p_recipient_member_id
      AND cr.status = 'PENDING' AND cr.expires_at > CURRENT_TIMESTAMP
    FOR UPDATE OF cr;
    IF v_sender_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Eligible pending connection request not found.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM social.member_block
        WHERE removed_at IS NULL
          AND ((blocker_member_id = v_sender_id AND blocked_member_id = p_recipient_member_id)
            OR (blocker_member_id = p_recipient_member_id AND blocked_member_id = v_sender_id))
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Connection is not eligible.';
    END IF;
    UPDATE social.connection_request
    SET status = 'ACCEPTED', responded_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
    WHERE connection_request_id = p_connection_request_id
    RETURNING row_version INTO v_request_version;
    INSERT INTO social.connection(connection_id, member_low_id, member_high_id, accepted_request_id)
    VALUES (p_connection_id, LEAST(v_sender_id, p_recipient_member_id), GREATEST(v_sender_id, p_recipient_member_id), p_connection_request_id);
    INSERT INTO chat.conversation(conversation_id, connection_id) VALUES (p_conversation_id, p_connection_id);
    INSERT INTO chat.conversation_participant(conversation_id, member_id)
    VALUES (p_conversation_id, v_sender_id), (p_conversation_id, p_recipient_member_id);
    INSERT INTO ops.outbox_event(outbox_event_id, aggregate_type, aggregate_id, event_type, payload_json)
    VALUES (gen_random_uuid()::text, 'CONNECTION', p_connection_id, 'connection.accepted',
            jsonb_build_object('connectionId', p_connection_id, 'conversationId', p_conversation_id));

    INSERT INTO ops.sync_change(
        community_id, member_scope_id, resource_type, resource_id, change_type,
        resource_version, payload_json, expires_at
    )
    SELECT v_community_id, member_id, 'REQUEST', p_connection_request_id, 'UPSERT',
           v_request_version,
           jsonb_build_object('requestId', p_connection_request_id, 'status', 'ACCEPTED'),
           p_sync_expires_at
    FROM (VALUES (v_sender_id), (p_recipient_member_id)) AS recipients(member_id)
    UNION ALL
    SELECT v_community_id, member_id, 'CONVERSATION', p_conversation_id, 'UPSERT',
           1,
           jsonb_build_object('conversationId', p_conversation_id, 'connectionId', p_connection_id),
           p_sync_expires_at
    FROM (VALUES (v_sender_id), (p_recipient_member_id)) AS recipients(member_id);

    UPDATE ops.idempotency_record
    SET status_code = 200, response_ref = p_connection_id || ':' || p_conversation_id
    WHERE scope = 'social.accept_connection_request'
      AND actor_id = p_recipient_member_id
      AND idempotency_key = p_idempotency_key;
    RETURN QUERY SELECT p_connection_id, p_conversation_id;
END;
$$;

DROP FUNCTION IF EXISTS chat.save_message(varchar, varchar, varchar, varchar, text, timestamptz);
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

CREATE OR REPLACE FUNCTION event.purge_expired_presence(p_batch_size int DEFAULT 5000)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_deleted bigint;
BEGIN
    IF p_batch_size NOT BETWEEN 1 AND 20000 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'batch_size must be between 1 and 20000.';
    END IF;
    WITH targets AS (
        SELECT ctid FROM event.event_presence
        WHERE expires_at <= CURRENT_TIMESTAMP
        ORDER BY expires_at
        LIMIT p_batch_size
        FOR UPDATE SKIP LOCKED
    )
    DELETE FROM event.event_presence p USING targets t WHERE p.ctid = t.ctid;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$;

CREATE OR REPLACE FUNCTION notification.try_enqueue(
    p_notification_id varchar(64), p_member_id varchar(64), p_purpose_code varchar(64), p_channel varchar(16),
    p_resource_type varchar(32), p_resource_id varchar(64), p_template_code varchar(64), p_dedupe_key varchar(160),
    p_context_id varchar(64) DEFAULT NULL, p_source_confidence numeric(6,5) DEFAULT NULL
)
RETURNS TABLE (
    notification_id varchar(64), status varchar(20), scheduled_at timestamptz,
    expires_at timestamptz, suppression_reason varchar(64)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_now timestamptz := CURRENT_TIMESTAMP;
    v_community_id varchar(64);
    v_policy_id bigint;
    v_opt_out boolean;
    v_quiet_behavior varchar(16);
    v_dedupe_seconds int;
    v_max_hour smallint;
    v_max_day smallint;
    v_ttl int;
    v_event_policy_id bigint;
    v_alert_threshold numeric(6,5);
    v_event_max_hour smallint;
    v_event_max_total smallint;
    v_min_interval smallint;
    v_suppression varchar(64);
    v_scheduled_at timestamptz := v_now;
    v_bucket_start timestamptz;
    v_push_enabled boolean := true;
    v_email_enabled boolean := true;
    v_quiet_start time;
    v_quiet_end time;
    v_timezone_id varchar(64);
    v_local_now timestamp;
    v_local_time time;
    v_target_date date;
BEGIN
    SELECT m.community_id INTO v_community_id
    FROM iam.member m WHERE m.member_id = p_member_id AND m.status = 'ACTIVE';
    IF v_community_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Active member not found.';
    END IF;
    SELECT p.notification_policy_id, p.member_opt_out_allowed, p.quiet_hours_behavior,
           p.dedupe_window_seconds, p.max_per_hour, p.max_per_day, p.ttl_minutes
    INTO v_policy_id, v_opt_out, v_quiet_behavior, v_dedupe_seconds, v_max_hour, v_max_day, v_ttl
    FROM notification.notification_policy p
    WHERE p.status = 'ACTIVE' AND p.purpose_code = p_purpose_code AND p.channel = p_channel
      AND (p.community_id = v_community_id OR p.community_id IS NULL)
      AND p.effective_from <= v_now AND (p.effective_to IS NULL OR p.effective_to > v_now)
    ORDER BY CASE WHEN p.community_id = v_community_id THEN 0 ELSE 1 END, p.policy_version DESC
    LIMIT 1;
    IF v_policy_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'No active notification policy.';
    END IF;
    IF p_context_id IS NOT NULL AND p_context_id <> 'GENERAL' THEN
        SELECT p.event_matching_policy_id, p.alert_confidence_threshold,
               p.max_match_alerts_per_hour, p.max_match_alerts_per_event, p.minimum_alert_interval_minutes
        INTO v_event_policy_id, v_alert_threshold, v_event_max_hour, v_event_max_total, v_min_interval
        FROM event.event_matching_policy p
        WHERE p.event_id = p_context_id AND p.status = 'ACTIVE'
          AND p.effective_from <= v_now AND (p.effective_to IS NULL OR p.effective_to > v_now)
        ORDER BY p.policy_version DESC LIMIT 1;
        IF p_purpose_code = 'MATCH' AND (v_event_policy_id IS NULL OR p_source_confidence IS NULL) THEN
            v_suppression := 'POLICY';
        END IF;
    END IF;
    SELECT p.push_enabled, p.email_enabled, p.quiet_start_local, p.quiet_end_local, p.timezone_id
    INTO v_push_enabled, v_email_enabled, v_quiet_start, v_quiet_end, v_timezone_id
    FROM notification.notification_preference p
    WHERE p.member_id = p_member_id AND p.purpose_code = p_purpose_code;
    IF NOT FOUND THEN
        v_push_enabled := true;
        v_email_enabled := true;
        v_quiet_start := NULL;
        v_quiet_end := NULL;
        v_timezone_id := NULL;
    END IF;

    v_bucket_start := to_timestamp(floor(extract(epoch FROM v_now) / v_dedupe_seconds) * v_dedupe_seconds);
    -- Serializes policy counters per member without locking unrelated recipients.
    PERFORM pg_advisory_xact_lock(hashtextextended(p_member_id || ':' || v_policy_id::text, 0));

    RETURN QUERY
    SELECT n.notification_id, n.status, n.scheduled_at, n.expires_at, n.suppression_reason
    FROM notification.notification n
    WHERE n.member_id = p_member_id AND n.channel = p_channel
      AND n.dedupe_key = p_dedupe_key AND n.dedupe_bucket_start = v_bucket_start;
    IF FOUND THEN RETURN; END IF;

    IF v_suppression IS NULL AND v_opt_out
       AND ((p_channel = 'PUSH' AND NOT v_push_enabled) OR (p_channel = 'EMAIL' AND NOT v_email_enabled)) THEN
        v_suppression := 'OPT_OUT';
    ELSIF v_suppression IS NULL AND v_event_policy_id IS NOT NULL
       AND p_source_confidence IS NOT NULL AND p_source_confidence < v_alert_threshold THEN
        v_suppression := 'BELOW_THRESHOLD';
    ELSIF v_suppression IS NULL AND ((SELECT count(*) FROM notification.notification n WHERE n.member_id = p_member_id AND n.notification_policy_id = v_policy_id AND n.created_at > v_now - interval '1 hour' AND n.status IN ('PENDING','SENT','DELIVERED')) >= v_max_hour
       OR (SELECT count(*) FROM notification.notification n WHERE n.member_id = p_member_id AND n.notification_policy_id = v_policy_id AND n.created_at > v_now - interval '1 day' AND n.status IN ('PENDING','SENT','DELIVERED')) >= v_max_day) THEN
        v_suppression := 'RATE_LIMIT';
    ELSIF v_suppression IS NULL AND v_event_policy_id IS NOT NULL AND (
        (SELECT count(*) FROM notification.notification n WHERE n.member_id = p_member_id AND n.event_matching_policy_id = v_event_policy_id AND n.created_at > v_now - interval '1 hour' AND n.status IN ('PENDING','SENT','DELIVERED')) >= v_event_max_hour
        OR (SELECT count(*) FROM notification.notification n WHERE n.member_id = p_member_id AND n.event_matching_policy_id = v_event_policy_id AND n.status IN ('PENDING','SENT','DELIVERED')) >= v_event_max_total
        OR EXISTS (SELECT 1 FROM notification.notification n WHERE n.member_id = p_member_id AND n.event_matching_policy_id = v_event_policy_id AND n.created_at > v_now - make_interval(mins => v_min_interval) AND n.status IN ('PENDING','SENT','DELIVERED'))
    ) THEN
        v_suppression := 'RATE_LIMIT';
    END IF;

    IF v_suppression IS NULL AND v_quiet_start IS NOT NULL AND v_quiet_end IS NOT NULL AND v_timezone_id IS NOT NULL THEN
        v_local_now := v_now AT TIME ZONE v_timezone_id;
        v_local_time := v_local_now::time;
        IF (v_quiet_start < v_quiet_end AND v_local_time >= v_quiet_start AND v_local_time < v_quiet_end)
           OR (v_quiet_start > v_quiet_end AND (v_local_time >= v_quiet_start OR v_local_time < v_quiet_end)) THEN
            IF v_quiet_behavior = 'SUPPRESS' THEN
                v_suppression := 'QUIET_HOURS';
            ELSIF v_quiet_behavior = 'DEFER' THEN
                v_target_date := CASE WHEN v_local_time < v_quiet_end THEN v_local_now::date ELSE v_local_now::date + 1 END;
                v_scheduled_at := (v_target_date + v_quiet_end) AT TIME ZONE v_timezone_id;
            END IF;
        END IF;
    END IF;

    INSERT INTO notification.notification(
        notification_id, member_id, notification_policy_id, event_matching_policy_id, purpose_code, channel,
        resource_type, resource_id, template_code, dedupe_key, dedupe_bucket_start, source_confidence,
        context_id, status, scheduled_at, expires_at, suppression_reason
    ) VALUES (
        p_notification_id, p_member_id, v_policy_id, v_event_policy_id, p_purpose_code, p_channel,
        p_resource_type, p_resource_id, p_template_code, p_dedupe_key, v_bucket_start, p_source_confidence,
        p_context_id, CASE WHEN v_suppression IS NULL THEN 'PENDING' ELSE 'SUPPRESSED' END,
        v_scheduled_at, v_now + make_interval(mins => v_ttl), v_suppression
    );
    IF v_suppression IS NULL THEN
        INSERT INTO ops.outbox_event(outbox_event_id, aggregate_type, aggregate_id, event_type, payload_json)
        VALUES (gen_random_uuid()::text, 'NOTIFICATION', p_notification_id, 'notification.queued',
                jsonb_build_object('notificationId', p_notification_id));
    END IF;
    RETURN QUERY
    SELECT n.notification_id, n.status, n.scheduled_at, n.expires_at, n.suppression_reason
    FROM notification.notification n WHERE n.notification_id = p_notification_id;
END;
$$;
