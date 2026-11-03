# DBeaver deployment

## Prepare

1. Confirm the target is PostgreSQL 17.
2. Confirm `vector` and `pg_stat_statements` are present in the Azure `azure.extensions`
   allowlist.
3. Connect with the migration-owner identity and TLS certificate verification.
4. Verify the target before deployment:

```sql
SELECT current_database(), current_user, version();
```

## Execute

Use **File → Open File** (`Ctrl+O`) or drag the file into DBeaver. Creating a new SQL editor opens
an empty script.

- For any correctly selected database, open `OLGA_Connect_PostgreSQL_Full_Setup.sql`.
- For the exact database name `olga_connect_dev`, `deploy_dbeaver.sql` adds a name guard.
- For the exact database name `olga_connect_prod`, `deploy_dbeaver_prd.sql` adds a name guard.

Associate the editor with the intended connection and use **Execute SQL Script** (`Alt+X`), not
single-statement execution. Result-set fetching may be disabled during the deployment.

For a new database, the generated setup creates the v2.4 baseline and then executes the ordered
v2.5 through v2.9 migrations in the same script. Do not execute the individual migration files
after the current full setup succeeds.

For an existing database, execute only the next migration from its reported schema version. In
particular, an existing v2.8 development database uses
`migrations/007_v2_8_to_v2_9_social_capital_index.sql`. Each migration is transactional,
rerunnable at its target version, and guarded against an unexpected starting version. Do not skip
a version.

An existing database that reports v2.4 because it ran only the older full setup may use
`migrations/upgrade_v2_4_to_v2_9.sql`, which contains migrations 003 through 007 in order. Do not
use that bundle from any other starting version.

Each baseline/upgrade section is transactional and runs its structural verification before
committing. If execution fails, choose Stop/Abort rather than Ignore, execute `ROLLBACK;`, correct
the cause, inspect the reported schema version, and resume with the next required migration.

## Confirm

Run with result fetching enabled:

```sql
SELECT
    current_database() AS database_name,
    obj_description('ops'::regnamespace, 'pg_namespace') AS schema_version,
    (
        SELECT count(*)
        FROM pg_trigger
        WHERE tgfoid = 'ops.archive_row_version()'::regprocedure
          AND NOT tgisinternal
          AND tgenabled <> 'D'
    ) AS history_trigger_count;
```

Expected schema version after the ordered migrations: `OLGA.SchemaVersion=2.9`. Expected
history-trigger count: `11`.

Run the rollback-only integration tests listed in the repository README only against a
development/test database.
