[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$schema = [System.IO.File]::ReadAllText((Join-Path $root '001_schemas_sequences.sql'))
$tables = [System.IO.File]::ReadAllText((Join-Path $root '010_tables.sql'))
$constraints = [System.IO.File]::ReadAllLines((Join-Path $root '020_constraints_indexes.sql'))
$seed = [System.IO.File]::ReadAllText((Join-Path $root '055_industry_questionnaire_seed.sql')).Trim()

$start = $tables.IndexOf('-- core.sector_questionnaire:', [System.StringComparison]::Ordinal)
$end = $tables.IndexOf('-- core.member_geography:', $start, [System.StringComparison]::Ordinal)
if ($start -lt 0 -or $end -lt 0) { throw 'Questionnaire table markers were not found.' }
$questionnaireTables = $tables.Substring($start, $end - $start).Trim()

$helperStart = $schema.IndexOf('CREATE OR REPLACE FUNCTION ops.add_constraint_if_missing(', [System.StringComparison]::Ordinal)
$helperEnd = $schema.IndexOf('$$;', $helperStart, [System.StringComparison]::Ordinal)
if ($helperStart -lt 0 -or $helperEnd -lt 0) { throw 'Constraint helper definition was not found.' }
$constraintHelper = $schema.Substring($helperStart, $helperEnd + 3 - $helperStart).Trim()

$constraintPattern = "member_sector_custom_name|sector_questionnaire|profile_question|member_questionnaire_response|member_question_answer"
$questionnaireConstraints = ($constraints | Where-Object { $_ -match $constraintPattern }) -join "`r`n"

$output = Join-Path $root 'migrations\006_v2_7_to_v2_8_industry_questionnaire.sql'
$content = @"
/*
OLGA Connect v2.7 -> v2.8: controlled industries and versioned member-profile questionnaires.

Run as the migration identity against an existing v2.7 development database. The script is
transactional, takes the shared migration lock, is rerunnable at v2.8, and does not delete member data.
*/
BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('olga_schema_migration', 0));

DO `$version_guard`$
DECLARE
    current_version text := obj_description('ops'::regnamespace, 'pg_namespace');
BEGIN
    IF current_version NOT IN ('OLGA.SchemaVersion=2.7', 'OLGA.SchemaVersion=2.8') THEN
        RAISE EXCEPTION 'Industry-questionnaire migration requires schema version 2.7 or 2.8; found %.',
            COALESCE(current_version, '<unset>');
    END IF;
END;
`$version_guard`$;

SET ROLE olga_ddl_admin;

-- The full setup drops this deployment-only helper after creating its constraints, so the
-- incremental migration recreates it transactionally and removes it again below.
$constraintHelper

ALTER TABLE core.member_sector
    ADD COLUMN IF NOT EXISTS custom_sector_name varchar(150) NULL;

$questionnaireTables

$questionnaireConstraints

DROP FUNCTION ops.add_constraint_if_missing(name, name, name, text);

DO `$audit_triggers`$
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
`$audit_triggers`$;

-- QA and early development databases used four short sector codes before the canonical API
-- taxonomy was approved. Reconcile only the exact known aliases and fail closed if a member or
-- child sector now depends on one of them. Organization.industry_code is textual, so update it too.
DO `$legacy_sector_aliases`$
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
`$legacy_sector_aliases`$;

$seed

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
DO `$questionnaire_sequence_privileges`$
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
`$questionnaire_sequence_privileges`$;

DO `$verify`$
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
`$verify`$;

COMMENT ON SCHEMA ops IS 'OLGA.SchemaVersion=2.8';
RESET ROLE;
COMMIT;
"@
$requiredFragments = @(
    'CREATE OR REPLACE FUNCTION ops.add_constraint_if_missing(',
    'DROP FUNCTION ops.add_constraint_if_missing(name, name, name, text);',
    "s.sector_code <> 'OTHER'",
    "('HEALTH'::varchar(64), 'HEALTHCARE'::varchar(64), 'Healthcare & Life Sciences'::varchar(150))",
    "pg_get_serial_sequence('core.sector_questionnaire', 'sector_questionnaire_id')",
    "pg_get_serial_sequence('core.profile_question', 'profile_question_id')",
    "pg_get_serial_sequence('core.sector_questionnaire_question', 'sector_questionnaire_question_id')",
    "pg_get_serial_sequence('core.member_questionnaire_response', 'member_questionnaire_response_id')",
    "pg_get_serial_sequence('core.member_question_answer', 'member_question_answer_id')",
    "COMMENT ON SCHEMA ops IS 'OLGA.SchemaVersion=2.8'"
)
foreach ($fragment in $requiredFragments) {
    if (-not $content.Contains($fragment, [System.StringComparison]::Ordinal)) {
        throw "Generated migration is missing required fragment: $fragment"
    }
}
if ($content -match 'core\.[a-z_]+_id_seq') {
    throw 'Generated migration contains a hardcoded identity-sequence name.'
}
if ($content.IndexOf('CREATE OR REPLACE FUNCTION ops.add_constraint_if_missing(', [System.StringComparison]::Ordinal) -gt
    $content.IndexOf('SELECT ops.add_constraint_if_missing(', [System.StringComparison]::Ordinal)) {
    throw 'Constraint helper is created after its first use.'
}
if ($content.IndexOf('DROP FUNCTION ops.add_constraint_if_missing', [System.StringComparison]::Ordinal) -lt
    $content.LastIndexOf('SELECT ops.add_constraint_if_missing(', [System.StringComparison]::Ordinal)) {
    throw 'Constraint helper is dropped before its final use.'
}
[System.IO.File]::WriteAllText($output, $content, [System.Text.UTF8Encoding]::new($false))
Write-Output $output
