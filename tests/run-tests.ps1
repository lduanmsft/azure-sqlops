$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'src/MiOps.psm1') -Force

$script:passed = 0
$script:failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param([scriptblock]$Script, [string]$Message)
    try {
        & $Script
    }
    catch {
        return
    }
    throw $Message
}

function Test-Case {
    param([string]$Name, [scriptblock]$Test)
    try {
        & $Test
        $script:passed++
        Write-Host "PASS $Name" -ForegroundColor Green
    }
    catch {
        $script:failed++
        Write-Host "FAIL $Name - $($_.Exception.Message)" -ForegroundColor Red
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "miops-tests-$([Guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $tempRoot -Force

try {
    $resourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Sql/managedInstances/test-mi'
    $baseConfig = @{
        schemaVersion = 1
        resource = @{
            id = $resourceId
            allowedResourceIds = @($resourceId)
        }
        azure = @{
            managedInstanceApiVersion = '2023-08-01-preview'
            resourceHealthApiVersion = '2023-07-01-preview'
        }
        safety = @{
            defaultReadOnly = $true
            allowedLifecycleTiers = @('GeneralPurpose')
        }
        evidence = @{
            defaultLookbackHours = 24
            metricNames = @()
        }
        state = @{ directory = '.miops-test' }
        sqlDiagnostics = @{ enabled = $false; adapter = $null }
        support = @{ submissionEnabled = $false }
    }

    Test-Case 'valid config loads and resolves state path' {
        $path = Join-Path $tempRoot 'valid.json'
        $baseConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $config = Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot
        Assert-True ($config.resource.id -eq $resourceId) 'Configured resource was not loaded.'
        Assert-True ([System.IO.Path]::IsPathRooted($config.state.directory)) 'State path was not resolved.'
    }

    Test-Case 'config rejects resource outside allowlist' {
        $path = Join-Path $tempRoot 'not-allowed.json'
        $invalid = $baseConfig.Clone()
        $invalid.resource = @{
            id = $resourceId
            allowedResourceIds = @('/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Sql/managedInstances/other-mi')
        }
        $invalid | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        Assert-Throws { Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot } 'Config outside allowlist was accepted.'
    }

    Test-Case 'config rejects disabling default read-only safety' {
        $path = Join-Path $tempRoot 'unsafe.json'
        $unsafe = $baseConfig.Clone()
        $unsafe.safety = @{
            defaultReadOnly = $false
            allowedLifecycleTiers = @('GeneralPurpose')
        }
        $unsafe | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        Assert-Throws { Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot } 'Unsafe defaultReadOnly=false config was accepted.'
    }

    Test-Case 'config rejects an empty lifecycle tier allowlist' {
        $path = Join-Path $tempRoot 'empty-tiers.json'
        $unsafe = $baseConfig.Clone()
        $unsafe.safety = @{
            defaultReadOnly = $true
            allowedLifecycleTiers = @()
        }
        $unsafe | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        Assert-Throws { Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot } 'Empty lifecycle tier allowlist was accepted.'
    }

    Test-Case 'allowlist comparison is case insensitive and exact' {
        Assert-True (Test-MiOpsResourceAllowed -Config $baseConfig -ResourceId $resourceId.ToUpperInvariant()) 'Case-insensitive allowlist match failed.'
        Assert-True (-not (Test-MiOpsResourceAllowed -Config $baseConfig -ResourceId "$resourceId-extra")) 'Prefix resource incorrectly matched allowlist.'
    }

    Test-Case 'mutation defaults to dry-run and exact approval is required' {
        $dryRun = Assert-MiOpsMutationApproval -Config $baseConfig -ResourceId $resourceId
        Assert-True (-not $dryRun) 'Mutation without Apply should be dry-run.'
        Assert-Throws {
            Assert-MiOpsMutationApproval -Config $baseConfig -ResourceId $resourceId -Apply -ApproveResourceId 'wrong'
        } 'Incorrect approval resource was accepted.'
        Assert-True (Assert-MiOpsMutationApproval -Config $baseConfig -ResourceId $resourceId -Apply -ApproveResourceId $resourceId) 'Exact approval was rejected.'
    }

    Test-Case 'operation state persists and reloads' {
        $path = Join-Path $tempRoot 'operation-config.json'
        $baseConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $config = Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot
        $operation = [ordered]@{
            operationId = 'operation-1'
            resourceId = $resourceId
            status = 'Submitted'
            azureOperationId = $null
            accessToken = 'secret-value'
        }
        $savedPath = Save-MiOpsOperation -Config $config -Operation $operation
        $loaded = Get-MiOpsOperation -Config $config -OperationId 'operation-1'
        Assert-True (Test-Path $savedPath) 'Operation file was not created.'
        Assert-True ($loaded.status -eq 'Submitted') 'Operation status did not persist.'
        Assert-True ($null -eq $loaded.azureOperationId) 'Null operation fields did not persist.'
        Assert-True ($loaded.accessToken -eq '[REDACTED]') 'Operation secret was not redacted.'
    }

    Test-Case 'redaction removes secret fields and bearer tokens' {
        $input = @{
            password = 'super-secret'
            message = 'Authorization: Bearer abc.def.ghi'
            nested = @{ connectionString = 'Server=tcp:test;Password=secret' }
        }
        $redacted = ConvertTo-MiOpsRedactedObject -InputObject $input
        Assert-True ($redacted.password -eq '[REDACTED]') 'Password field was not redacted.'
        Assert-True ($redacted.nested.connectionString -eq '[REDACTED]') 'Connection string field was not redacted.'
        Assert-True ($redacted.message -notmatch 'abc\.def\.ghi') 'Bearer token was not redacted.'
    }

    Test-Case 'dry-run operations cannot be polled as verified' {
        $path = Join-Path $tempRoot 'dry-run-config.json'
        $baseConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $config = Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot
        $operation = [ordered]@{
            operationId = 'dry-run-operation'
            resourceId = $resourceId
            desiredState = 'Ready'
            status = 'DryRun'
        }
        $null = Save-MiOpsOperation -Config $config -Operation $operation
        Assert-Throws {
            Update-MiOpsOperation -Config $config -OperationId 'dry-run-operation'
        } 'Dry-run operation was allowed to enter verification polling.'
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

Write-Host "$script:passed passed; $script:failed failed"
if ($script:failed -gt 0) {
    exit 1
}
