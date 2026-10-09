[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$pluginRoot = Join-Path $repositoryRoot '.github\plugins\azure-sqlops'

$files = [ordered]@{
    'miops.ps1' = 'runtime\miops.ps1'
    'src\MiOps.psm1' = 'runtime\src\MiOps.psm1'
    'config\miops.example.json' = 'runtime\config\miops.example.json'
    'LICENSE' = 'LICENSE'
    'skills\azure-sqlops\SKILL.md' = 'skills\azure-sqlops\SKILL.md'
    'skills\mi-manage\SKILL.md' = 'skills\mi-manage\SKILL.md'
    'skills\mi-troubleshoot\SKILL.md' = 'skills\mi-troubleshoot\SKILL.md'
    'skills\mi-capacity\SKILL.md' = 'skills\mi-capacity\SKILL.md'
    'skills\mi-escalate\SKILL.md' = 'skills\mi-escalate\SKILL.md'
}

$outOfSync = @()
foreach ($entry in $files.GetEnumerator()) {
    $source = Join-Path $repositoryRoot $entry.Key
    $destination = Join-Path $pluginRoot $entry.Value
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Plugin source file not found: $source"
    }

    if ($Check) {
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            $outOfSync += $entry.Value
            continue
        }
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if ($sourceHash -ne $destinationHash) {
            $outOfSync += $entry.Value
        }
        continue
    }

    $parent = Split-Path -Parent $destination
    $null = New-Item -ItemType Directory -Path $parent -Force
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

if ($Check -and $outOfSync.Count -gt 0) {
    throw "Plugin package is out of sync: $($outOfSync -join ', '). Run pwsh -NoProfile -File .\scripts\sync-plugin.ps1."
}

if ($Check) {
    Write-Host 'Plugin package is synchronized.'
}
else {
    Write-Host "Synchronized $($files.Count) files into $pluginRoot."
}
