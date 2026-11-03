[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputPath = Join-Path $root 'migrations\upgrade_v2_4_to_v2_9.sql'
$migrations = @(
    'migrations\003_v2_4_to_v2_5_profile_image.sql',
    'migrations\004_v2_5_to_v2_6_core_outbox_leasing.sql',
    'migrations\005_v2_6_to_v2_7_chat_outbox_contract.sql',
    'migrations\006_v2_7_to_v2_8_industry_questionnaire.sql',
    'migrations\007_v2_8_to_v2_9_social_capital_index.sql'
)

$parts = [System.Collections.Generic.List[string]]::new()
$parts.Add(@'
/*
OLGA Connect existing-database upgrade bundle: schema v2.4 -> v2.9.

Use this only when the database reports OLGA.SchemaVersion=2.4. Each contained
migration is transactional and advances the version before the next migration.
*/
'@)

foreach ($migration in $migrations) {
    $parts.Add("`r`n-- ======================== $migration ========================`r`n")
    $text = [System.IO.File]::ReadAllText((Join-Path $root $migration))
    $parts.Add($text.TrimEnd() + "`r`n")
}

[System.IO.File]::WriteAllText($outputPath, ($parts -join ''), [System.Text.UTF8Encoding]::new($false))
Write-Output $outputPath
