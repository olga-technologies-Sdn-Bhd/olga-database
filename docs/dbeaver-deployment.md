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

The generated setup creates schema v2.4. After it commits successfully, execute these scripts in
order against the same database:

1. `migrations/003_v2_4_to_v2_5_profile_image.sql`
2. `migrations/004_v2_5_to_v2_6_core_outbox_leasing.sql`

Each migration is transactional, rerunnable at its target version, and guarded against an
unexpected starting version. Do not skip a version.

The script is transactional and runs its structural verification before committing. If execution
fails, choose Stop/Abort rather than Ignore, execute `ROLLBACK;`, correct the cause, reopen the
latest file and execute the complete script again.

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

Expected schema version after the ordered migrations: `OLGA.SchemaVersion=2.6`. Expected
history-trigger count: `11`.

Run the rollback-only integration tests listed in the repository README only against a
development/test database.
