from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASELINE_FILES = [
    "001_schemas_sequences.sql", "010_tables.sql", "015_audit_history.sql", "020_constraints_indexes.sql", "025_invariants.sql",
    "030_views.sql", "040_procedures.sql", "050_seed.sql", "060_security.sql", "090_verify.sql",
]
EXPECTED_TABLES = {
    "core.community", "core.organization", "core.organization_member", "core.member_profile", "core.sector",
    "core.member_sector", "core.member_geography", "core.profile_field_visibility", "core.member_verification",
    "iam.member", "iam.member_identity", "iam.role", "iam.permission", "iam.role_permission", "iam.member_role",
    "iam.member_device", "iam.auth_session", "consent.consent_policy", "consent.member_consent",
    "consent.privacy_request", "consent.privacy_request_task", "event.venue", "event.event",
    "event.event_matching_policy", "event.event_registration", "event.live_mode_session", "event.event_presence",
    "social.connection_request", "social.connection", "social.member_block", "social.member_report",
    "chat.conversation", "chat.conversation_participant", "chat.message", "chat.message_receipt",
    "storage.file_asset", "storage.file_asset_link", "notification.notification_policy",
    "notification.notification_preference", "notification.push_token", "notification.notification",
    "notification.notification_delivery_attempt", "nlp.nlp_intent", "nlp.nlp_embedding", "nlp.nlp_model_version",
    "nlp.nlp_ranking_config", "nlp.nlp_processing_job", "nlp.match_request", "nlp.nlp_match_result",
    "nlp.nlp_feedback", "nlp.match_suppression", "nlp.evaluation_dataset", "nlp.evaluation_pair",
    "nlp.evaluation_run", "moderation.moderation_case", "moderation.moderation_action",
    "moderation.content_rule", "moderation.content_scan", "ops.outbox_event", "ops.idempotency_record",
    "ops.background_job", "ops.sync_change", "ops.retention_policy", "ops.retention_execution",
    "ops.audit_event", "analytics.product_event",
}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_tables(text: str) -> dict[str, set[str]]:
    result: dict[str, set[str]] = {}
    pattern = re.compile(r"CREATE TABLE IF NOT EXISTS ([a-z_]+\.[a-z_]+)\s*\((.*?)\n\s*\);", re.S)
    for match in pattern.finditer(text):
        columns = {
            column.group(1)
            for line in match.group(2).splitlines()
            if (column := re.match(r"\s*([a-z_][a-z0-9_]*)\s+[a-z]", line))
            and column.group(1).lower() != "constraint"
        }
        result[match.group(1)] = columns
    return result


def validate_delimiters(name: str, text: str) -> None:
    code = re.sub(r"--[^\n]*", "", text)
    code = re.sub(r"'(?:''|[^'])*'", "''", code)
    depth = 0
    for character in code:
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth < 0:
                fail(f"unbalanced closing parenthesis in {name}")
    if depth:
        fail(f"unbalanced parentheses in {name}: depth={depth}")
    for delimiter in set(re.findall(r"\$[a-z_]*\$", text, re.I)):
        if text.count(delimiter) % 2:
            fail(f"unbalanced dollar quote {delimiter} in {name}")


def main() -> None:
    texts = {name: (ROOT / name).read_text(encoding="utf-8") for name in BASELINE_FILES}
    for name, text in texts.items():
        validate_delimiters(name, text)
    combined = "\n".join([*texts.values(), (ROOT / "070_bind_identities.template.sql").read_text(encoding="utf-8")])
    tables = parse_tables(texts["010_tables.sql"])
    if set(tables) != EXPECTED_TABLES:
        fail(f"table inventory mismatch; missing={sorted(EXPECTED_TABLES-set(tables))}, extra={sorted(set(tables)-EXPECTED_TABLES)}")

    forbidden = re.compile(
        r"(?im)^\s*GO\s*$|\[[A-Za-z_][^]]*\]|\b(?:nvarchar|datetimeoffset|rowversion|varbinary|SYSUTCDATETIME|OBJECT_ID|SCHEMA_ID|CREATE OR ALTER|MERGE)\b|DECLARE\s+@|@@"
    )
    match = forbidden.search(combined)
    if match:
        fail(f"SQL Server syntax remains: {match.group(0)!r}")
    mixed_identifier = re.search(
        r"\b(?:core|iam|consent|event|social|chat|storage|notification|nlp|moderation|ops|analytics|admin)\.[A-Za-z0-9_]*[A-Z][A-Za-z0-9_]*",
        combined,
    )
    if mixed_identifier:
        fail(f"mixed-case PostgreSQL identifier remains: {mixed_identifier.group(0)!r}")

    foreign_keys = re.findall(
        r"add_constraint_if_missing\('([a-z_]+)', '([a-z_]+)', '[a-z0-9_]+', \$constraint\$FOREIGN KEY \(([a-z0-9_]+)\) REFERENCES ([a-z_]+\.[a-z_]+) \(([a-z0-9_]+)\)\$constraint\$\)",
        texts["020_constraints_indexes.sql"], re.I,
    )
    if len(foreign_keys) != 101:
        fail(f"unexpected foreign-key inventory: {len(foreign_keys)}")
    for source_schema, source_name, source_column, target_table, target_column in foreign_keys:
        source_table = f"{source_schema}.{source_name}"
        if source_column not in tables.get(source_table, set()):
            fail(f"foreign-key source does not exist: {source_table}.{source_column}")
        if target_column not in tables.get(target_table, set()):
            fail(f"foreign-key target does not exist: {target_table}.{target_column}")

    for index_name, table_name, expression in re.findall(
        r"CREATE (?:UNIQUE )?INDEX IF NOT EXISTS ([a-z0-9_]+) ON ([a-z_]+\.[a-z_]+) \(([^)]+)\)",
        texts["020_constraints_indexes.sql"], re.I,
    ):
        if table_name not in tables:
            fail(f"index {index_name} references missing table {table_name}")
        for column in re.findall(r"\b[a-z_][a-z0-9_]*\b", expression):
            if column.lower() not in {"asc", "desc"} and column not in tables[table_name]:
                fail(f"index {index_name} references missing column {table_name}.{column}")

    constraint_count = len(re.findall(r"^SELECT ops\.add_constraint_if_missing", texts["020_constraints_indexes.sql"], re.M))
    index_count = len(re.findall(r"^CREATE (?:UNIQUE )?INDEX IF NOT EXISTS", texts["020_constraints_indexes.sql"], re.M))
    if constraint_count != 174 or index_count != 175:
        fail(f"constraint/index inventory mismatch: constraints={constraint_count}, indexes={index_count}")

    if not re.search(r"embedding\s+vector\(1536\)\s+NOT NULL", texts["010_tables.sql"], re.I):
        fail("nlp_embedding.embedding is not vector(1536)")
    if "<=>" not in texts["040_procedures.sql"] or "AS MATERIALIZED" not in texts["040_procedures.sql"]:
        fail("candidate retrieval does not eligibility-bound exact cosine ranking")
    if re.search(r"USING\s+(?:hnsw|ivfflat)", combined, re.I):
        fail("approximate vector indexes are prohibited before load-test approval")
    if "p_max_rows NOT BETWEEN 50 AND 200" not in texts["040_procedures.sql"]:
        fail("candidate retrieval is not capped to the approved 50-200 range")
    if "SELECT m.member_id, CAST('GENERAL' AS varchar(64)) AS context_id" not in texts["030_views.sql"] or "m.community_id" not in texts["030_views.sql"]:
        fail("general matching eligibility does not carry the member community boundary")
    if "JOIN requester_scope requester ON requester.community_id = m.community_id" not in texts["040_procedures.sql"]:
        fail("candidate retrieval does not enforce requester/candidate community equality")
    if "AND eligibility.is_live" not in texts["040_procedures.sql"] or "AND eligibility.has_consent" not in texts["040_procedures.sql"]:
        fail("candidate retrieval does not fail closed when the requester is ineligible")
    if "s.intent_id IN (requester.intent_id, i.intent_id)" not in texts["040_procedures.sql"]:
        fail("intent-targeted requester/candidate suppressions are not enforced")
    if "ck_match_suppression_target" not in texts["020_constraints_indexes.sql"]:
        fail("match suppressions can be created without a bounded target")
    if texts["040_procedures.sql"].count("e.normalized_hash = i.normalized_hash") < 3:
        fail("matching reads can use embeddings for stale normalized intent text")
    if texts["040_procedures.sql"].count("mv.preprocessing_version = i.preprocessing_version") < 3:
        fail("matching reads can mix incompatible preprocessing versions")
    if "CREATE TRIGGER enforce_live_mode_session_consent" not in texts["025_invariants.sql"]:
        fail("Live Mode sessions are not protected by consent/event integrity enforcement")
    if "mc.member_id = NEW.member_id" not in texts["025_invariants.sql"] or "cp.purpose_code = 'LIVE_MODE'" not in texts["025_invariants.sql"]:
        fail("Live Mode consent is not bound to the same member and purpose")
    if "NEW.active_until > v_event_ends_at" not in texts["025_invariants.sql"]:
        fail("Live Mode session expiry is not bounded by the event")
    if re.search(r"\brow_version\s+(?!bigint NOT NULL DEFAULT 1)", texts["010_tables.sql"], re.I):
        fail("row_version is not trigger-managed bigint with default 1")
    for table_name, columns in tables.items():
        if "row_version" in columns and "updated_at" not in columns:
            fail(f"row_version resource lacks updated_at: {table_name}")
    for table_name in ("iam.member_identity", "iam.role", "event.venue"):
        if "status" not in tables[table_name]:
            fail(f"reusable resource lacks lifecycle status: {table_name}")
    if "CREATE SCHEMA IF NOT EXISTS history" not in texts["001_schemas_sequences.sql"]:
        fail("history schema is not created")
    if "CREATE TRIGGER set_audit_actor" not in texts["015_audit_history.sql"]:
        fail("database-sourced audit actor trigger is missing")
    if "CREATE TRIGGER versioning_history" not in texts["015_audit_history.sql"]:
        fail("system-period history trigger is missing")
    if "CREATE OR REPLACE FUNCTION ops.archive_row_version()" not in texts["015_audit_history.sql"] or "SECURITY DEFINER\nSET search_path = pg_catalog, ops" not in texts["015_audit_history.sql"]:
        fail("audit actor trigger is not secured")
    if "EXECUTE FUNCTION ops.archive_row_version" not in texts["015_audit_history.sql"]:
        fail("owned temporal history trigger is missing")
    if "ALTER FUNCTION versioning()" in texts["015_audit_history.sql"]:
        fail("Azure-owned extension functions must not be altered")
    if "v_old_row := to_jsonb(OLD)" not in texts["025_invariants.sql"] or "OLD.accepted_request_id" in texts["025_invariants.sql"]:
        fail("accepted-request deferred validation must use relation-safe trigger record extraction")
    if "NULLS NOT DISTINCT WHERE status = 'ACTIVE'" not in texts["020_constraints_indexes.sql"]:
        fail("global active notification policies are not null-safe unique")
    if "ux_push_token_fingerprint" not in texts["020_constraints_indexes.sql"] or re.search(
        r"CREATE .*INDEX.*\([^)]*ciphertext", texts["020_constraints_indexes.sql"], re.I
    ):
        fail("sensitive ciphertext indexing guard is missing")
    if len(re.findall(r"CREATE OR REPLACE VIEW ", texts["030_views.sql"], re.I)) != 4:
        fail("controlled-view count differs from the design")
    if len(re.findall(r"CREATE OR REPLACE FUNCTION (?:nlp|social|chat|event|notification)\.", texts["040_procedures.sql"], re.I)) != 9:
        fail("controlled-function count differs from the design")
    procedures = texts["040_procedures.sql"]
    invariants = texts["025_invariants.sql"]
    security = texts["060_security.sql"]
    role_setup = texts["001_schemas_sequences.sql"]
    if "PRIMARY KEY (scope, actor_id, idempotency_key)" not in texts["010_tables.sql"]:
        fail("idempotency keys are not scoped by authenticated actor")
    for operation in ("social.accept_connection_request", "chat.save_message", "chat.save_message_receipt"):
        if f"VALUES ('{operation}'" not in procedures:
            fail(f"atomic workflow does not claim idempotency for {operation}")
    if procedures.count("INSERT INTO ops.sync_change") < 3 or procedures.count("INSERT INTO ops.outbox_event") < 4:
        fail("connection/message/receipt workflows do not atomically write outbox and sync ledgers")
    if "CREATE CONSTRAINT TRIGGER validate_conversation_participant_set_on_conversation" not in invariants or "CREATE CONSTRAINT TRIGGER validate_conversation_participant_set_on_participant" not in invariants:
        fail("exact two-member conversation integrity is not deferred to transaction commit")
    if "CREATE TRIGGER enforce_message_receipt" not in invariants or "Last-read message cursor cannot move backwards" not in invariants:
        fail("receipt or read-cursor monotonicity enforcement is missing")
    expected_database_roles = {"olga_ddl_admin", "olga_dml_writer", "olga_reader", "olga_nlp_worker"}
    created_database_roles = set(re.findall(r"CREATE ROLE (olga_[a-z_]+)", role_setup, re.I))
    if created_database_roles != expected_database_roles:
        fail(f"database-role inventory mismatch: {sorted(created_database_roles)}")
    for required_grant in (
        "TO olga_dml_writer", "TO olga_reader", "FOR ROLE olga_ddl_admin"
    ):
        if required_grant not in security:
            fail(f"coarse-grained role grant is missing: {required_grant}")
    seed = texts["050_seed.sql"]
    for model_value in (
        "azure-text-embedding-3-small-1536-v1", "AZURE_OPENAI",
        "text-embedding-3-small", "normalizer-v1",
    ):
        if model_value not in seed:
            fail(f"active NLP model seed is missing: {model_value}")
    for worker_grant in (
        "GRANT SELECT ON nlp.nlp_intent, nlp.nlp_processing_job, nlp.nlp_embedding TO olga_nlp_worker",
        "ON nlp.nlp_intent TO olga_nlp_worker",
        "ON nlp.nlp_processing_job TO olga_nlp_worker",
        "GRANT INSERT, UPDATE ON nlp.nlp_embedding TO olga_nlp_worker",
        "GRANT INSERT ON ops.outbox_event TO olga_nlp_worker",
    ):
        if worker_grant not in security:
            fail(f"least-privilege NLP worker grant is missing: {worker_grant}")
    if re.search(r"GRANT\s+(?:ALL|SELECT, INSERT, UPDATE, DELETE).*SCHEMA nlp.*olga_nlp_worker", security, re.I):
        fail("NLP worker has unrestricted NLP schema access")

    full_setup = (ROOT / "OLGA_Connect_PostgreSQL_Full_Setup.sql").read_text(encoding="utf-8")
    for name, text in texts.items():
        if text.strip() not in full_setup:
            fail(f"standalone setup is stale relative to {name}")
    print(f"Static validation passed: {len(tables)} PostgreSQL tables; foreign keys, indexes, functions, and generated setup resolve.")


if __name__ == "__main__":
    main()
