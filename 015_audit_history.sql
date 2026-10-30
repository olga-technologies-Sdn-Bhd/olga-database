-- Database-sourced actor attribution for mutable API resources. Applications should set
-- olga.actor_id after authenticating each request.
CREATE OR REPLACE FUNCTION ops.set_audit_context(p_actor_id varchar(64))
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    IF p_actor_id IS NULL OR btrim(p_actor_id) = '' THEN
        RAISE EXCEPTION 'Audit actor ID is required.' USING ERRCODE = '22023';
    END IF;
    PERFORM set_config('olga.actor_id', p_actor_id, true);
END;
$function$;

CREATE OR REPLACE FUNCTION ops.current_audit_actor_id()
RETURNS varchar(64)
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(NULLIF(current_setting('olga.actor_id', true), ''), session_user)::varchar(64)
$function$;

CREATE OR REPLACE FUNCTION ops.set_audit_actor()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops
AS $function$
DECLARE
    v_actor_id varchar(64) := ops.current_audit_actor_id();
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Never trust audit identities supplied in an INSERT payload.
        NEW.created_by := v_actor_id;
        NEW.updated_by := v_actor_id;
    ELSE
        NEW.created_by := OLD.created_by;
        NEW.updated_by := v_actor_id;
        NEW.updated_at := CURRENT_TIMESTAMP;
    END IF;
    RETURN NEW;
END;
$function$;

-- Add lifecycle support to the few reusable records that had no disable/retire state.
ALTER TABLE iam.member_identity ADD COLUMN IF NOT EXISTS status varchar(16) NOT NULL DEFAULT 'ACTIVE';
ALTER TABLE iam.member_identity ADD COLUMN IF NOT EXISTS revoked_at timestamptz NULL;
ALTER TABLE iam.member_identity ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE iam.member_identity ADD COLUMN IF NOT EXISTS row_version bigint NOT NULL DEFAULT 1;
ALTER TABLE iam.role ADD COLUMN IF NOT EXISTS status varchar(16) NOT NULL DEFAULT 'ACTIVE';
ALTER TABLE event.venue ADD COLUMN IF NOT EXISTS status varchar(16) NOT NULL DEFAULT 'ACTIVE';
ALTER TABLE chat.message ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE nlp.nlp_model_version ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE nlp.nlp_model_version ADD COLUMN IF NOT EXISTS row_version bigint NOT NULL DEFAULT 1;
ALTER TABLE nlp.nlp_ranking_config ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE nlp.nlp_ranking_config ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE nlp.nlp_ranking_config ADD COLUMN IF NOT EXISTS row_version bigint NOT NULL DEFAULT 1;

-- Audit actors may be members, administrators, services, or the database system; they are
-- intentionally polymorphic rather than foreign keys to iam.member.
ALTER TABLE nlp.match_suppression DROP CONSTRAINT IF EXISTS fk_match_suppression_created_by;
ALTER TABLE moderation.content_rule DROP CONSTRAINT IF EXISTS fk_content_rule_created_by;

-- Repair lifecycle checks from the prior baseline only when they omit documented states.
DO $block$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'iam.member'::regclass AND conname = 'ck_member_status'
          AND pg_get_constraintdef(oid) NOT LIKE '%ANONYMIZED%'
    ) THEN
        ALTER TABLE iam.member DROP CONSTRAINT ck_member_status;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'core.member_profile'::regclass AND conname = 'ck_member_profile_profile_status'
          AND pg_get_constraintdef(oid) NOT LIKE '%PENDING_REVIEW%'
    ) THEN
        ALTER TABLE core.member_profile DROP CONSTRAINT ck_member_profile_profile_status;
    END IF;
END;
$block$;

-- Every row_version-backed resource receives immutable creator attribution and a last-writer actor.
-- UNKNOWN is used only when upgrading rows that predate actor capture.
DO $block$
DECLARE
    target record;
BEGIN
    FOR target IN
        SELECT DISTINCT table_schema, table_name
        FROM information_schema.columns
        WHERE (
                column_name = 'row_version'
                AND table_schema IN ('core','iam','consent','event','social','chat','storage','notification','nlp','moderation','ops')
              )
           OR (table_schema, table_name) IN (
                ('nlp','nlp_model_version'),
                ('nlp','nlp_ranking_config')
              )
    LOOP
        EXECUTE format('ALTER TABLE %I.%I ADD COLUMN IF NOT EXISTS created_by varchar(64)', target.table_schema, target.table_name);
        EXECUTE format('ALTER TABLE %I.%I ADD COLUMN IF NOT EXISTS updated_by varchar(64)', target.table_schema, target.table_name);

        EXECUTE format(
            'UPDATE %I.%I SET created_by = COALESCE(created_by, %L), updated_by = COALESCE(updated_by, created_by, %L) WHERE created_by IS NULL OR updated_by IS NULL',
            target.table_schema, target.table_name, 'legacy_unknown', 'legacy_unknown'
        );

        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN created_by SET DEFAULT ops.current_audit_actor_id()', target.table_schema, target.table_name);
        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN updated_by SET DEFAULT ops.current_audit_actor_id()', target.table_schema, target.table_name);
        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN created_by SET NOT NULL', target.table_schema, target.table_name);
        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN updated_by SET NOT NULL', target.table_schema, target.table_name);

        EXECUTE format('DROP TRIGGER IF EXISTS set_audit_actor ON %I.%I', target.table_schema, target.table_name);
        EXECUTE format(
            'CREATE TRIGGER set_audit_actor BEFORE INSERT OR UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION ops.set_audit_actor()',
            target.table_schema, target.table_name
        );

        IF EXISTS (
            SELECT 1 FROM information_schema.columns c
            WHERE c.table_schema = target.table_schema AND c.table_name = target.table_name AND c.column_name = 'row_version'
        ) THEN
            EXECUTE format('DROP TRIGGER IF EXISTS set_row_version ON %I.%I', target.table_schema, target.table_name);
            EXECUTE format(
                'CREATE TRIGGER set_row_version BEFORE UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION ops.set_row_version()',
                target.table_schema, target.table_name
            );
        END IF;
    END LOOP;
END;
$block$;

-- PostgreSQL 17 has no native SQL Server-style FOR SYSTEM_TIME syntax. Archive OLD rows with an
-- OLGA-owned trigger because Azure-owned extension functions cannot safely be changed to
-- SECURITY DEFINER by a customer administrator.
-- History is intentionally limited to low-volume reference/configuration tables; copying member
-- content, identity ciphertext, messages or presence would conflict with privacy and retention.
CREATE OR REPLACE FUNCTION ops.archive_row_version()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops
AS $function$
DECLARE
    v_effective_at timestamptz := transaction_timestamp();
    v_period_start timestamptz;
    v_history_table regclass;
    v_history_schema name;
BEGIN
    IF TG_WHEN <> 'BEFORE' OR TG_LEVEL <> 'ROW'
       OR TG_OP NOT IN ('INSERT', 'UPDATE', 'DELETE') THEN
        RAISE EXCEPTION 'archive_row_version must be a BEFORE ROW trigger for INSERT, UPDATE or DELETE.'
            USING ERRCODE = '55000';
    END IF;
    IF TG_NARGS <> 1 THEN
        RAISE EXCEPTION 'archive_row_version requires one history-table argument.'
            USING ERRCODE = '22023';
    END IF;

    v_history_table := to_regclass(TG_ARGV[0]);
    IF v_history_table IS NULL THEN
        RAISE EXCEPTION 'History table % does not exist.', TG_ARGV[0]
            USING ERRCODE = '42P01';
    END IF;
    SELECT n.nspname
      INTO v_history_schema
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = v_history_table;
    IF v_history_schema <> 'history' THEN
        RAISE EXCEPTION 'History target must be in the history schema.'
            USING ERRCODE = '22023';
    END IF;

    IF TG_OP = 'INSERT' THEN
        NEW.sys_period := tstzrange(v_effective_at, NULL, '[)');
        RETURN NEW;
    END IF;

    v_period_start := lower(OLD.sys_period);
    IF v_period_start IS NULL OR v_period_start > v_effective_at THEN
        RAISE EXCEPTION 'Invalid system period on %.%.', TG_TABLE_SCHEMA, TG_TABLE_NAME
            USING ERRCODE = '22000';
    END IF;

    -- Multiple changes to a row in one transaction collapse into one externally visible version.
    IF v_period_start < v_effective_at THEN
        OLD.sys_period := tstzrange(v_period_start, v_effective_at, '[)');
        EXECUTE format('INSERT INTO %s SELECT ($1).*', v_history_table) USING OLD;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        NEW.sys_period := tstzrange(v_effective_at, NULL, '[)');
        RETURN NEW;
    END IF;
    RETURN OLD;
END;
$function$;

DO $block$
DECLARE
    target record;
    history_table name;
BEGIN
    FOR target IN
        SELECT * FROM (VALUES
            ('iam','permission','permission_code'),
            ('iam','role','role_code'),
            ('core','sector','sector_code'),
            ('consent','consent_policy','policy_id'),
            ('event','venue','venue_id'),
            ('event','event_matching_policy','event_matching_policy_id'),
            ('notification','notification_policy','notification_policy_id'),
            ('nlp','nlp_model_version','model_version'),
            ('nlp','nlp_ranking_config','ranking_version'),
            ('moderation','content_rule','content_rule_id'),
            ('ops','retention_policy','retention_policy_id')
        ) AS configured(table_schema, table_name, key_column)
    LOOP
        history_table := (target.table_schema || '_' || target.table_name)::name;
        EXECUTE format(
            'ALTER TABLE %I.%I ADD COLUMN IF NOT EXISTS sys_period tstzrange NOT NULL DEFAULT tstzrange(CURRENT_TIMESTAMP, NULL, ''[)'')',
            target.table_schema, target.table_name
        );
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS history.%I (LIKE %I.%I INCLUDING DEFAULTS)',
            history_table, target.table_schema, target.table_name
        );
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS %I ON history.%I (%I, lower(sys_period) DESC)',
            ('ix_' || history_table || '_key_period')::name, history_table, target.key_column
        );
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS %I ON history.%I USING gist (sys_period)',
            ('ix_' || history_table || '_sys_period')::name, history_table
        );
        EXECUTE format('DROP TRIGGER IF EXISTS versioning_history ON %I.%I', target.table_schema, target.table_name);
        EXECUTE format(
            'CREATE TRIGGER versioning_history BEFORE INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION ops.archive_row_version(%L)',
            target.table_schema, target.table_name, 'history.' || quote_ident(history_table)
        );
        EXECUTE format(
            'CREATE OR REPLACE VIEW history.%I AS SELECT * FROM %I.%I UNION ALL SELECT * FROM history.%I',
            (history_table || '_all')::name, target.table_schema, target.table_name, history_table
        );
    END LOOP;
END;
$block$;
