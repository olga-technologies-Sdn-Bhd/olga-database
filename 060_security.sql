REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA core, iam, consent, event, social, chat,
    storage, notification, nlp, moderation, ops, analytics, admin, history FROM PUBLIC;
REVOKE ALL ON SCHEMA history FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA history FROM PUBLIC;

GRANT USAGE ON SCHEMA core, iam, consent, event, social, chat, storage, notification,
    nlp, moderation, ops, analytics, admin, history TO olga_dml_writer, olga_reader;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, iam, consent, event,
    social, chat, storage, notification, nlp, moderation, ops, analytics, admin, history
    TO olga_dml_writer;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA core, iam, consent, event, social,
    chat, storage, notification, nlp, moderation, ops, analytics, admin, history
    TO olga_dml_writer;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA core, iam, consent, event, social, chat, storage,
    notification, nlp, moderation, ops, analytics, admin, history TO olga_dml_writer;

GRANT SELECT ON ALL TABLES IN SCHEMA core, iam, consent, event, social, chat, storage,
    notification, nlp, moderation, ops, analytics, admin, history TO olga_reader;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA core, iam, consent, event, social, chat, storage,
    notification, nlp, moderation, ops, analytics, admin, history TO olga_reader;

-- Questionnaire definitions are deployment-managed reference data. The Core runtime reads them
-- but only writes member selections and responses.
REVOKE INSERT, UPDATE, DELETE ON
    core.sector, core.sector_questionnaire, core.profile_question, core.sector_questionnaire_question
FROM olga_dml_writer;
GRANT SELECT ON
    core.sector, core.sector_questionnaire, core.profile_question, core.sector_questionnaire_question
TO olga_dml_writer;
DO $questionnaire_sequence_privileges$
DECLARE
    sequence_name text;
BEGIN
    FOREACH sequence_name IN ARRAY ARRAY[
        pg_get_serial_sequence('core.sector_questionnaire', 'sector_questionnaire_id'),
        pg_get_serial_sequence('core.profile_question', 'profile_question_id'),
        pg_get_serial_sequence('core.sector_questionnaire_question', 'sector_questionnaire_question_id')
    ]
    LOOP
        IF sequence_name IS NULL THEN
            RAISE EXCEPTION 'Questionnaire identity sequence could not be resolved.';
        END IF;
        EXECUTE format('REVOKE ALL PRIVILEGES ON SEQUENCE %s FROM olga_dml_writer', sequence_name);
    END LOOP;
END;
$questionnaire_sequence_privileges$;

-- The embedding worker can read its input and lease queue rows, but it cannot create or
-- delete intents/jobs or access unrelated NLP and operational data.
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA nlp, ops FROM olga_nlp_worker;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA nlp, ops FROM olga_nlp_worker;
REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA nlp, ops FROM olga_nlp_worker;
REVOKE ALL PRIVILEGES ON SCHEMA nlp, ops FROM olga_nlp_worker;
GRANT USAGE ON SCHEMA nlp, ops TO olga_nlp_worker;
GRANT SELECT ON nlp.nlp_intent, nlp.nlp_processing_job, nlp.nlp_embedding TO olga_nlp_worker;
GRANT UPDATE (status, updated_at) ON nlp.nlp_intent TO olga_nlp_worker;
GRANT UPDATE (status, attempt_count, available_at, locked_until, error_code, updated_at)
    ON nlp.nlp_processing_job TO olga_nlp_worker;
GRANT INSERT, UPDATE ON nlp.nlp_embedding TO olga_nlp_worker;
GRANT INSERT ON ops.outbox_event TO olga_nlp_worker;

ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO olga_dml_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO olga_dml_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT EXECUTE ON FUNCTIONS TO olga_dml_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT SELECT ON TABLES TO olga_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE olga_ddl_admin
    GRANT SELECT ON SEQUENCES TO olga_reader;
