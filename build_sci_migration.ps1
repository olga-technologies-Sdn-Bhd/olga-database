[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$bodyPath = Join-Path $root '065_social_capital_index.sql'
$outputPath = Join-Path $root 'migrations\007_v2_8_to_v2_9_social_capital_index.sql'
$body = [System.IO.File]::ReadAllText($bodyPath).Trim()

$header = @'
/*
OLGA Connect v2.8 -> v2.9: ventures, imported-contact vault, invitation consent,
and the intent-gated Social Capital Index.

Run as the migration identity against an existing v2.8 development database. The
script is transactional, takes the shared migration lock, is rerunnable at v2.9,
and does not delete member data. The SCI scoring configuration is installed as
DRAFT and must not be activated until calibration is reviewed.
*/
BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('olga_schema_migration', 0));

DO $version_guard$
DECLARE
    current_version text := obj_description('ops'::regnamespace, 'pg_namespace');
BEGIN
    IF current_version NOT IN ('OLGA.SchemaVersion=2.8', 'OLGA.SchemaVersion=2.9') THEN
        RAISE EXCEPTION 'SCI migration requires schema version 2.8 or 2.9; found %.',
            COALESCE(current_version, '<unset>');
    END IF;
END;
$version_guard$;

SET ROLE olga_ddl_admin;
'@

$footer = @'

COMMENT ON SCHEMA ops IS 'OLGA.SchemaVersion=2.9';
RESET ROLE;
COMMIT;
'@

$content = $header.TrimEnd() + "`r`n`r`n" + $body + "`r`n" + $footer.TrimStart()
[System.IO.File]::WriteAllText($outputPath, $content, [System.Text.UTF8Encoding]::new($false))
Write-Output $outputPath
