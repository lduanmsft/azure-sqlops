[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet(
        'preflight',
        'status',
        'start',
        'stop',
        'operation-poll',
        'schedule-show',
        'schedule-plan',
        'schedule-delete',
        'evidence',
        'support-draft',
        'sql-adapter-status'
    )]
    [string]$Command,

    [string]$ConfigPath = 'config/miops.local.json',
    [string]$OperationId,
    [string]$EvidencePath,
    [string]$Title = 'Azure SQL Managed Instance incident',
    [string]$Impact = 'Describe the customer or business impact.',
    [int]$LookbackHours,
    [switch]$Apply,
    [string]$ApproveResourceId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/MiOps.psm1') -Force

$resolvedConfigPath = if ([System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath
}
else {
    Join-Path $PSScriptRoot $ConfigPath
}

$config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $PSScriptRoot

switch ($Command) {
    'preflight' {
        Invoke-MiOpsPreflight -Config $config
    }
    'status' {
        Get-MiOpsStatus -Config $config
    }
    'start' {
        Invoke-MiOpsLifecycle -Config $config -Action Start -Apply:$Apply -ApproveResourceId $ApproveResourceId
    }
    'stop' {
        Invoke-MiOpsLifecycle -Config $config -Action Stop -Apply:$Apply -ApproveResourceId $ApproveResourceId
    }
    'operation-poll' {
        if (-not $OperationId) {
            throw '-OperationId is required for operation-poll.'
        }
        Update-MiOpsOperation -Config $config -OperationId $OperationId
    }
    'schedule-show' {
        Get-MiOpsSchedule -Config $config
    }
    'schedule-plan' {
        New-MiOpsSchedulePlan -Config $config
    }
    'schedule-delete' {
        Remove-MiOpsSchedule -Config $config -Apply:$Apply -ApproveResourceId $ApproveResourceId
    }
    'evidence' {
        $arguments = @{ Config = $config }
        if ($LookbackHours -gt 0) {
            $arguments.LookbackHours = $LookbackHours
        }
        Get-MiOpsEvidence @arguments
    }
    'support-draft' {
        if (-not $EvidencePath) {
            throw '-EvidencePath is required for support-draft.'
        }
        $resolvedEvidencePath = if ([System.IO.Path]::IsPathRooted($EvidencePath)) {
            $EvidencePath
        }
        else {
            Join-Path $PSScriptRoot $EvidencePath
        }
        New-MiOpsSupportDraft -Config $config -EvidencePath $resolvedEvidencePath -Title $Title -Impact $Impact
    }
    'sql-adapter-status' {
        Get-MiOpsSqlAdapterStatus -Config $config
    }
}
