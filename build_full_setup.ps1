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
    @{ Label = 'SOCIAL CAPITAL INDEX'; File = '065_social_capital_index.sql' },
    @{ Label = 'VERIFICATION'; File = '090_verify.sql' }
)
$upgrades = @(
    @{ Label = 'UPGRADE V2.4 TO V2.5 - PROFILE IMAGE'; File = 'migrations\003_v2_4_to_v2_5_profile_image.sql' },
    @{ Label = 'UPGRADE V2.5 TO V2.6 - CORE OUTBOX LEASING'; File = 'migrations\004_v2_5_to_v2_6_core_outbox_leasing.sql' },
    @{ Label = 'UPGRADE V2.6 TO V2.7 - CHAT OUTBOX CONTRACT'; File = 'migrations\005_v2_6_to_v2_7_chat_outbox_contract.sql' },
    @{ Label = 'UPGRADE V2.7 TO V2.8 - INDUSTRY QUESTIONNAIRE'; File = 'migrations\006_v2_7_to_v2_8_industry_questionnaire.sql' },
    @{ Label = 'UPGRADE V2.8 TO V2.9 - SOCIAL CAPITAL INDEX'; File = 'migrations\007_v2_8_to_v2_9_social_capital_index.sql' }
)
$parts = [System.Collections.Generic.List[string]]::new()
$parts.Add(@'
/*
OLGA Connect Release 1 - PostgreSQL full database setup
Architecture baseline: Database Architecture and Table-Level Design v2.3 + auditability hardening v2.4
Implementation baseline: MVP Architecture Implementation Guide v1.0
Current schema: OLGA.SchemaVersion=2.9
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
foreach ($upgrade in $upgrades) {
    $parts.Add("`r`n-- ======================== $($upgrade.Label) ========================`r`n")
    $text = [System.IO.File]::ReadAllText((Join-Path $root $upgrade.File))
    $parts.Add($text.TrimEnd() + "`r`n")
}
[System.IO.File]::WriteAllText($output, ($parts -join ''), [System.Text.UTF8Encoding]::new($false))
Write-Output $output
