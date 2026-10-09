$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$pluginRoot = Join-Path $repositoryRoot '.github\plugins\azure-sqlops'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

$marketplacePath = Join-Path $repositoryRoot '.github\plugin\marketplace.json'
$manifestPath = Join-Path $pluginRoot '.plugin\plugin.json'
$marketplace = Get-Content -LiteralPath $marketplacePath -Raw | ConvertFrom-Json -Depth 20
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 20

Assert-True ($marketplace.name -eq 'azure-sqlops') 'Marketplace name is incorrect.'
Assert-True ($marketplace.plugins.Count -eq 1) 'Marketplace must expose exactly one plugin.'
Assert-True ($marketplace.plugins[0].source -eq './.github/plugins/azure-sqlops') 'Marketplace plugin source is incorrect.'

foreach ($field in @('name', 'description', 'version', 'author', 'repository', 'license', 'keywords', 'skills')) {
    Assert-True ($null -ne $manifest.$field) "Plugin manifest is missing '$field'."
}
Assert-True ($manifest.name -eq 'azure-sqlops') 'Plugin manifest name is incorrect.'
Assert-True ($manifest.license -eq 'MIT') 'Plugin manifest must declare MIT.'
Assert-True ($manifest.skills -eq './skills/') 'Plugin skills path is incorrect.'
Assert-True ($marketplace.plugins[0].version -eq $manifest.version) 'Marketplace and plugin versions differ.'

$expectedSkills = @('azure-sqlops', 'mi-manage', 'mi-troubleshoot', 'mi-capacity', 'mi-escalate')
foreach ($skillName in $expectedSkills) {
    $skillPath = Join-Path $pluginRoot "skills\$skillName\SKILL.md"
    Assert-True (Test-Path -LiteralPath $skillPath -PathType Leaf) "Bundled skill is missing: $skillName"
    $skillText = Get-Content -LiteralPath $skillPath -Raw
    Assert-True ($skillText -match "(?m)^name:\s+$([regex]::Escape($skillName))\s*$") "Bundled skill frontmatter name is incorrect: $skillName"
}

foreach ($runtimeFile in @('runtime\miops.ps1', 'runtime\src\MiOps.psm1', 'runtime\config\miops.example.json')) {
    Assert-True (Test-Path -LiteralPath (Join-Path $pluginRoot $runtimeFile) -PathType Leaf) "Bundled runtime file is missing: $runtimeFile"
}

& (Join-Path $repositoryRoot 'scripts\sync-plugin.ps1') -Check

$runtimeText = Get-Content -LiteralPath (Join-Path $pluginRoot 'runtime\miops.ps1') -Raw
Assert-True ($runtimeText -match '\[string\]\$DataRoot') 'Bundled runtime does not expose an explicit data root.'
Assert-True ($runtimeText -match '\[string\]\$TypedConfirmation') 'Bundled runtime does not expose deterministic typed confirmation.'
Assert-True ($runtimeText -match 'Assert-MiOpsMutationApproval|Invoke-MiOpsLifecycle') 'Bundled runtime is missing deterministic lifecycle dispatch.'

Write-Host 'Plugin structural tests passed.'
