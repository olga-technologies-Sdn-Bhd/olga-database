DO $$
DECLARE
    expected_tables text[] := ARRAY[
        'core.community','core.organization','core.organization_member','core.member_profile','core.sector','core.member_sector','core.member_geography','core.profile_field_visibility','core.member_verification',
        'iam.member','iam.member_identity','iam.role','iam.permission','iam.role_permission','iam.member_role','iam.member_device','iam.auth_session',
        'consent.consent_policy','consent.member_consent','consent.privacy_request','consent.privacy_request_task',
        'event.venue','event.event','event.event_matching_policy','event.event_registration','event.live_mode_session','event.event_presence',
        'social.connection_request','social.connection','social.member_block','social.member_report',
        'chat.conversation','chat.conversation_participant','chat.message','chat.message_receipt',
        'storage.file_asset','storage.file_asset_link',
        'notification.notification_policy','notification.notification_preference','notification.push_token','notification.notification','notification.notification_delivery_attempt',
        'nlp.nlp_intent','nlp.nlp_embedding','nlp.nlp_model_version','nlp.nlp_ranking_config','nlp.nlp_processing_job','nlp.match_request','nlp.nlp_match_result','nlp.nlp_feedback','nlp.match_suppression','nlp.evaluation_dataset','nlp.evaluation_pair','nlp.evaluation_run',
        'moderation.moderation_case','moderation.moderation_action','moderation.content_rule','moderation.content_scan',
        'ops.outbox_event','ops.idempotency_record','ops.background_job','ops.sync_change','ops.retention_policy','ops.retention_execution','ops.audit_event',
        'analytics.product_event'
    ];
    expected_views text[] := ARRAY[
        'nlp.vw_member_context_eligibility','nlp.vw_member_relationship','chat.vw_authorized_conversation','admin.vw_member_review'
    ];
    expected_history_tables text[] := ARRAY[
        'history.iam_permission','history.iam_role','history.core_sector','history.consent_consent_policy',
        'history.event_venue','history.event_event_matching_policy','history.notification_notification_policy',
        'history.nlp_nlp_model_version','history.nlp_nlp_ranking_config','history.moderation_content_rule',
        'history.ops_retention_policy'
    ];
    expected_history_source_tables text[] := ARRAY[
        'iam.permission','iam.role','core.sector','consent.consent_policy','event.venue',
        'event.event_matching_policy','notification.notification_policy','nlp.nlp_model_version',
        'nlp.nlp_ranking_config','moderation.content_rule','ops.retention_policy'
    ];
    expected_functions text[] := ARRAY[
        'nlp.get_requester_intent','nlp.get_eligible_candidates','nlp.save_match_results','nlp.save_feedback',
        'social.accept_connection_request','chat.save_message','chat.save_message_receipt',
        'event.purge_expired_presence','notification.try_enqueue',
        'ops.set_audit_context','ops.current_audit_actor_id','ops.set_audit_actor','ops.archive_row_version'
    ];
    expected_triggers text[] := ARRAY[
        'storage.file_asset_link.enforce_file_asset_link_resource',
        'event.live_mode_session.enforce_live_mode_session_consent',
        'nlp.match_suppression.enforce_match_suppression_target',
        'social.connection.enforce_connection_request_pair',
        'social.connection_request.validate_accepted_request_connection_on_request',
        'social.connection.validate_accepted_request_connection_on_connection',
        'chat.conversation_participant.enforce_conversation_participant',
        'chat.conversation.validate_conversation_participant_set_on_conversation',
        'chat.conversation_participant.validate_conversation_participant_set_on_participant',
        'chat.message.enforce_message_sender',
        'chat.message_receipt.enforce_message_receipt',
        'consent.privacy_request.enforce_privacy_request_completion',
        'consent.privacy_request_task.protect_completed_privacy_request_tasks',
        'ops.retention_policy.protect_active_retention_policy'
    ];
    item text;
    actual_count int;
BEGIN
    SELECT count(*) INTO actual_count
    FROM information_schema.tables
    WHERE table_type = 'BASE TABLE'
      AND table_schema IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops','analytics');
    IF actual_count <> cardinality(expected_tables) THEN
        RAISE EXCEPTION 'Unexpected OLGA product-table count: expected %, found %', cardinality(expected_tables), actual_count;
    END IF;
    FOREACH item IN ARRAY expected_tables LOOP
        IF to_regclass(item) IS NULL THEN RAISE EXCEPTION 'Required table is missing: %', item; END IF;
    END LOOP;
    FOREACH item IN ARRAY expected_views LOOP
        IF to_regclass(item) IS NULL THEN RAISE EXCEPTION 'Required view is missing: %', item; END IF;
    END LOOP;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'nlp' AND table_name = 'vw_member_context_eligibility'
          AND column_name = 'community_id'
    ) THEN RAISE EXCEPTION 'Matching eligibility view must expose the authoritative community boundary.'; END IF;
    FOREACH item IN ARRAY expected_history_tables LOOP
        IF to_regclass(item) IS NULL THEN RAISE EXCEPTION 'Required temporal history table is missing: %', item; END IF;
    END LOOP;
    FOREACH item IN ARRAY expected_history_source_tables LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_trigger t
            WHERE t.tgrelid = item::regclass AND t.tgname = 'versioning_history'
              AND t.tgfoid = 'ops.archive_row_version()'::regprocedure AND t.tgenabled <> 'D'
        ) THEN RAISE EXCEPTION 'Required temporal versioning trigger is missing: %', item; END IF;
    END LOOP;
    FOREACH item IN ARRAY expected_functions LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = split_part(item,'.',1) AND p.proname = split_part(item,'.',2)
        ) THEN RAISE EXCEPTION 'Required function is missing: %', item; END IF;
    END LOOP;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'social' AND p.proname = 'accept_connection_request'
          AND p.pronargs = 8 AND p.prosecdef
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'chat' AND p.proname = 'save_message'
          AND p.pronargs = 10 AND p.prosecdef
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'chat' AND p.proname = 'save_message_receipt'
          AND p.pronargs = 8 AND p.prosecdef
    ) THEN RAISE EXCEPTION 'Atomic mutation functions are missing required signatures or SECURITY DEFINER protection.'; END IF;
    FOREACH item IN ARRAY expected_triggers LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_trigger t
            JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE NOT t.tgisinternal AND n.nspname = split_part(item,'.',1)
              AND c.relname = split_part(item,'.',2) AND t.tgname = split_part(item,'.',3)
        ) THEN RAISE EXCEPTION 'Required trigger is missing: %', item; END IF;
    END LOOP;
    IF to_regclass('chat.message_sequence') IS NULL OR to_regclass('ops.sync_change_sequence') IS NULL THEN
        RAISE EXCEPTION 'One or more required sequences are missing.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'ops.idempotency_record'::regclass
          AND conname = 'pk_idempotency_record_'
          AND pg_get_constraintdef(oid) = 'PRIMARY KEY (scope, actor_id, idempotency_key)'
    ) THEN RAISE EXCEPTION 'Idempotency primary key must be scoped by operation, actor and client key.'; END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'ops.archive_row_version()'::regprocedure) THEN
        RAISE EXCEPTION 'Temporal history trigger must run as a security-definer function.';
    END IF;
    IF to_regclass('chat.attachment') IS NOT NULL THEN RAISE EXCEPTION 'Legacy chat.attachment must not remain.'; END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'iam' AND table_name = 'member_identity' AND column_name = 'provider_subject'
    ) THEN RAISE EXCEPTION 'Plaintext identity subject column remains.'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'iam' AND table_name = 'member_identity' AND column_name = 'provider_subject_hash'
    ) OR NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'iam' AND table_name = 'member_identity' AND column_name = 'provider_subject_ciphertext' AND data_type = 'bytea'
    ) THEN RAISE EXCEPTION 'Protected identity subject columns are missing or invalid.'; END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute a
        JOIN pg_class t ON t.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = 'nlp' AND t.relname = 'nlp_embedding' AND a.attname = 'embedding'
          AND format_type(a.atttypid, a.atttypmod) = 'vector(1536)'
    ) THEN RAISE EXCEPTION 'nlp_embedding.embedding must use pgvector.'; END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE column_name = 'row_version'
          AND table_schema IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops')
          AND (data_type <> 'bigint' OR column_default IS NULL OR column_default !~ '^1(?:::bigint)?$')
    ) THEN RAISE EXCEPTION 'Every row_version must be bigint with default 1.'; END IF;
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.column_name = 'row_version'
          AND c.table_schema IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops')
          AND NOT EXISTS (
              SELECT 1 FROM pg_trigger t
              WHERE t.tgrelid = format('%I.%I', c.table_schema, c.table_name)::regclass
                AND t.tgname = 'set_row_version' AND t.tgfoid = 'ops.set_row_version()'::regprocedure
                AND t.tgenabled <> 'D'
          )
    ) THEN RAISE EXCEPTION 'One or more row_version triggers are missing or disabled.'; END IF;
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.column_name = 'row_version'
          AND c.table_schema IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops')
          AND (
              NOT EXISTS (
                  SELECT 1 FROM information_schema.columns a
                  WHERE a.table_schema = c.table_schema AND a.table_name = c.table_name
                    AND a.column_name IN ('created_by','updated_by')
                  GROUP BY a.table_schema, a.table_name HAVING count(*) = 2
              )
              OR NOT EXISTS (
                  SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = format('%I.%I', c.table_schema, c.table_name)::regclass
                    AND t.tgname = 'set_audit_actor' AND t.tgfoid = 'ops.set_audit_actor()'::regprocedure
                    AND t.tgenabled <> 'D'
              )
          )
    ) THEN RAISE EXCEPTION 'One or more mutable resources lack audit actor columns or triggers.'; END IF;
    IF EXISTS (
        SELECT 1 FROM unnest(expected_history_tables) h(history_name)
        WHERE NOT EXISTS (
            SELECT 1 FROM information_schema.columns c
            WHERE c.table_schema = split_part(h.history_name,'.',1)
              AND c.table_name = split_part(h.history_name,'.',2)
              AND c.column_name = 'sys_period' AND c.udt_name = 'tstzrange'
        )
    ) THEN RAISE EXCEPTION 'One or more temporal history tables lack a tstzrange system period.'; END IF;
    IF EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops','analytics')
          AND NOT c.convalidated
    ) THEN RAISE EXCEPTION 'One or more constraints are not validated.'; END IF;
    IF EXISTS (
        SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops','analytics')
          AND NOT i.indisvalid
    ) THEN RAISE EXCEPTION 'One or more indexes are invalid.'; END IF;
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops','analytics')
          AND indexdef ~* 'USING[[:space:]]+(hnsw|ivfflat)'
    ) THEN RAISE EXCEPTION 'Approximate vector indexes are not approved.'; END IF;
    IF EXISTS (
        SELECT 1
        FROM chat.conversation c
        JOIN social.connection cn ON cn.connection_id = c.connection_id
        LEFT JOIN chat.conversation_participant cp ON cp.conversation_id = c.conversation_id
        GROUP BY c.conversation_id, cn.member_low_id, cn.member_high_id
        HAVING count(cp.member_id) <> 2
           OR count(*) FILTER (WHERE cp.member_id IN (cn.member_low_id, cn.member_high_id)) <> 2
    ) THEN RAISE EXCEPTION 'One or more conversations do not contain exactly their connection members.'; END IF;
    IF EXISTS (
        SELECT 1
        FROM chat.message_receipt mr
        JOIN chat.message m ON m.message_id = mr.message_id
        LEFT JOIN chat.conversation_participant cp
          ON cp.conversation_id = m.conversation_id AND cp.member_id = mr.member_id
        WHERE cp.member_id IS NULL OR mr.member_id = m.sender_member_id
           OR (mr.read_at IS NOT NULL AND (mr.delivered_at IS NULL OR mr.read_at < mr.delivered_at))
    ) THEN RAISE EXCEPTION 'One or more message receipts violate participant or timestamp integrity.'; END IF;
    IF EXISTS (
        SELECT 1
        FROM chat.conversation_participant cp
        JOIN chat.message m ON m.message_id = cp.last_read_message_id
        WHERE cp.last_read_message_id IS NOT NULL AND m.conversation_id <> cp.conversation_id
    ) THEN RAISE EXCEPTION 'One or more participant read cursors reference another conversation.'; END IF;
    IF NOT EXISTS (SELECT 1 FROM iam.permission WHERE status = 'ACTIVE')
       OR NOT EXISTS (SELECT 1 FROM iam.role_permission WHERE revoked_at IS NULL) THEN
        RAISE EXCEPTION 'Authorization permission seeds are missing.';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM nlp.nlp_model_version
        WHERE model_version = 'azure-text-embedding-3-small-1536-v1'
          AND provider = 'AZURE_OPENAI'
          AND deployment_name = 'text-embedding-3-small'
          AND dimensions = 1536
          AND preprocessing_version = 'normalizer-v1'
          AND status = 'ACTIVE'
          AND activated_at IS NOT NULL
    ) THEN RAISE EXCEPTION 'The approved active NLP model seed is missing or inconsistent.'; END IF;
    IF NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_intent', 'SELECT')
       OR NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_processing_job', 'SELECT')
       OR NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_embedding', 'SELECT')
       OR NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_embedding', 'INSERT')
       OR NOT has_table_privilege('olga_nlp_worker', 'nlp.nlp_embedding', 'UPDATE')
       OR NOT has_table_privilege('olga_nlp_worker', 'ops.outbox_event', 'INSERT')
       OR NOT has_column_privilege('olga_nlp_worker', 'nlp.nlp_intent', 'status', 'UPDATE')
       OR NOT has_column_privilege('olga_nlp_worker', 'nlp.nlp_processing_job', 'locked_until', 'UPDATE')
       OR has_table_privilege('olga_nlp_worker', 'nlp.nlp_intent', 'INSERT')
       OR has_table_privilege('olga_nlp_worker', 'nlp.nlp_intent', 'DELETE')
       OR has_table_privilege('olga_nlp_worker', 'nlp.nlp_processing_job', 'INSERT')
       OR has_table_privilege('olga_nlp_worker', 'nlp.nlp_processing_job', 'DELETE')
       OR has_table_privilege('olga_nlp_worker', 'ops.outbox_event', 'SELECT')
       OR has_table_privilege('olga_nlp_worker', 'ops.outbox_event', 'UPDATE')
       OR has_table_privilege('olga_nlp_worker', 'ops.outbox_event', 'DELETE')
       OR has_table_privilege('olga_nlp_worker', 'nlp.match_request', 'SELECT')
       OR has_table_privilege('olga_nlp_worker', 'nlp.match_request', 'INSERT')
       OR has_table_privilege('olga_nlp_worker', 'nlp.match_request', 'UPDATE')
       OR has_table_privilege('olga_nlp_worker', 'nlp.match_request', 'DELETE') THEN
        RAISE EXCEPTION 'NLP worker privileges are missing or exceed the approved boundary.';
    END IF;
END;
$$;

COMMENT ON SCHEMA ops IS 'OLGA.SchemaVersion=2.4';
RESET ROLE;
COMMIT;
