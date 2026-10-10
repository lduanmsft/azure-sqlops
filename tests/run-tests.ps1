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

    Test-Case 'inventory selector rejects arbitrary resource kinds' {
        Assert-Throws {
            Get-MiOpsInventoryQuery -ResourceKind 'Microsoft.Compute/disks' -SubscriptionId '00000000-0000-0000-0000-000000000000'
        } 'Arbitrary inventory resource kind was accepted.'
    }

    Test-Case 'inventory queries use fixed Azure CLI arguments' {
        $subscriptionId = '00000000-0000-0000-0000-000000000000'
        $allQuery = @(Get-MiOpsInventoryQuery -ResourceKind all -SubscriptionId $subscriptionId)
        $vmQuery = @(Get-MiOpsInventoryQuery -ResourceKind vm -SubscriptionId $subscriptionId)
        $miQuery = @(Get-MiOpsInventoryQuery -ResourceKind mi -SubscriptionId $subscriptionId)
        Assert-True (($allQuery -join ' ') -eq "resource list --subscription $subscriptionId") 'All-resource query changed from the fixed command.'
        Assert-True (($vmQuery -join ' ') -eq "resource list --subscription $subscriptionId --resource-type Microsoft.Compute/virtualMachines") 'VM query changed from the fixed resource type.'
        Assert-True (($miQuery -join ' ') -eq "sql mi list --subscription $subscriptionId") 'MI inventory did not reuse the fixed MI enumeration command.'
    }

    Test-Case 'inventory context enforces configured tenant and subscription' {
        $configured = $baseConfig.Clone()
        $configured.onboarding = @{
            tenantId = '11111111-1111-1111-1111-111111111111'
            subscriptionId = '00000000-0000-0000-0000-000000000000'
        }
        $account = [pscustomobject]@{
            id = '00000000-0000-0000-0000-000000000000'
            tenantId = '11111111-1111-1111-1111-111111111111'
        }
        $context = Resolve-MiOpsInventoryContext -Account $account -Config $configured
        Assert-True ($context.subscriptionId -eq $configured.onboarding.subscriptionId) 'Configured subscription was not selected.'
        Assert-True ($context.configurationFound) 'Configured inventory context was not reported.'
        Assert-ThrowsLike {
            Resolve-MiOpsInventoryContext -Account ([pscustomobject]@{
                id = '22222222-2222-2222-2222-222222222222'
                tenantId = '11111111-1111-1111-1111-111111111111'
            }) -Config $configured
        } '*does not match configured subscription*' 'Mismatched active subscription was accepted.'
        Assert-ThrowsLike {
            Resolve-MiOpsInventoryContext -Account ([pscustomobject]@{
                id = '00000000-0000-0000-0000-000000000000'
                tenantId = '33333333-3333-3333-3333-333333333333'
            }) -Config $configured
        } '*does not match configured tenant*' 'Mismatched active tenant was accepted.'
    }

    Test-Case 'inventory supports legacy config without onboarding metadata' {
        $account = [pscustomobject]@{
            id = '00000000-0000-0000-0000-000000000000'
            tenantId = '11111111-1111-1111-1111-111111111111'
        }
        $context = Resolve-MiOpsInventoryContext -Account $account -Config $baseConfig
        Assert-True ($context.subscriptionId -eq $account.id) 'Subscription was not derived from the configured MI resource ID.'
        Assert-True ($context.configurationFound) 'Legacy config was not treated as configuration.'
    }

    Test-Case 'inventory without config uses only the active subscription' {
        $account = [pscustomobject]@{
            id = '00000000-0000-0000-0000-000000000000'
            tenantId = '11111111-1111-1111-1111-111111111111'
        }
        $context = Resolve-MiOpsInventoryContext -Account $account
        Assert-True (-not $context.configurationFound) 'Missing config was not reported.'
        Assert-True ($context.subscriptionId -eq $account.id) 'Active subscription was not used.'
        Assert-True ($context.note -like 'No local onboarding configuration*') 'Missing config note was not explicit.'
        Assert-ThrowsLike {
            Resolve-MiOpsInventoryContext -Account $account -SubscriptionId '22222222-2222-2222-2222-222222222222'
        } '*does not match requested subscription*' 'A different subscription was queried silently.'
    }

    Test-Case 'inventory output exposes only minimal resource fields' {
        $raw = @([pscustomobject]@{
            name = 'vm-one'
            resourceGroup = 'rg-one'
            type = 'Microsoft.Compute/virtualMachines'
            location = 'eastus'
            id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-one/providers/Microsoft.Compute/virtualMachines/vm-one'
            tags = @{ secret = 'omit-me' }
            properties = @{ verbose = 'omit-me' }
            identity = @{ principalId = 'omit-me' }
        })
        $items = @(ConvertTo-MiOpsInventoryItems -ResourceKind vm -Resources $raw)
        Assert-True ($items.Count -eq 1) 'VM inventory item was lost.'
        Assert-True (($items[0].PSObject.Properties.Name -join ',') -eq 'name,resourceGroup,type,location,id') 'VM inventory exposed fields beyond the minimal shape.'
    }

    Test-Case 'MI inventory includes state and tier without verbose properties' {
        $raw = @([pscustomobject]@{
            name = 'mi-one'
            resourceGroup = 'rg-one'
            type = 'Microsoft.Sql/managedInstances'
            location = 'eastus'
            id = $resourceId
            state = 'Ready'
            provisioningState = 'Succeeded'
            sku = [pscustomobject]@{ tier = 'GeneralPurpose'; capacity = 8 }
            administratorLogin = 'omit-me'
        })
        $items = @(ConvertTo-MiOpsInventoryItems -ResourceKind mi -Resources $raw)
        Assert-True ($items[0].state -eq 'Ready') 'MI state was not preserved.'
        Assert-True ($items[0].tier -eq 'GeneralPurpose') 'MI tier was not preserved.'
        Assert-True ($items[0].PSObject.Properties.Name -notcontains 'administratorLogin') 'MI inventory exposed an unapproved property.'
        Assert-True ($items[0].PSObject.Properties.Name -notcontains 'sku') 'MI inventory exposed the verbose SKU object.'
    }

    Test-Case 'empty inventory shaping returns an empty collection' {
        $items = @(ConvertTo-MiOpsInventoryItems -ResourceKind all -Resources @())
        Assert-True ($items.Count -eq 0) 'Empty inventory did not remain empty.'
    }

    Test-Case 'local config generation sets one exact allowlisted resource' {
        $destination = Join-Path $tempRoot 'generated\miops.local.json'
        $example = Join-Path $repositoryRoot 'config\miops.example.json'
        $config = New-MiOpsLocalConfig -ExamplePath $example -DestinationPath $destination `
            -ResourceId $resourceId -TenantId '11111111-1111-1111-1111-111111111111' `
            -SubscriptionId '00000000-0000-0000-0000-000000000000' -RepositoryRoot $tempRoot
        Assert-True (Test-Path -LiteralPath $destination) 'Local config was not created.'
        Assert-True ($config.resource.id -eq $resourceId) 'Generated resource.id is incorrect.'
        Assert-True ($config.resource.allowedResourceIds.Count -eq 1) 'Generated allowlist must contain exactly one resource.'
        Assert-True ($config.resource.allowedResourceIds[0] -eq $resourceId) 'Generated allowlist resource is incorrect.'
        Assert-True ($config.onboarding.subscriptionId -eq '00000000-0000-0000-0000-000000000000') 'Subscription metadata was not stored.'
        Assert-True ($config.state.directory.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) 'Generated config did not resolve state under the requested data root.'
        Assert-True ((Get-Content -LiteralPath $example -Raw) -notmatch 'test-mi') 'Checked-in example was modified.'
    }

    Test-Case 'typed mutation confirmation is action and MI specific' {
        Assert-True (Test-MiOpsTypedConfirmation -Action START -ManagedInstanceName 'test-mi' -Confirmation 'START test-mi') 'Exact start confirmation was rejected.'
        Assert-True (-not (Test-MiOpsTypedConfirmation -Action START -ManagedInstanceName 'test-mi' -Confirmation 'STOP test-mi')) 'Wrong action confirmation was accepted.'
        Assert-True (-not (Test-MiOpsTypedConfirmation -Action STOP -ManagedInstanceName 'test-mi' -Confirmation 'STOP other-mi')) 'Wrong MI confirmation was accepted.'
        Assert-True (-not (Test-MiOpsTypedConfirmation -Action STOP -ManagedInstanceName 'test-mi' -Confirmation 'stop test-mi')) 'Case-changed confirmation was accepted.'
        Assert-True (Test-MiOpsTypedConfirmation -Action DELETE-SCHEDULE -ManagedInstanceName 'test-mi' -Confirmation 'DELETE SCHEDULE test-mi') 'Exact schedule deletion confirmation was rejected.'
        Assert-True (-not (Test-MiOpsTypedConfirmation -Action DELETE-SCHEDULE -ManagedInstanceName 'test-mi' -Confirmation 'DELETE test-mi')) 'Incomplete schedule deletion confirmation was accepted.'
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

    Test-Case 'database shaping tolerates Azure CLI schema differences' {
        $items = @(ConvertTo-MiOpsDatabaseItems -Databases @(
            [pscustomobject]@{
                name = 'db1'
                state = 'Online'
                creationDateTime = '2026-10-01T00:00:00Z'
                sourceDatabaseResourceId = '/source/db'
                id = "$resourceId/databases/db1"
            }
        ))
        Assert-True ($items[0].status -eq 'Online') 'Database state fallback was not used.'
        Assert-True ($items[0].creationDate -eq '2026-10-01T00:00:00Z') 'Creation date schema fallback was not used.'
        Assert-True ($items[0].sourceDatabaseId -eq '/source/db') 'Source database schema fallback was not used.'
    }

    Test-Case 'database inventory reports stopped instance without querying databases' {
        $calls = [System.Collections.Generic.List[string]]::new()
        $config = $baseConfig.Clone()
        $config.state = @{ directory = Join-Path $tempRoot 'stopped-instance-state' }
        $invoker = {
            param([string[]]$Arguments, [bool]$AllowEmpty)
            $calls.Add(($Arguments -join ' '))
            return [pscustomobject]@{ id = $resourceId; state = 'Stopped'; provisioningState = 'Succeeded' }
        }
        $result = Get-MiOpsDatabaseList -Config $config -AzInvoker $invoker
        Assert-True (-not $result.available) 'Stopped instance was reported as available.'
        Assert-True ($calls.Count -eq 1) 'Database list was queried for a stopped instance.'
        Assert-True ($result.evidenceGaps[0] -like '*Stopped*') 'Stopped state was not reported explicitly.'
    }

    Test-Case 'backup threshold configuration is validated' {
        $path = Join-Path $tempRoot 'invalid-backup-threshold.json'
        $invalid = $baseConfig.Clone()
        $invalid.backupHealth = @{ minimumShortTermRetentionDays = 36 }
        $invalid | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        Assert-ThrowsLike {
            Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot
        } '*minimumShortTermRetentionDays must be between 1 and 35*' 'Invalid STR threshold was accepted.'
    }

    Test-Case 'strict UTC timestamps reject offsets local time and future values' {
        Assert-True (Test-MiOpsUtcTimestamp -Timestamp '2026-10-10T01:00:00Z') 'Valid UTC timestamp was rejected.'
        Assert-True (Test-MiOpsUtcTimestamp -Timestamp '2026-10-10T01:00:00.123Z') 'Valid fractional UTC timestamp was rejected.'
        Assert-True (-not (Test-MiOpsUtcTimestamp -Timestamp '2026-10-10T01:00:00+08:00')) 'Offset timestamp was accepted.'
        Assert-True (-not (Test-MiOpsUtcTimestamp -Timestamp '2026-10-10 01:00:00')) 'Non-ISO local timestamp was accepted.'
    }

    Test-Case 'system and unsafe database names are rejected' {
        foreach ($name in @('master', 'model', 'msdb', 'tempdb')) {
            Assert-True (-not (Test-MiOpsDatabaseName -Name $name)) "System database '$name' was accepted."
        }
        Assert-True (Test-MiOpsDatabaseName -Name 'db1-restore') 'Safe destination name was rejected.'
        Assert-True (-not (Test-MiOpsDatabaseName -Name 'db1/restore')) 'Unsafe destination name was accepted.'
    }

    Test-Case 'LTR retention parsing is strict normalized and bounded' {
        Assert-True ((ConvertTo-MiOpsLtrRetention -Value 'P12W' -Dimension Weekly).normalized -eq 'P12W') 'Weekly retention was not normalized.'
        Assert-True ((ConvertTo-MiOpsLtrRetention -Value 'P12M' -Dimension Monthly).normalized -eq 'P12M') 'Monthly retention was not normalized.'
        Assert-True ((ConvertTo-MiOpsLtrRetention -Value 'P5Y' -Dimension Yearly).normalized -eq 'P5Y') 'Yearly retention was not normalized.'
        Assert-True ((ConvertTo-MiOpsLtrRetention -Value 'P1M' -Dimension Weekly).enabled) 'Azure-supported cross-dimension ISO unit was rejected.'
        Assert-True ((ConvertTo-MiOpsLtrRetention -Value 'P3650D' -Dimension Weekly).enabled) 'Maximum day retention was rejected.'
        Assert-True ((ConvertTo-MiOpsLtrRetention -Value 'P521W' -Dimension Weekly).enabled) 'Maximum week retention was rejected.'
        Assert-True ((ConvertTo-MiOpsLtrRetention -Value 'P120M' -Dimension Monthly).enabled) 'Maximum monthly retention was rejected.'
        Assert-True ((ConvertTo-MiOpsLtrRetention -Value 'P10Y' -Dimension Yearly).enabled) 'Maximum yearly retention was rejected.'
        Assert-True (-not (ConvertTo-MiOpsLtrRetention -Value 'PT0S' -Dimension Weekly).enabled) 'PT0S was not treated as disabled.'
        Assert-Throws { ConvertTo-MiOpsLtrRetention -Value '12' -Dimension Weekly } 'Bare numeric retention was accepted.'
        Assert-Throws { ConvertTo-MiOpsLtrRetention -Value 'P6D' -Dimension Weekly } 'Retention below seven days was accepted.'
        Assert-Throws { ConvertTo-MiOpsLtrRetention -Value 'P1Y2M' -Dimension Yearly } 'Combined duration was accepted.'
        Assert-Throws { ConvertTo-MiOpsLtrRetention -Value 'P0W' -Dimension Weekly } 'Zero duration outside PT0S was accepted.'
        Assert-Throws { ConvertTo-MiOpsLtrRetention -Value 'P3651D' -Dimension Weekly } 'Day retention above 10 years was accepted.'
        Assert-Throws { ConvertTo-MiOpsLtrRetention -Value 'P522W' -Dimension Weekly } 'Weekly retention above 10 years was accepted.'
        Assert-Throws { ConvertTo-MiOpsLtrRetention -Value 'P121M' -Dimension Monthly } 'Monthly retention above 10 years was accepted.'
        Assert-Throws { ConvertTo-MiOpsLtrRetention -Value 'P11Y' -Dimension Yearly } 'Yearly retention above 10 years was accepted.'
    }

    Test-Case 'LTR current policy shaping normalizes Azure disabled sentinels' {
        $policy = ConvertTo-MiOpsLtrPolicy -Policy ([pscustomobject]@{
            weeklyRetention = 'P84D'
            monthlyRetention = 'P0D'
            yearlyRetention = 'PT0S'
            weekOfYear = 51
        }) -FromAzure
        Assert-True ($policy.weeklyRetention -eq 'P84D') 'Azure day-form weekly retention was not preserved safely.'
        Assert-True ($policy.monthlyRetention -eq 'PT0S') 'Azure monthly disabled sentinel was not normalized.'
        Assert-True ($policy.yearlyRetention -eq 'PT0S') 'Azure yearly disabled sentinel was not normalized.'
        Assert-True ($policy.weekOfYear -eq 0) 'Irrelevant week-of-year was not normalized to zero.'
        $dayPolicy = ConvertTo-MiOpsLtrPolicy -Policy ([pscustomobject]@{
            weeklyRetention = 'P7D'
            monthlyRetention = 'P365D'
            yearlyRetention = 'P1825D'
            weekOfYear = 1
        }) -FromAzure
        Assert-True ($dayPolicy.weeklyRetention -eq 'P7D') 'Azure weekly day form was not preserved safely.'
        Assert-True ($dayPolicy.monthlyRetention -eq 'P365D') 'Azure monthly day form was not preserved safely.'
        Assert-True ($dayPolicy.yearlyRetention -eq 'P1825D') 'Azure yearly day form was not preserved safely.'
    }

    Test-Case 'LTR requested policy validates week and rejects all disabled' {
        Assert-ThrowsLike {
            New-MiOpsLtrRequestedPolicy -WeeklyRetention 'PT0S' -MonthlyRetention 'PT0S' -YearlyRetention 'PT0S' -WeekOfYear 0
        } '*At least one LTR retention dimension must remain enabled*' 'All-disabled LTR policy was accepted.'
        Assert-ThrowsLike {
            New-MiOpsLtrRequestedPolicy -WeeklyRetention 'P12W' -MonthlyRetention 'P12M' -YearlyRetention 'P5Y' -WeekOfYear 53
        } '*between 1 and 52*' 'Out-of-range yearly week was accepted.'
        Assert-ThrowsLike {
            New-MiOpsLtrRequestedPolicy -WeeklyRetention 'P12W' -MonthlyRetention 'P12M' -YearlyRetention 'PT0S' -WeekOfYear 1
        } '*must be 0 when yearly retention is PT0S*' 'Week was accepted while yearly retention was disabled.'
    }

    Test-Case 'LTR no-weakening detects reductions and exact confirmation' {
        $current = New-MiOpsLtrRequestedPolicy -WeeklyRetention 'P12W' -MonthlyRetention 'P12M' -YearlyRetention 'P5Y' -WeekOfYear 1
        $increase = New-MiOpsLtrRequestedPolicy -WeeklyRetention 'P13W' -MonthlyRetention 'P12M' -YearlyRetention 'P6Y' -WeekOfYear 1
        $reduction = New-MiOpsLtrRequestedPolicy -WeeklyRetention 'P6W' -MonthlyRetention 'PT0S' -YearlyRetention 'P5Y' -WeekOfYear 1
        Assert-True (-not (Test-MiOpsLtrPolicyReduction -Current $current -Requested $increase).isReduction) 'Retention increase was treated as reduction.'
        Assert-True ((Test-MiOpsLtrPolicyReduction -Current $current -Requested $reduction).isReduction) 'Retention weakening was not detected.'
        Assert-True (Test-MiOpsLtrConfirmation -Database 'test02' -Policy $increase -IsReduction $false -Confirmation 'SET LTR test02 WEEKLY P13W MONTHLY P12M YEARLY P6Y WEEK 1') 'Exact normal confirmation was rejected.'
        Assert-True (-not (Test-MiOpsLtrConfirmation -Database 'test02' -Policy $reduction -IsReduction $true -Confirmation 'SET LTR test02 WEEKLY P6W MONTHLY PT0S YEARLY P5Y WEEK 1')) 'Normal confirmation authorized a reduction.'
        Assert-True (Test-MiOpsLtrConfirmation -Database 'test02' -Policy $reduction -IsReduction $true -Confirmation 'REDUCE LTR test02 WEEKLY P6W MONTHLY PT0S YEARLY P5Y WEEK 1') 'Exact reduction confirmation was rejected.'
    }

    Test-Case 'LTR plan uses fixed CLI arguments and never mutates' {
        $path = Join-Path $tempRoot 'ltr-plan.json'
        $baseConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $config = Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot
        $script:ltrSetCalls = 0
        $invoker = {
            param([string[]]$Arguments, [bool]$AllowEmpty)
            $joined = $Arguments -join ' '
            if ($joined -eq "sql mi show --ids $resourceId") {
                return [pscustomobject]@{ id = $resourceId; name = 'test-mi'; state = 'Ready'; provisioningState = 'Succeeded' }
            }
            if ($joined -like 'sql midb list*') {
                return @([pscustomobject]@{ name = 'test02'; status = 'Online'; id = "$resourceId/databases/test02" })
            }
            if ($joined -like 'sql midb ltr-policy show*') {
                return [pscustomobject]@{ weeklyRetention = 'P4W'; monthlyRetention = 'PT0S'; yearlyRetention = 'PT0S'; weekOfYear = 0 }
            }
            if ($joined -like 'sql midb ltr-policy set*') {
                $script:ltrSetCalls++
            }
            throw "Unexpected mock Azure CLI call: $joined"
        }
        $plan = Get-MiOpsLtrPolicyPlan -Config $config -Database 'test02' -WeeklyRetention 'P12W' `
            -MonthlyRetention 'P12M' -YearlyRetention 'P5Y' -WeekOfYear 1 -AzInvoker $invoker
        Assert-True ($script:ltrSetCalls -eq 0) 'LTR planning mutated Azure.'
        Assert-True (($plan.azureCliArguments -join ' ') -eq 'sql midb ltr-policy set --resource-group test-rg --managed-instance test-mi --name test02 --weekly-retention P12W --monthly-retention P12M --yearly-retention P5Y --week-of-year 1 --subscription 00000000-0000-0000-0000-000000000000') 'LTR plan did not produce the fixed CLI shape.'
        Assert-True ($plan.requiredConfirmation -eq 'SET LTR test02 WEEKLY P12W MONTHLY P12M YEARLY P5Y WEEK 1') 'LTR plan confirmation was not bound to the full policy.'
    }

    Test-Case 'LTR apply blocks weakening without both explicit safeguards' {
        $path = Join-Path $tempRoot 'ltr-reduction.json'
        $baseConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $config = Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot
        $invoker = {
            param([string[]]$Arguments, [bool]$AllowEmpty)
            $joined = $Arguments -join ' '
            if ($joined -eq "sql mi show --ids $resourceId") {
                return [pscustomobject]@{ id = $resourceId; name = 'test-mi'; state = 'Ready'; provisioningState = 'Succeeded' }
            }
            if ($joined -like 'sql midb list*') {
                return @([pscustomobject]@{ name = 'test02'; status = 'Online'; id = "$resourceId/databases/test02" })
            }
            if ($joined -like 'sql midb ltr-policy show*') {
                return [pscustomobject]@{ weeklyRetention = 'P12W'; monthlyRetention = 'P12M'; yearlyRetention = 'P5Y'; weekOfYear = 1 }
            }
            throw "Unexpected mock Azure CLI call: $joined"
        }
        Assert-ThrowsLike {
            Invoke-MiOpsLtrPolicy -Config $config -Database 'test02' -WeeklyRetention 'P6W' `
                -MonthlyRetention 'PT0S' -YearlyRetention 'P5Y' -WeekOfYear 1 -Apply `
                -ApproveResourceId $resourceId -TypedConfirmation 'REDUCE LTR test02 WEEKLY P6W MONTHLY PT0S YEARLY P5Y WEEK 1' -AzInvoker $invoker
        } '*-AllowRetentionReduction*' 'Reduction was accepted without the explicit switch.'
        Assert-ThrowsLike {
            Invoke-MiOpsLtrPolicy -Config $config -Database 'test02' -WeeklyRetention 'P6W' `
                -MonthlyRetention 'PT0S' -YearlyRetention 'P5Y' -WeekOfYear 1 -Apply `
                -ApproveResourceId $resourceId -AllowRetentionReduction `
                -TypedConfirmation 'SET LTR test02 WEEKLY P6W MONTHLY PT0S YEARLY P5Y WEEK 1' -AzInvoker $invoker
        } '*Typed confirmation did not exactly match*' 'Reduction was accepted without the REDUCE phrase.'
    }

    Test-Case 'LTR apply persists intent redacts response and verifies exact read-back' {
        $path = Join-Path $tempRoot 'ltr-apply.json'
        $baseConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $config = Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot
        $script:ltrShowCount = 0
        $script:ltrSubmissionArguments = $null
        $invoker = {
            param([string[]]$Arguments, [bool]$AllowEmpty)
            $joined = $Arguments -join ' '
            if ($joined -eq "sql mi show --ids $resourceId") {
                return [pscustomobject]@{ id = $resourceId; name = 'test-mi'; state = 'Ready'; provisioningState = 'Succeeded' }
            }
            if ($joined -like 'sql midb list*') {
                return @([pscustomobject]@{ name = 'test02'; status = 'Online'; id = "$resourceId/databases/test02" })
            }
            if ($joined -like 'sql midb ltr-policy show*') {
                $script:ltrShowCount++
                if ($script:ltrShowCount -eq 1) {
                    return [pscustomobject]@{ weeklyRetention = 'P4W'; monthlyRetention = 'PT0S'; yearlyRetention = 'PT0S'; weekOfYear = 0 }
                }
                return [pscustomobject]@{ weeklyRetention = 'P12W'; monthlyRetention = 'P12M'; yearlyRetention = 'P5Y'; weekOfYear = 1 }
            }
            if ($joined -like 'sql midb ltr-policy set*') {
                $script:ltrSubmissionArguments = $Arguments
                return [pscustomobject]@{ status = 'Accepted'; accessToken = 'secret-value' }
            }
            throw "Unexpected mock Azure CLI call: $joined"
        }
        $result = Invoke-MiOpsLtrPolicy -Config $config -Database 'test02' -WeeklyRetention 'P12W' `
            -MonthlyRetention 'P12M' -YearlyRetention 'P5Y' -WeekOfYear 1 -Apply `
            -ApproveResourceId $resourceId `
            -TypedConfirmation 'SET LTR test02 WEEKLY P12W MONTHLY P12M YEARLY P5Y WEEK 1' -AzInvoker $invoker
        $operationText = Get-Content -LiteralPath $result.operationPath -Raw
        $auditText = Get-Content -LiteralPath (Join-Path $config.state.directory 'audit.jsonl') -Raw
        Assert-True ($result.operation.status -eq 'Verified') 'Exact LTR read-back was not marked Verified.'
        Assert-True (($script:ltrSubmissionArguments -join ' ') -like 'sql midb ltr-policy set*--weekly-retention P12W*--monthly-retention P12M*--yearly-retention P5Y*') 'LTR apply did not use the reviewed fixed command.'
        Assert-True ($operationText -match '"accessToken":\s*"\[REDACTED\]"') 'Sensitive Azure response was not redacted in operation state.'
        Assert-True ($auditText -match 'ltr.policy.ready') 'Pre-submission LTR audit record was not persisted.'
        Assert-True ($auditText -notmatch 'secret-value') 'Sensitive Azure response leaked into audit records.'
    }

    Test-Case 'LTR apply never verifies a read-back mismatch' {
        $path = Join-Path $tempRoot 'ltr-mismatch.json'
        $baseConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $config = Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot
        $invoker = {
            param([string[]]$Arguments, [bool]$AllowEmpty)
            $joined = $Arguments -join ' '
            if ($joined -eq "sql mi show --ids $resourceId") {
                return [pscustomobject]@{ id = $resourceId; name = 'test-mi'; state = 'Ready'; provisioningState = 'Succeeded' }
            }
            if ($joined -like 'sql midb list*') {
                return @([pscustomobject]@{ name = 'test02'; status = 'Online'; id = "$resourceId/databases/test02" })
            }
            if ($joined -like 'sql midb ltr-policy show*') {
                return [pscustomobject]@{ weeklyRetention = 'P4W'; monthlyRetention = 'PT0S'; yearlyRetention = 'PT0S'; weekOfYear = 0 }
            }
            if ($joined -like 'sql midb ltr-policy set*') {
                return [pscustomobject]@{ status = 'Accepted' }
            }
            throw "Unexpected mock Azure CLI call: $joined"
        }
        $result = Invoke-MiOpsLtrPolicy -Config $config -Database 'test02' -WeeklyRetention 'P12W' `
            -MonthlyRetention 'P12M' -YearlyRetention 'P5Y' -WeekOfYear 1 -Apply `
            -ApproveResourceId $resourceId `
            -TypedConfirmation 'SET LTR test02 WEEKLY P12W MONTHLY P12M YEARLY P5Y WEEK 1' -AzInvoker $invoker
        Assert-True ($result.operation.status -eq 'VerificationMismatch') 'Mismatched LTR read-back was incorrectly marked Verified.'
    }

    Test-Case 'restore target allowlist comparison is exact' {
        $targetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Sql/managedInstances/target-mi'
        $config = $baseConfig.Clone()
        $config.restoreTargets = @{ allowedResourceIds = @($targetId) }
        Assert-True (Test-MiOpsRestoreTargetAllowed -Config $config -ResourceId $targetId.ToUpperInvariant()) 'Exact target allowlist match failed.'
        Assert-True (-not (Test-MiOpsRestoreTargetAllowed -Config $config -ResourceId "$targetId-extra")) 'Target allowlist accepted a prefix match.'
    }

    Test-Case 'restore target configuration requires exact phrase and persists only the requested target' {
        $targetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/target-rg/providers/Microsoft.Sql/managedInstances/target-mi'
        $path = Join-Path $tempRoot 'configure-target.json'
        $baseConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $config = Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot
        $invoker = {
            param([string[]]$Arguments, [bool]$AllowEmpty)
            return [pscustomobject]@{ id = $targetId; name = 'target-mi'; state = 'Ready'; provisioningState = 'Succeeded' }
        }
        Assert-ThrowsLike {
            Add-MiOpsRestoreTarget -Config $config -TargetManagedInstanceId $targetId -TypedConfirmation 'yes' -AzInvoker $invoker
        } '*CONFIGURE RESTORE TARGET target-mi*' 'Conversational target configuration approval was accepted.'
        $updated = Add-MiOpsRestoreTarget -Config $config -TargetManagedInstanceId $targetId `
            -TypedConfirmation 'CONFIGURE RESTORE TARGET target-mi' -AzInvoker $invoker
        Assert-True ($updated.restoreTargets.allowedResourceIds.Count -eq 1) 'Unexpected restore targets were persisted.'
        Assert-True ($updated.restoreTargets.allowedResourceIds[0] -eq $targetId) 'Requested restore target was not persisted exactly.'
        Assert-True ($updated.resource.allowedResourceIds.Count -eq 1) 'Source allowlist changed while configuring a restore target.'
    }

    Test-Case 'backup anomaly rules separate warnings from insufficient evidence' {
        $now = [DateTimeOffset]'2026-10-10T12:00:00Z'
        $result = Get-MiOpsBackupFindings `
            -Database ([pscustomobject]@{ name = 'db1'; status = 'Restoring' }) `
            -ShortTermPolicy ([pscustomobject]@{ retentionDays = 5 }) `
            -LongTermPolicy ([pscustomobject]@{ weeklyRetention = 'P4W'; monthlyRetention = 'P0D'; yearlyRetention = 'P0D' }) `
            -LongTermBackups @([pscustomobject]@{ backupTime = '2026-09-01T00:00:00Z' }) `
            -SqlHistory ([pscustomobject]@{
                latestFullBackupUtc = '2026-10-01T00:00:00Z'
                latestDifferentialBackupUtc = $null
                latestLogBackupUtc = '2026-10-10T10:00:00Z'
            }) `
            -Thresholds @{
                minimumShortTermRetentionDays = 7
                requireLongTermRetention = $true
                maximumLatestLongTermBackupAgeDays = 8
                maximumFullBackupAgeHours = 192
                maximumDifferentialBackupAgeHours = 48
                maximumLogBackupAgeMinutes = 30
            } -EvidenceGaps @('LTR permission unavailable.') -NowUtc $now
        Assert-True (@($result.findings | Where-Object code -eq 'database-not-online').Count -eq 1) 'Non-online database warning was missing.'
        Assert-True (@($result.findings | Where-Object code -eq 'str-retention-below-threshold').Count -eq 1) 'STR threshold warning was missing.'
        Assert-True (@($result.findings | Where-Object code -eq 'ltr-latest-too-old').Count -eq 1) 'Stale LTR warning was missing.'
        Assert-True (@($result.findings | Where-Object severity -eq 'insufficient-evidence').Count -ge 2) 'Evidence gaps were not separated from warnings.'
    }

    Test-Case 'SQL backup adapter uses fixed Entra query without secrets' {
        $config = $baseConfig.Clone()
        $config.sqlDiagnostics = @{
            enabled = $true
            adapter = 'sqlcmd-entra'
            connectTimeoutSeconds = 15
            queryTimeoutSeconds = 30
            maxRows = 100
        }
        $config.state = @{ directory = Join-Path $tempRoot 'sql-adapter-state' }
        $captured = $null
        $invoker = {
            param($Executable, [string[]]$Arguments)
            $script:capturedSqlArguments = $Arguments
            return 'db1|2026-10-10T00:00:00|2026-10-10T06:00:00|2026-10-10T11:50:00'
        }
        $result = Invoke-MiOpsSqlBackupHistory -Config $config -Server 'test-mi.public.example' -SqlInvoker $invoker
        $joined = $script:capturedSqlArguments -join ' '
        Assert-True ($result.included) 'SQL adapter did not return parsed evidence.'
        Assert-True ($result.rows[0].database -eq 'db1') 'SQL adapter did not parse the fixed result shape.'
        Assert-True ($joined -match ' -G ') 'Microsoft Entra authentication flag was not used.'
        Assert-True ($joined -notmatch '(?i)(password|access[_-]?token|client[_-]?secret)') 'SQL adapter arguments contained a secret input.'
        Assert-True ($joined -match 'TOP \(100\)') 'Configured SQL row limit was not embedded in the fixed query.'
    }

    Test-Case 'restore plan rejects an existing destination database' {
        $targetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/target-rg/providers/Microsoft.Sql/managedInstances/target-mi'
        $path = Join-Path $tempRoot 'restore-existing.json'
        $restoreConfig = $baseConfig.Clone()
        $restoreConfig.restoreTargets = @{ allowedResourceIds = @($targetId) }
        $restoreConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $restoreConfig = Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot
        $restoreTime = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $earliest = [DateTimeOffset]::UtcNow.AddDays(-7).ToString('o')
        $invoker = {
            param([string[]]$Arguments, [bool]$AllowEmpty)
            $joined = $Arguments -join ' '
            if ($joined -eq "sql mi show --ids $resourceId") {
                return [pscustomobject]@{ id = $resourceId; name = 'test-mi'; location = 'eastus'; state = 'Ready'; provisioningState = 'Succeeded' }
            }
            if ($joined -eq "sql mi show --ids $targetId") {
                return [pscustomobject]@{ id = $targetId; name = 'target-mi'; location = 'eastus'; state = 'Ready'; provisioningState = 'Succeeded' }
            }
            if ($joined -like 'sql midb list*--managed-instance test-mi*') {
                return @([pscustomobject]@{ name = 'db1'; status = 'Online'; earliestRestoreDate = $earliest; id = "$resourceId/databases/db1" })
            }
            if ($joined -like 'sql midb list*--managed-instance target-mi*') {
                return @([pscustomobject]@{ name = 'db1-restore'; status = 'Online'; id = "$targetId/databases/db1-restore" })
            }
            throw "Unexpected mock Azure CLI call: $joined"
        }
        Assert-ThrowsLike {
            Get-MiOpsRestorePlan -Config $restoreConfig -SourceDatabase 'db1' -TargetManagedInstanceId $targetId `
                -TargetDatabase 'db1-restore' -RestoreTimeUtc $restoreTime -AzInvoker $invoker
        } '*already exists*never overwrites*' 'Existing destination database was accepted.'
    }

    Test-Case 'restore apply requires dual approvals and exact field-bound phrase' {
        $targetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/target-rg/providers/Microsoft.Sql/managedInstances/target-mi'
        $path = Join-Path $tempRoot 'restore-apply.json'
        $restoreConfig = $baseConfig.Clone()
        $restoreConfig.restoreTargets = @{ allowedResourceIds = @($targetId) }
        $restoreConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $restoreConfig = Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot
        $restoreTime = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $earliest = [DateTimeOffset]::UtcNow.AddDays(-7).ToString('o')
        $script:restoreSubmissionArguments = $null
        $invoker = {
            param([string[]]$Arguments, [bool]$AllowEmpty)
            $joined = $Arguments -join ' '
            if ($joined -eq "sql mi show --ids $resourceId") {
                return [pscustomobject]@{ id = $resourceId; name = 'test-mi'; location = 'eastus'; state = 'Ready'; provisioningState = 'Succeeded' }
            }
            if ($joined -eq "sql mi show --ids $targetId") {
                return [pscustomobject]@{ id = $targetId; name = 'target-mi'; location = 'eastus'; state = 'Ready'; provisioningState = 'Succeeded' }
            }
            if ($joined -like 'sql midb list*--managed-instance test-mi*') {
                return @([pscustomobject]@{ name = 'db1'; status = 'Online'; earliestRestoreDate = $earliest; id = "$resourceId/databases/db1" })
            }
            if ($joined -like 'sql midb list*--managed-instance target-mi*') {
                return @()
            }
            if ($joined -like 'sql midb restore*') {
                $script:restoreSubmissionArguments = $Arguments
                return $null
            }
            throw "Unexpected mock Azure CLI call: $joined"
        }
        Assert-ThrowsLike {
            Invoke-MiOpsRestore -Config $restoreConfig -SourceDatabase 'db1' -TargetManagedInstanceId $targetId `
                -TargetDatabase 'db1-restore' -RestoreTimeUtc $restoreTime -Apply `
                -ApproveSourceResourceId $resourceId -ApproveTargetResourceId $targetId `
                -TypedConfirmation 'yes' -AzInvoker $invoker
        } '*Typed confirmation did not exactly match*' 'Conversational approval was accepted.'
        Assert-ThrowsLike {
            Invoke-MiOpsRestore -Config $restoreConfig -SourceDatabase 'db1' -TargetManagedInstanceId $targetId `
                -TargetDatabase 'db1-restore' -RestoreTimeUtc $restoreTime -Apply `
                -ApproveSourceResourceId $resourceId -ApproveTargetResourceId $resourceId `
                -TypedConfirmation "RESTORE db1 TO target-mi/db1-restore AT $restoreTime" -AzInvoker $invoker
        } '*exact -ApproveSourceResourceId and -ApproveTargetResourceId*' 'Wrong target approval was accepted.'
        $submitted = Invoke-MiOpsRestore -Config $restoreConfig -SourceDatabase 'db1' -TargetManagedInstanceId $targetId `
            -TargetDatabase 'db1-restore' -RestoreTimeUtc $restoreTime -Apply `
            -ApproveSourceResourceId $resourceId -ApproveTargetResourceId $targetId `
            -TypedConfirmation "RESTORE db1 TO target-mi/db1-restore AT $restoreTime" -AzInvoker $invoker
        $joined = $script:restoreSubmissionArguments -join ' '
        Assert-True ($submitted.operation.status -eq 'Submitted') 'Accepted restore was not persisted as Submitted.'
        Assert-True ($joined -like 'sql midb restore*--dest-name db1-restore*--dest-mi target-mi*--no-wait') 'Restore did not use the fixed current Azure CLI shape.'
    }

    Test-Case 'restore polling transitions InProgress to Verified and distinguishes failure' {
        $inProgress = Get-MiOpsRestorePollState -Database ([pscustomobject]@{ status = 'Restoring'; provisioningState = 'Creating' })
        $verified = Get-MiOpsRestorePollState -Database ([pscustomobject]@{ status = 'Online'; provisioningState = 'Succeeded' })
        $failed = Get-MiOpsRestorePollState -Database ([pscustomobject]@{ status = 'Inaccessible'; provisioningState = 'Failed' })
        $notFound = Get-MiOpsRestorePollState -ErrorMessage 'ResourceNotFound: database not found'
        Assert-True ($inProgress.status -eq 'InProgress') 'Restoring database was not InProgress.'
        Assert-True ($verified.status -eq 'Verified') 'Online database was not Verified.'
        Assert-True ($failed.status -eq 'Failed') 'Terminal database failure was not Failed.'
        Assert-True ($notFound.status -eq 'InProgress') 'Destination not yet visible was not treated as InProgress.'
    }

    Test-Case 'restore poll transitions persist InProgress and Verified states' {
        $targetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/target-rg/providers/Microsoft.Sql/managedInstances/target-mi'
        $path = Join-Path $tempRoot 'restore-poll.json'
        $restoreConfig = $baseConfig.Clone()
        $restoreConfig.restoreTargets = @{ allowedResourceIds = @($targetId) }
        $restoreConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
        $restoreConfig = Get-MiOpsConfig -Path $path -RepositoryRoot $tempRoot
        $operation = [ordered]@{
            operationId = 'restore-poll-operation'
            action = 'restore'
            status = 'Submitted'
            sourceManagedInstanceId = $resourceId
            targetManagedInstanceId = $targetId
            targetDatabase = 'db1-restore'
            updatedAtUtc = [DateTime]::UtcNow.ToString('o')
            verification = $null
        }
        $null = Save-MiOpsOperation -Config $restoreConfig -Operation $operation
        $restoringInvoker = {
            param([string[]]$Arguments, [bool]$AllowEmpty)
            return [pscustomobject]@{ name = 'db1-restore'; status = 'Restoring'; provisioningState = 'Creating' }
        }
        $first = Update-MiOpsRestoreOperation -Config $restoreConfig -Operation (Get-MiOpsOperation -Config $restoreConfig -OperationId 'restore-poll-operation') -AzInvoker $restoringInvoker
        Assert-True ($first.operation.status -eq 'InProgress') 'Restore poll did not persist InProgress.'
        $onlineInvoker = {
            param([string[]]$Arguments, [bool]$AllowEmpty)
            return [pscustomobject]@{ name = 'db1-restore'; status = 'Online'; provisioningState = 'Succeeded' }
        }
        $second = Update-MiOpsRestoreOperation -Config $restoreConfig -Operation (Get-MiOpsOperation -Config $restoreConfig -OperationId 'restore-poll-operation') -AzInvoker $onlineInvoker
        $loaded = Get-MiOpsOperation -Config $restoreConfig -OperationId 'restore-poll-operation'
        Assert-True ($second.operation.status -eq 'Verified') 'Restore poll did not transition to Verified.'
        Assert-True ($loaded.status -eq 'Verified') 'Verified restore state was not persisted.'
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

Write-Host "$script:passed passed; $script:failed failed"
if ($script:failed -gt 0) {
    exit 1
}

& (Join-Path $PSScriptRoot 'project-skills-tests.ps1')
