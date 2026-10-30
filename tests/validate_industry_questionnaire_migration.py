from pathlib import Path
import re


root = Path(__file__).resolve().parents[1]
migration = (root / "migrations/006_v2_7_to_v2_8_industry_questionnaire.sql").read_text(encoding="utf-8")
seed = (root / "055_industry_questionnaire_seed.sql").read_text(encoding="utf-8")
full_setup = (root / "OLGA_Connect_PostgreSQL_Full_Setup.sql").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"ERROR: {message}")


require(len(re.findall(r"^BEGIN;$", migration, re.MULTILINE)) == 1, "migration must have one transaction start")
require(len(re.findall(r"^COMMIT;$", migration, re.MULTILINE)) == 1, "migration must have one transaction commit")
helper_create = migration.index("CREATE OR REPLACE FUNCTION ops.add_constraint_if_missing(")
first_helper_use = migration.index("SELECT ops.add_constraint_if_missing(")
helper_drop = migration.index("DROP FUNCTION ops.add_constraint_if_missing(name, name, name, text);")
last_helper_use = migration.rindex("SELECT ops.add_constraint_if_missing(")
require(helper_create < first_helper_use, "constraint helper is created after its first use")
require(helper_drop > last_helper_use, "constraint helper is dropped before its last use")

require(not re.search(r"core\.[a-z_]+_id_seq", migration), "hardcoded identity sequence name remains")
require(migration.count("pg_get_serial_sequence('") == 5, "all five identity sequences must be resolved dynamically")
require("s.sector_code <> 'OTHER'" in migration, "OTHER must not be automatically backfilled without a custom label")
require(migration.count("CREATE TABLE IF NOT EXISTS core.") == 5, "migration must create five questionnaire tables")
require("OLGA.SchemaVersion=2.7" in migration and "OLGA.SchemaVersion=2.8" in migration, "schema-version guard is incomplete")
require("COMMENT ON SCHEMA ops IS 'OLGA.SchemaVersion=2.8';" in migration, "final schema version is missing")

for delimiter in set(re.findall(r"\$[a-z_]*\$", migration, re.IGNORECASE)):
    require(migration.count(delimiter) % 2 == 0, f"unbalanced dollar quote {delimiter}")

sector_rows = len(re.findall(r"^\s*\('[A-Z_]+',NULL,", seed, re.MULTILINE))
question_rows = len(re.findall(r"^\s*\('q_", seed, re.MULTILINE))
require(sector_rows == 17, f"expected 17 seeded sectors, found {sector_rows}")
require(question_rows == 57, f"expected 57 seeded questions, found {question_rows}")
require(seed.strip() in full_setup, "full setup is stale relative to questionnaire seed")

print("Industry questionnaire migration static validation passed.")
