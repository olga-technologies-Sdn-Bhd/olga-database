/*
OLGA Connect - DBeaver Community production deployment entry point

Safety rule: this script runs only when the active database is olga_connect_prod.
Run this file with Execute SQL Script (Alt+X), not Execute SQL Statement.
*/
DO $deployment_guard$
BEGIN
    IF current_database() <> 'olga_connect_prod' THEN
        RAISE EXCEPTION
            'Production deployment stopped: connected to database %, expected olga_connect_prod.',
            current_database();
    END IF;
END;
$deployment_guard$;

SELECT current_database() AS deployment_database,
       current_user AS deployment_user,
       version() AS server_version;

@include OLGA_Connect_PostgreSQL_Full_Setup.sql
