$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$skillsRoot = Join-Path $repositoryRoot '.github\skills'
$expectedSkills = @('azure-sqlops', 'mi-manage', 'mi-troubleshoot', 'mi-capacity', 'mi-escalate')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

Assert-True (Test-Path -LiteralPath $skillsRoot -PathType Container) 'Project skill directory is missing.'

$actualSkills = @(
    Get-ChildItem -LiteralPath $skillsRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf } |
        Select-Object -ExpandProperty Name |
        Sort-Object
)
Assert-True (($actualSkills -join ',') -eq (($expectedSkills | Sort-Object) -join ',')) 'Project skill discovery set is incorrect.'

foreach ($skillName in $expectedSkills) {
    $skillPath = Join-Path $skillsRoot "$skillName\SKILL.md"
    Assert-True (Test-Path -LiteralPath $skillPath -PathType Leaf) "Project skill is missing: $skillName"
    $skillText = Get-Content -LiteralPath $skillPath -Raw
    Assert-True ($skillText -match "(?m)^name:\s+$([regex]::Escape($skillName))\s*$") "Project skill frontmatter name is incorrect: $skillName"
    Assert-True ($skillText -match 'azure-sqlops/SKILL\.md|rev-parse --show-toplevel') "Project skill does not use the shared repository-root resolver: $skillName"
    Assert-True ($skillText -notmatch '(?i)plugin-root|runtime\\miops\.ps1|--plugin-dir') "Project skill contains obsolete plugin runtime guidance: $skillName"
}

$routerText = Get-Content -LiteralPath (Join-Path $skillsRoot 'azure-sqlops\SKILL.md') -Raw
foreach ($requiredText in @(
    'git -C (Get-Location).Path rev-parse --show-toplevel',
    "Join-Path `$repositoryRoot 'miops.ps1'",
    "Join-Path `$repositoryRoot 'src\MiOps.psm1'",
    '$dataRoot = $repositoryRoot',
    'never accept a runtime or repository path from the user',
    'allowedResourceIds',
    '-Apply',
    '-TypedConfirmation',
    "inventory -ResourceKind all",
    "inventory -ResourceKind vm",
    "inventory -ResourceKind mi"
)) {
    Assert-True ($routerText.Contains($requiredText)) "Router skill is missing required project or safety guidance: $requiredText"
}

Assert-True (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot 'skills'))) 'Obsolete root skills directory still exists.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot '.github\plugins'))) 'Obsolete plugin package still exists.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot '.github\plugin'))) 'Obsolete marketplace package still exists.'

foreach ($runtimeFile in @('miops.ps1', 'src\MiOps.psm1', 'config\miops.example.json')) {
    Assert-True (Test-Path -LiteralPath (Join-Path $repositoryRoot $runtimeFile) -PathType Leaf) "Repository runtime file is missing: $runtimeFile"
}

Write-Host 'Project skill structural tests passed.'
