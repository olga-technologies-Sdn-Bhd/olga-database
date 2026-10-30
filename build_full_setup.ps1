[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$output = Join-Path $root 'OLGA_Connect_PostgreSQL_Full_Setup.sql'
$sections = @(
    @{ Label = 'SCHEMAS AND SEQUENCES'; File = '001_schemas_sequences.sql' },
    @{ Label = 'TABLES'; File = '010_tables.sql' },
    @{ Label = 'AUDIT ATTRIBUTION AND TEMPORAL HISTORY'; File = '015_audit_history.sql' },
    @{ Label = 'CONSTRAINTS AND INDEXES'; File = '020_constraints_indexes.sql' },
    @{ Label = 'CROSS-ROW INVARIANTS'; File = '025_invariants.sql' },
    @{ Label = 'CONTROLLED VIEWS'; File = '030_views.sql' },
    @{ Label = 'CONTROLLED FUNCTIONS'; File = '040_procedures.sql' },
    @{ Label = 'REFERENCE DATA'; File = '050_seed.sql' },
    @{ Label = 'INDUSTRY QUESTIONNAIRE REFERENCE DATA'; File = '055_industry_questionnaire_seed.sql' },
    @{ Label = 'DATABASE ROLES AND GRANTS'; File = '060_security.sql' },
    @{ Label = 'VERIFICATION'; File = '090_verify.sql' }
)
$parts = [System.Collections.Generic.List[string]]::new()
$parts.Add(@'
/*
OLGA Connect Release 1 - PostgreSQL full database setup
Architecture baseline: Database Architecture and Table-Level Design v2.3 + auditability hardening v2.4
Implementation baseline: MVP Architecture Implementation Guide v1.0
Target: a new, empty PostgreSQL 17 database

This transactional script never drops product tables. Provisional QA notification-policy
seeding remains fail-closed until product and security approve it.
*/
'@)
foreach ($section in $sections) {
    $parts.Add("`r`n-- ======================== $($section.Label) ========================`r`n")
    $text = [System.IO.File]::ReadAllText((Join-Path $root $section.File))
    $parts.Add($text.TrimEnd() + "`r`n")
}
[System.IO.File]::WriteAllText($output, ($parts -join ''), [System.Text.UTF8Encoding]::new($false))
Write-Output $output
