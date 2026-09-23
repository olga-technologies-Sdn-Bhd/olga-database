# OLGA Connect PostgreSQL database

PostgreSQL 17 baseline for OLGA Connect Release 1 on Azure Database for PostgreSQL Flexible
Server. Physical identifiers use lower_snake_case and the database is organized by bounded domain
schemas inside one database.

## Repository contents

- `001_schemas_sequences.sql` through `090_verify.sql`: ordered, maintainable schema source.
- `build_full_setup.ps1`: rebuilds the standalone setup from the ordered source modules.
- `OLGA_Connect_PostgreSQL_Full_Setup.sql`: generated, transactional setup for a new database.
- `deploy_dbeaver.sql` and `deploy_dbeaver_prd.sql`: optional DBeaver database-name guards for
  `olga_connect_dev` and `olga_connect_prod`.
- `migrate_dev_roles.sql`: one-time, data-preserving migration from the former service roles to
  `olga_ddl_admin`, `olga_dml_writer`, `olga_reader`, and `olga_nlp_worker` in an existing
  development database.
- `070_bind_identities.template.sql`: non-executable reference for pre-provisioned Azure identities.
- `bind_nlp_identities.sql`: guarded one-time identity-membership script for the environment's NLP
  API and worker managed identities. It aborts before granting if an expected role is absent.
- `deploy_nlp_runtime.sql`: guarded, rerunnable manual upgrade for the active embedding model and
  least-privilege NLP worker role in either approved database.
- `tests/validate_static.py`: static consistency and architecture validation.
- `tests/seed_test_data.sql`: rerunnable development/test fixture with at least one coherent row in
  every application table; never run it in production.
- `tests/verify_chat_atomicity.sql` and `tests/verify_temporal_history.sql`: rollback-only
  integration tests for a development/test database.
- `docs/dbeaver-deployment.md`: concise deployment and recovery runbook.
- `docs/database-requirements-and-table-guide.md`: team guide to product requirements, table purposes,
  relationships and protected workflows.
- `docs/architecture-decisions-v2.4.md`: security, lifecycle, history and matching decisions that
  are not self-evident from the DDL.

## Prerequisites

- PostgreSQL 17.
- The `vector` and `pg_stat_statements` extensions allowlisted on the Azure server.
- A migration identity permitted to create schemas, extensions, `NOLOGIN` roles, tables, functions
  and grants. The setup grants this identity membership in `olga_ddl_admin` and creates all OLGA
  objects under that owner role.
- TLS certificate verification configured in the database client.

## Deploy

Follow [the DBeaver runbook](docs/dbeaver-deployment.md). The normal deployment artifact is
`OLGA_Connect_PostgreSQL_Full_Setup.sql`; execute it as a script, not as individual statements.

`070_bind_identities.template.sql` is a non-executable reference and is intentionally excluded from
the baseline. After the Azure managed identities have been mapped into PostgreSQL, execute the
`bind_nlp_identities.sql` script. It only adds NLP API/worker memberships and does not modify other
roles.

For a database that already has the baseline, execute `deploy_nlp_runtime.sql` manually. It checks
the database name, takes the migration advisory lock, applies the model/worker delta
transactionally, and verifies the resulting privilege boundary.

For a development database deployed with the former 13 service roles, run
`migrate_dev_roles.sql` once as its existing migration owner. It preserves data and removes those
obsolete roles after transferring ownership and privileges.

## Maintain

Edit the numbered source modules, not the generated full-setup file. Rebuild it afterward:

```powershell
.\build_full_setup.ps1
```

Then run:

```powershell
& '<approved-python>' .\tests\validate_static.py
```

The validator confirms the 66-table inventory, PostgreSQL-native types, constraints, indexes,
controlled functions and that the generated setup contains every current source module.

## Database verification

`090_verify.sql` is included at the end of the full setup. A failed check aborts the deployment
transaction.

On development/test only, execute these with a migration-owner connection:

1. `tests/seed_test_data.sql` to populate persistent development/test fixture data (optional).
2. `tests/verify_temporal_history.sql`
3. `tests/verify_chat_atomicity.sql`

The verification tests are self-contained and finish with `ROLLBACK`; the seed script commits its
fixture rows and is safe to rerun.

## Guardrails

- Domain schemas are namespaces and permission boundaries within one transactional database.
- Mutable API resources use trigger-managed `bigint row_version` values for ETags.
- Internal numeric keys use identity columns; external IDs remain opaque `varchar(64)`.
- Sensitive ciphertext uses `bytea`; business timestamps use `timestamptz`.
- NLP embeddings use `vector(1536)`; matching applies eligibility first and exact cosine distance
  to a bounded candidate set. ANN indexes are intentionally absent.
- Connection, chat and receipt mutations use actor-scoped idempotency, transactional outbox and
  member-scoped synchronization records.
- The owned system-period trigger writes selected reference/configuration history without granting
  application roles direct access to history tables.
