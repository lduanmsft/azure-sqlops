[CmdletBinding()]
param(
    [string]$ConfigPath = 'config/miops.local.json'
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 or later is required.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required and was not found on PATH.'
}

$destination = if ([System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath
}
else {
    Join-Path $PSScriptRoot $ConfigPath
}
$source = Join-Path $PSScriptRoot 'config/miops.example.json'

if (Test-Path -LiteralPath $destination) {
    Write-Host "Configuration already exists; no file was changed: $destination"
}
else {
    $parent = Split-Path -Parent $destination
    $null = New-Item -ItemType Directory -Path $parent -Force
    Copy-Item -LiteralPath $source -Destination $destination
    Write-Host "Created local configuration: $destination"
}

Write-Host 'For guided Azure login, subscription/MI selection, and exact allowlist setup, run:'
Write-Host '  pwsh ./miops.ps1 setup'
Write-Host 'For manual configuration, replace the placeholder resource ID, run az login, then execute:'
Write-Host '  pwsh ./miops.ps1 preflight'
