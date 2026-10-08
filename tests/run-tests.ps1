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

function Assert-ThrowsLike {
    param([scriptblock]$Script, [string]$Pattern, [string]$Message)
    try {
        & $Script
    }
    catch {
        if ($_.Exception.Message -like $Pattern) {
            return
        }
        throw "$Message Actual: $($_.Exception.Message)"
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

    Test-Case 'tenant and subscription identifiers are validated' {
        Assert-True (Test-MiOpsTenantId -TenantId 'fdpo.onmicrosoft.com') 'Tenant domain was rejected.'
        Assert-True (Test-MiOpsTenantId -TenantId '11111111-1111-1111-1111-111111111111') 'Tenant GUID was rejected.'
        Assert-True (-not (Test-MiOpsTenantId -TenantId 'not a tenant')) 'Invalid tenant was accepted.'
        Assert-True (Test-MiOpsSubscriptionId -SubscriptionId '22222222-2222-2222-2222-222222222222') 'Subscription GUID was rejected.'
        Assert-True (-not (Test-MiOpsSubscriptionId -SubscriptionId 'production-subscription')) 'Subscription name was accepted as an ID.'
    }

    Test-Case 'tenant choices use core account subscription metadata' {
        $subscriptions = @(
            [pscustomobject]@{
                id = '22222222-2222-2222-2222-222222222222'
                tenantId = '11111111-1111-1111-1111-111111111111'
                tenantDefaultDomain = 'fdpo.onmicrosoft.com'
                tenantDisplayName = 'Example tenant'
            },
            [pscustomobject]@{
                id = '33333333-3333-3333-3333-333333333333'
                tenantId = '11111111-1111-1111-1111-111111111111'
                tenantDefaultDomain = 'fdpo.onmicrosoft.com'
                tenantDisplayName = 'Example tenant'
            }
        )
        $tenants = @(ConvertTo-MiOpsTenantChoices -Subscriptions $subscriptions)
        Assert-True ($tenants.Count -eq 1) 'Subscriptions from one tenant produced duplicate tenant choices.'
        Assert-True ($tenants[0].defaultDomain -eq 'fdpo.onmicrosoft.com') 'Tenant domain metadata was not preserved.'
    }

    Test-Case 'tenant choices tolerate missing optional metadata' {
        $subscriptions = @(
            [pscustomobject]@{
                id = '22222222-2222-2222-2222-222222222222'
                tenantId = '11111111-1111-1111-1111-111111111111'
                state = 'Enabled'
            }
        )
        $tenants = @(ConvertTo-MiOpsTenantChoices -Subscriptions $subscriptions)
        Assert-True ($tenants.Count -eq 1) 'GUID-only tenant was not returned.'
        Assert-True ($tenants[0].tenantId -eq '11111111-1111-1111-1111-111111111111') 'Tenant GUID was not preserved.'
        Assert-True ([string]::IsNullOrEmpty($tenants[0].defaultDomain)) 'Missing tenant domain was not represented safely.'
        Assert-True ([string]::IsNullOrEmpty($tenants[0].displayName)) 'Missing tenant display name was not represented safely.'
    }

    Test-Case 'GUID-only tenant matching does not require domain metadata' {
        $tenants = @([pscustomobject]@{
            tenantId = '11111111-1111-1111-1111-111111111111'
            defaultDomain = ''
            displayName = ''
        })
        $tenant = Resolve-MiOpsTenant -TenantId '11111111-1111-1111-1111-111111111111' -Tenants $tenants
        Assert-True ($tenant.tenantId -eq '11111111-1111-1111-1111-111111111111') 'GUID-only tenant matching failed.'
    }

    Test-Case 'domain resolution failure lists actionable tenant GUIDs' {
        $tenants = @([pscustomobject]@{
            tenantId = '11111111-1111-1111-1111-111111111111'
            defaultDomain = ''
            displayName = ''
        })
        Assert-ThrowsLike {
            Resolve-MiOpsTenant -TenantId 'fdpo.onmicrosoft.com' -Tenants $tenants
        } '*Available tenant GUIDs/domains: 11111111-1111-1111-1111-111111111111*Retry with the tenant GUID shown*' 'Domain resolution failure was not actionable.'
    }

    Test-Case 'numbered selection validates bounds and supports cancellation' {
        $items = @(
            [pscustomobject]@{ name = 'first' },
            [pscustomobject]@{ name = 'second' }
        )
        Assert-True ((Select-MiOpsNumberedItem -Items $items -Selection '2').name -eq 'second') 'Numbered selection chose the wrong item.'
        Assert-True ($null -eq (Select-MiOpsNumberedItem -Items $items -Selection '0')) 'Cancellation did not return null.'
        Assert-Throws { Select-MiOpsNumberedItem -Items $items -Selection '3' } 'Out-of-range selection was accepted.'
        Assert-Throws { Select-MiOpsNumberedItem -Items $items -Selection 'one' } 'Non-numeric selection was accepted.'
    }

    Test-Case 'Managed Instance selection preserves the discovered resource' {
        $instances = @(
            [pscustomobject]@{ name = 'mi-one'; id = "$resourceId-one" },
            [pscustomobject]@{ name = 'mi-two'; id = $resourceId }
        )
        $selected = Select-MiOpsNumberedItem -Items $instances -Selection '2'
        Assert-True ($selected.name -eq 'mi-two') 'Managed Instance name was not selected.'
        Assert-True ($selected.id -eq $resourceId) 'Managed Instance resource ID changed during selection.'
    }

    Test-Case 'local config generation sets one exact allowlisted resource' {
        $destination = Join-Path $tempRoot 'generated\miops.local.json'
        $example = Join-Path $repositoryRoot 'config\miops.example.json'
        $config = New-MiOpsLocalConfig -ExamplePath $example -DestinationPath $destination `
            -ResourceId $resourceId -TenantId '11111111-1111-1111-1111-111111111111' `
            -SubscriptionId '00000000-0000-0000-0000-000000000000'
        Assert-True (Test-Path -LiteralPath $destination) 'Local config was not created.'
        Assert-True ($config.resource.id -eq $resourceId) 'Generated resource.id is incorrect.'
        Assert-True ($config.resource.allowedResourceIds.Count -eq 1) 'Generated allowlist must contain exactly one resource.'
        Assert-True ($config.resource.allowedResourceIds[0] -eq $resourceId) 'Generated allowlist resource is incorrect.'
        Assert-True ($config.onboarding.subscriptionId -eq '00000000-0000-0000-0000-000000000000') 'Subscription metadata was not stored.'
        Assert-True ((Get-Content -LiteralPath $example -Raw) -notmatch 'test-mi') 'Checked-in example was modified.'
    }

    Test-Case 'typed mutation confirmation is action and MI specific' {
        Assert-True (Test-MiOpsTypedConfirmation -Action START -ManagedInstanceName 'test-mi' -Confirmation 'START test-mi') 'Exact start confirmation was rejected.'
        Assert-True (-not (Test-MiOpsTypedConfirmation -Action START -ManagedInstanceName 'test-mi' -Confirmation 'STOP test-mi')) 'Wrong action confirmation was accepted.'
        Assert-True (-not (Test-MiOpsTypedConfirmation -Action STOP -ManagedInstanceName 'test-mi' -Confirmation 'STOP other-mi')) 'Wrong MI confirmation was accepted.'
        Assert-True (-not (Test-MiOpsTypedConfirmation -Action STOP -ManagedInstanceName 'test-mi' -Confirmation 'stop test-mi')) 'Case-changed confirmation was accepted.'
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
