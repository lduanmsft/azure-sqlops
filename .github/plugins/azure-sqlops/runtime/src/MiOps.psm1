Set-StrictMode -Version Latest

function ConvertTo-MiOpsHashtable {
    param($InputObject)

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = ConvertTo-MiOpsHashtable -InputObject $InputObject[$key]
        }
        return $result
    }

    if ($InputObject -is [pscustomobject]) {
        $result = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-MiOpsHashtable -InputObject $property.Value
        }
        return $result
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return @($InputObject | ForEach-Object { ConvertTo-MiOpsHashtable -InputObject $_ })
    }

    return $InputObject
}

function Get-MiOpsConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path. Copy config/miops.example.json to config/miops.local.json and edit it."
    }

    try {
        $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    }
    catch {
        throw "Configuration is not valid JSON: $($_.Exception.Message)"
    }

    if ($config.schemaVersion -ne 1) {
        throw 'Configuration schemaVersion must be 1.'
    }
    if (-not $config.resource -or -not $config.safety -or -not $config.state -or -not $config.evidence) {
        throw 'Configuration requires resource, safety, state, and evidence sections.'
    }

    $resourceIdPattern = '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Sql/managedInstances/[^/]+$'
    if (-not $config.resource.id -or $config.resource.id -notmatch $resourceIdPattern) {
        throw 'resource.id must be a complete Azure SQL Managed Instance resource ID.'
    }

    if (-not $config.resource.allowedResourceIds -or $config.resource.allowedResourceIds.Count -lt 1) {
        throw 'resource.allowedResourceIds must contain at least one complete resource ID.'
    }

    foreach ($resourceId in $config.resource.allowedResourceIds) {
        if ($resourceId -notmatch $resourceIdPattern) {
            throw "Invalid allowlisted Managed Instance resource ID: $resourceId"
        }
    }

    if (-not (Test-MiOpsResourceAllowed -Config $config -ResourceId $config.resource.id)) {
        throw 'resource.id is not present in resource.allowedResourceIds.'
    }

    if (-not $config.state.directory) {
        throw 'state.directory is required.'
    }
    if ($config.safety.defaultReadOnly -ne $true) {
        throw 'safety.defaultReadOnly must be true for the phase-1 MVP.'
    }
    if (-not $config.safety.allowedLifecycleTiers -or $config.safety.allowedLifecycleTiers.Count -lt 1) {
        throw 'safety.allowedLifecycleTiers must contain at least one explicitly approved SKU tier.'
    }

    $stateDirectory = if ([System.IO.Path]::IsPathRooted([string]$config.state.directory)) {
        [string]$config.state.directory
    }
    else {
        Join-Path $RepositoryRoot ([string]$config.state.directory)
    }

    $config.state.directory = [System.IO.Path]::GetFullPath($stateDirectory)
    $config['_configPath'] = [System.IO.Path]::GetFullPath($Path)
    return $config
}

function Test-MiOpsResourceAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ResourceId
    )

    $normalized = $ResourceId.TrimEnd('/').ToLowerInvariant()
    return @($Config.resource.allowedResourceIds | ForEach-Object {
        ([string]$_).TrimEnd('/').ToLowerInvariant()
    }) -contains $normalized
}

function ConvertTo-MiOpsRedactedObject {
    [CmdletBinding()]
    param(
        $InputObject,
        [string]$PropertyName = ''
    )

    if ($PropertyName -match '(?i)(access.?token|authorization|client.?secret|password|connection.?string|private.?key|sas.?token|api.?key)') {
        return '[REDACTED]'
    }

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = ConvertTo-MiOpsRedactedObject -InputObject $InputObject[$key] -PropertyName ([string]$key)
        }
        return $result
    }

    if ($InputObject -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-MiOpsRedactedObject -InputObject $property.Value -PropertyName $property.Name
        }
        return $result
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return @($InputObject | ForEach-Object {
            ConvertTo-MiOpsRedactedObject -InputObject $_
        })
    }

    if ($InputObject -is [string]) {
        $value = [string]$InputObject
        $value = $value -replace '(?i)Bearer\s+[A-Za-z0-9\-._~+/]+=*', 'Bearer [REDACTED]'
        $value = $value -replace '(?i)(password|pwd|client_secret|access_token)\s*[=:]\s*[^;\s]+', '$1=[REDACTED]'
        return $value
    }

    return $InputObject
}

function Initialize-MiOpsState {
    param([Parameter(Mandatory)][hashtable]$Config)

    $directories = @(
        $Config.state.directory,
        (Join-Path $Config.state.directory 'operations'),
        (Join-Path $Config.state.directory 'evidence'),
        (Join-Path $Config.state.directory 'support')
    )
    foreach ($directory in $directories) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
}

function Write-MiOpsAudit {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Event,
        [Parameter(Mandatory)]$Data
    )

    Initialize-MiOpsState -Config $Config
    $record = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        event = $Event
        data = ConvertTo-MiOpsRedactedObject -InputObject $Data
    }
    $record | ConvertTo-Json -Depth 20 -Compress | Add-Content -LiteralPath (Join-Path $Config.state.directory 'audit.jsonl') -Encoding utf8
}

function Test-MiOpsTenantId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId)

    $value = $TenantId.Trim()
    return $value -match '^(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+)$'
}

function Test-MiOpsSubscriptionId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubscriptionId)

    return $SubscriptionId.Trim() -match '^(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

function Get-MiOpsPropertyValue {
    [CmdletBinding()]
    param(
        $InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }
    return $null
}

function Select-MiOpsNumberedItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [string]$Selection,
        [string]$Prompt = 'Select an item'
    )

    if ($Items.Count -eq 0) {
        throw 'No items are available for selection.'
    }

    $value = if ($PSBoundParameters.ContainsKey('Selection')) {
        $Selection
    }
    else {
        Read-Host "$Prompt (1-$($Items.Count), or 0 to cancel)"
    }

    $number = 0
    if (-not [int]::TryParse(([string]$value).Trim(), [ref]$number)) {
        throw "Selection must be a number from 1 to $($Items.Count), or 0 to cancel."
    }
    if ($number -eq 0) {
        return $null
    }
    if ($number -lt 1 -or $number -gt $Items.Count) {
        throw "Selection must be a number from 1 to $($Items.Count), or 0 to cancel."
    }

    return $Items[$number - 1]
}

function Test-MiOpsTypedConfirmation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('CONFIGURE', 'START', 'STOP', 'DELETE-SCHEDULE')][string]$Action,
        [Parameter(Mandatory)][string]$ManagedInstanceName,
        [Parameter(Mandatory)][string]$Confirmation
    )

    $expected = if ($Action -eq 'DELETE-SCHEDULE') {
        "DELETE SCHEDULE $ManagedInstanceName"
    }
    else {
        "$($Action.ToUpperInvariant()) $ManagedInstanceName"
    }
    return $Confirmation -ceq $expected
}

function Invoke-MiOpsAzLogin {
    [CmdletBinding()]
    param(
        [string]$TenantId,
        [switch]$UseDeviceCode
    )

    if ($TenantId -and -not (Test-MiOpsTenantId -TenantId $TenantId)) {
        throw 'TenantId must be a tenant domain name or GUID.'
    }
    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) {
        throw 'Azure CLI (az) is not installed or not on PATH.'
    }

    $arguments = @('login')
    if ($TenantId) {
        $arguments += @('--tenant', $TenantId)
    }
    $arguments += @('--only-show-errors', '--output', 'none')
    if ($UseDeviceCode) {
        $arguments += '--use-device-code'
    }

    $loginOutput = @(& $az.Source @arguments 2>&1 | ForEach-Object {
        Write-Host ([string]$_)
        $_
    })
    if ($LASTEXITCODE -ne 0) {
        $detail = ConvertTo-MiOpsRedactedObject -InputObject (($loginOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = 'Azure CLI returned no additional error text.'
        }
        throw "Azure CLI interactive login failed. $detail Conditional Access and device-compliance requirements cannot be bypassed by changing login mode; use an organization-approved managed device or contact the tenant administrator."
    }

    try {
        $account = Invoke-MiOpsAzJson -Arguments @('account', 'show')
        $subscriptions = @(Invoke-MiOpsAzJson -Arguments @('account', 'list', '--all'))
    }
    catch {
        throw "Azure CLI login completed, but the signed-in account context could not be read: $($_.Exception.Message)"
    }
    return [pscustomobject]@{
        account = $account
        subscriptions = $subscriptions
    }
}

function ConvertTo-MiOpsTenantChoices {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Subscriptions)

    $choices = [ordered]@{}
    foreach ($subscription in $Subscriptions) {
        $tenantId = [string](Get-MiOpsPropertyValue -InputObject $subscription -Name 'tenantId')
        if ([string]::IsNullOrWhiteSpace($tenantId) -or $choices.Contains($tenantId)) {
            continue
        }
        $choices[$tenantId] = [pscustomobject]@{
            tenantId = $tenantId
            defaultDomain = [string](Get-MiOpsPropertyValue -InputObject $subscription -Name 'tenantDefaultDomain')
            displayName = [string](Get-MiOpsPropertyValue -InputObject $subscription -Name 'tenantDisplayName')
        }
    }
    return @($choices.Values | Sort-Object defaultDomain, tenantId)
}

function Get-MiOpsTenants {
    [CmdletBinding()]
    param()

    return @(ConvertTo-MiOpsTenantChoices -Subscriptions @(Get-MiOpsEnabledSubscriptions))
}

function Resolve-MiOpsTenant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [object[]]$Tenants
    )

    if (-not (Test-MiOpsTenantId -TenantId $TenantId)) {
        throw 'TenantId must be a tenant domain name or GUID.'
    }
    if (-not $PSBoundParameters.ContainsKey('Tenants')) {
        $Tenants = @(Get-MiOpsTenants)
    }
    $match = @($Tenants | Where-Object {
        ([string](Get-MiOpsPropertyValue -InputObject $_ -Name 'tenantId') -ieq $TenantId) -or
        ([string](Get-MiOpsPropertyValue -InputObject $_ -Name 'defaultDomain') -ieq $TenantId)
    })
    if ($match.Count -ne 1) {
        $available = @($Tenants | ForEach-Object {
            $guid = [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'tenantId')
            $domain = [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'defaultDomain')
            if ($domain) { "$domain ($guid)" } else { $guid }
        } | Where-Object { $_ })
        $availableText = if ($available.Count -gt 0) { $available -join ', ' } else { 'none' }
        throw "Azure CLI could not resolve tenant domain '$TenantId' from optional account metadata. Available tenant GUIDs/domains: $availableText. Retry with the tenant GUID shown, or verify access with your tenant administrator."
    }
    return $match[0]
}

function Get-MiOpsEnabledSubscriptions {
    [CmdletBinding()]
    param([string]$TenantGuid)

    $subscriptions = @(Invoke-MiOpsAzJson -Arguments @('account', 'list', '--all'))
    return @($subscriptions |
        Where-Object {
            [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'state') -eq 'Enabled' -and
            (-not $TenantGuid -or [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'tenantId') -ieq $TenantGuid)
        } |
        Sort-Object name, id)
}

function Set-MiOpsSubscription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantGuid
    )

    if (-not (Test-MiOpsSubscriptionId -SubscriptionId $SubscriptionId)) {
        throw 'SubscriptionId must be a GUID.'
    }
    $null = Invoke-MiOpsAzJson -Arguments @('account', 'set', '--subscription', $SubscriptionId) -AllowEmpty
    $account = Invoke-MiOpsAzJson -Arguments @('account', 'show')
    if ([string]$account.id -ine $SubscriptionId -or [string]$account.tenantId -ine $TenantGuid) {
        throw "Active Azure account does not match tenant '$TenantGuid' and subscription '$SubscriptionId'."
    }
    return $account
}

function Get-MiOpsManagedInstances {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubscriptionId)

    if (-not (Test-MiOpsSubscriptionId -SubscriptionId $SubscriptionId)) {
        throw 'SubscriptionId must be a GUID.'
    }
    try {
        return @(Invoke-MiOpsAzJson -Arguments @('sql', 'mi', 'list', '--subscription', $SubscriptionId))
    }
    catch {
        throw "Unable to enumerate Azure SQL Managed Instances in subscription '$SubscriptionId'. Verify Microsoft.Sql read permission. $($_.Exception.Message)"
    }
}

function New-MiOpsLocalConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExamplePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $ExamplePath))
    )

    if (-not (Test-MiOpsTenantId -TenantId $TenantId)) {
        throw 'TenantId must be a tenant domain name or GUID.'
    }
    if (-not (Test-MiOpsSubscriptionId -SubscriptionId $SubscriptionId)) {
        throw 'SubscriptionId must be a GUID.'
    }
    if ($ResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Sql/managedInstances/[^/]+$') {
        throw 'ResourceId must be a complete Azure SQL Managed Instance resource ID.'
    }
    $resourceSubscription = ([regex]::Match($ResourceId, '(?i)^/subscriptions/([^/]+)')).Groups[1].Value
    if ($resourceSubscription -ine $SubscriptionId) {
        throw 'The Managed Instance resource ID does not belong to the selected subscription.'
    }
    if (-not (Test-Path -LiteralPath $ExamplePath -PathType Leaf)) {
        throw "Example configuration file not found: $ExamplePath"
    }

    $config = Get-Content -LiteralPath $ExamplePath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    $config.resource.id = $ResourceId
    $config.resource.allowedResourceIds = @($ResourceId)
    $config.onboarding = [ordered]@{
        tenantId = $TenantId
        subscriptionId = $SubscriptionId
        configuredAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $parent = Split-Path -Parent $DestinationPath
    if ($parent) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $DestinationPath -Encoding utf8
    return Get-MiOpsConfig -Path $DestinationPath -RepositoryRoot $RepositoryRoot
}

function Invoke-MiOpsAzJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowEmpty
    )

    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) {
        throw 'Azure CLI (az) is not installed or not on PATH.'
    }

    $output = @(& $az.Source @Arguments --only-show-errors --output json 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw "Azure CLI command failed (az $($Arguments -join ' ')): $text"
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        if ($AllowEmpty) {
            return $null
        }
        throw "Azure CLI returned no JSON for: az $($Arguments -join ' ')"
    }

    try {
        return $text | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Azure CLI returned invalid JSON for az $($Arguments -join ' '): $text"
    }
}

function Get-MiOpsStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $resourceId = [string]$Config.resource.id
    if (-not (Test-MiOpsResourceAllowed -Config $Config -ResourceId $resourceId)) {
        throw "Resource is not allowlisted: $resourceId"
    }

    $resource = Invoke-MiOpsAzJson -Arguments @('sql', 'mi', 'show', '--ids', $resourceId)
    $result = [ordered]@{
        collectedAtUtc = [DateTime]::UtcNow.ToString('o')
        resourceId = $resource.id
        name = $resource.name
        location = $resource.location
        state = $resource.state
        provisioningState = $resource.provisioningState
        sku = $resource.sku
        vCores = $resource.vCores
        storageSizeInGb = $resource.storageSizeInGb
        zoneRedundant = $resource.zoneRedundant
        lifecycleEligibility = Get-MiOpsLifecycleEligibility -Config $Config -Resource $resource
        tenantValidated = $false
    }
    Write-MiOpsAudit -Config $Config -Event 'status.read' -Data $result
    return [pscustomobject]$result
}

function Get-MiOpsLifecycleEligibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Resource
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $tier = [string]$Resource.sku.tier
    if ($Config.safety.allowedLifecycleTiers -and $tier -notin @($Config.safety.allowedLifecycleTiers)) {
        $reasons.Add("SKU tier '$tier' is not in safety.allowedLifecycleTiers.")
    }
    if ($Resource.instancePoolId) {
        $reasons.Add('Instances in an instance pool are not enabled by this MVP safety policy.')
    }
    if ([string]$Resource.provisioningState -and [string]$Resource.provisioningState -ne 'Succeeded') {
        $reasons.Add("Provisioning state is '$($Resource.provisioningState)', not Succeeded.")
    }

    return [pscustomobject]@{
        eligibleByLocalPolicy = ($reasons.Count -eq 0)
        reasons = @($reasons)
        note = 'Azure remains authoritative. Local eligibility checks are conservative and do not prove platform support.'
    }
}

function Assert-MiOpsMutationApproval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ResourceId,
        [switch]$Apply,
        [string]$ApproveResourceId
    )

    if (-not (Test-MiOpsResourceAllowed -Config $Config -ResourceId $ResourceId)) {
        throw "Resource is not allowlisted: $ResourceId"
    }

    if (-not $Apply) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($ApproveResourceId) -or $ApproveResourceId.TrimEnd('/') -ine $ResourceId.TrimEnd('/')) {
        throw 'Mutation requires -Apply and -ApproveResourceId with the exact allowlisted resource ID.'
    }

    return $true
}

function Save-MiOpsOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Operation
    )

    Initialize-MiOpsState -Config $Config
    $path = Join-Path (Join-Path $Config.state.directory 'operations') "$($Operation.operationId).json"
    ConvertTo-MiOpsRedactedObject -InputObject $Operation |
        ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

function Get-MiOpsOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$OperationId
    )

    $path = Join-Path (Join-Path $Config.state.directory 'operations') "$OperationId.json"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Operation not found: $OperationId"
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 30
}

function Invoke-MiOpsLifecycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][ValidateSet('Start', 'Stop')][string]$Action,
        [switch]$Apply,
        [string]$ApproveResourceId
    )

    $resourceId = [string]$Config.resource.id
    $approved = Assert-MiOpsMutationApproval -Config $Config -ResourceId $resourceId -Apply:$Apply -ApproveResourceId $ApproveResourceId
    $status = Get-MiOpsStatus -Config $Config
    if (-not $status.lifecycleEligibility.eligibleByLocalPolicy) {
        throw "Lifecycle action blocked by local eligibility checks: $($status.lifecycleEligibility.reasons -join '; ')"
    }

    $operation = [ordered]@{
        operationId = [Guid]::NewGuid().ToString()
        action = $Action.ToLowerInvariant()
        resourceId = $resourceId
        desiredState = if ($Action -eq 'Start') { 'Ready' } else { 'Stopped' }
        status = if ($approved) { 'Ready' } else { 'DryRun' }
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        initialResourceState = $status.state
        azureOperationId = $null
        azureResponse = $null
        verification = $null
    }
    $path = Save-MiOpsOperation -Config $Config -Operation $operation

    if (-not $approved) {
        Write-MiOpsAudit -Config $Config -Event 'lifecycle.dry-run' -Data $operation
        return [pscustomobject]@{
            mode = 'dry-run'
            message = "No Azure mutation was executed. Re-run with -Apply -ApproveResourceId '$resourceId'."
            operation = $operation
            operationPath = $path
        }
    }

    $operation.status = 'Submitting'
    $operation.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $null = Save-MiOpsOperation -Config $Config -Operation $operation
    Write-MiOpsAudit -Config $Config -Event 'lifecycle.submitting' -Data $operation

    try {
        $response = Invoke-MiOpsAzJson -Arguments @('sql', 'mi', $Action.ToLowerInvariant(), '--ids', $resourceId, '--no-wait') -AllowEmpty
        $operation.azureResponse = $response
        if ($response) {
            $candidate = @('operationId', 'azureAsyncOperation', 'name') |
                ForEach-Object {
                    $property = $response.PSObject.Properties[$_]
                    if ($property) { $property.Value }
                } |
                Where-Object { $_ } |
                Select-Object -First 1
            $operation.azureOperationId = $candidate
        }
        $operation.status = 'Submitted'
    }
    catch {
        $operation.status = 'Failed'
        $operation.error = $_.Exception.Message
        $operation.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        $null = Save-MiOpsOperation -Config $Config -Operation $operation
        Write-MiOpsAudit -Config $Config -Event 'lifecycle.failed' -Data $operation
        throw
    }

    $operation.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $path = Save-MiOpsOperation -Config $Config -Operation $operation
    Write-MiOpsAudit -Config $Config -Event 'lifecycle.submitted' -Data $operation
    return [pscustomobject]@{
        mode = 'apply'
        message = 'Azure accepted the non-blocking CLI request. Poll the local operation until independently verified.'
        operation = $operation
        operationPath = $path
    }
}

function Update-MiOpsOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$OperationId
    )

    $operation = Get-MiOpsOperation -Config $Config -OperationId $OperationId
    if (-not (Test-MiOpsResourceAllowed -Config $Config -ResourceId $operation.resourceId)) {
        throw "Operation target is no longer allowlisted: $($operation.resourceId)"
    }
    if ([string]$operation.status -eq 'Verified') {
        return [pscustomobject]@{
            operation = $operation
            operationPath = Join-Path (Join-Path $Config.state.directory 'operations') "$OperationId.json"
        }
    }
    if ([string]$operation.status -notin @('Submitted', 'InProgress')) {
        throw "Operation '$OperationId' cannot be polled because its status is '$($operation.status)'. Only successfully submitted operations can be verified."
    }

    $resource = Invoke-MiOpsAzJson -Arguments @('sql', 'mi', 'show', '--ids', $operation.resourceId)
    $observedState = [string]$resource.state
    $terminalFailureStates = @('Failed', 'Canceled', 'Cancelled')
    if ($observedState -eq [string]$operation.desiredState) {
        $operation.status = 'Verified'
        $operation.verification = [ordered]@{
            observedState = $observedState
            provisioningState = $resource.provisioningState
            verifiedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
    }
    elseif ($observedState -in $terminalFailureStates -or [string]$resource.provisioningState -in $terminalFailureStates) {
        $operation.status = 'Failed'
        $operation.verification = [ordered]@{
            observedState = $observedState
            provisioningState = $resource.provisioningState
            checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
    }
    else {
        $operation.status = 'InProgress'
        $operation.verification = [ordered]@{
            observedState = $observedState
            provisioningState = $resource.provisioningState
            checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
    }
    $operation.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $path = Save-MiOpsOperation -Config $Config -Operation $operation
    Write-MiOpsAudit -Config $Config -Event 'lifecycle.polled' -Data $operation
    return [pscustomobject]@{
        operation = $operation
        operationPath = $path
    }
}

function Invoke-MiOpsPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $checks = [System.Collections.Generic.List[object]]::new()
    $checks.Add([pscustomobject]@{
        name = 'az-cli'
        status = if (Get-Command az -ErrorAction SilentlyContinue) { 'pass' } else { 'fail' }
        detail = 'Azure CLI must be installed and on PATH.'
    })
    if ($checks[-1].status -eq 'fail') {
        return [pscustomobject]@{ checks = $checks; ready = $false; tenantValidated = $false }
    }

    try {
        $version = Invoke-MiOpsAzJson -Arguments @('version')
        $checks.Add([pscustomobject]@{
            name = 'az-cli-version'
            status = 'pass'
            detail = "Azure CLI version: $($version.'azure-cli')."
        })
        $checks.Add([pscustomobject]@{
            name = 'required-extensions'
            status = 'pass'
            detail = 'No Azure CLI extension is required by the phase-1 command set.'
        })
    }
    catch {
        $checks.Add([pscustomobject]@{ name = 'az-cli-version'; status = 'fail'; detail = $_.Exception.Message })
    }

    try {
        $account = Invoke-MiOpsAzJson -Arguments @('account', 'show')
        $checks.Add([pscustomobject]@{
            name = 'az-login'
            status = 'pass'
            detail = "Signed in to subscription $($account.id) as $($account.user.name)."
        })
        $subscriptionFromResource = ([regex]::Match([string]$Config.resource.id, '(?i)/subscriptions/([^/]+)')).Groups[1].Value
        $checks.Add([pscustomobject]@{
            name = 'subscription-match'
            status = if ([string]$account.id -ieq $subscriptionFromResource) { 'pass' } else { 'fail' }
            detail = "Active subscription: $($account.id); configured subscription: $subscriptionFromResource."
        })
    }
    catch {
        $checks.Add([pscustomobject]@{ name = 'az-login'; status = 'fail'; detail = $_.Exception.Message })
    }

    foreach ($namespace in @('Microsoft.Sql', 'Microsoft.Insights', 'Microsoft.ResourceHealth')) {
        try {
            $provider = Invoke-MiOpsAzJson -Arguments @('provider', 'show', '--namespace', $namespace)
            $checks.Add([pscustomobject]@{
                name = "provider-$namespace"
                status = if ($provider.registrationState -eq 'Registered') { 'pass' } else { 'warn' }
                detail = "Registration state: $($provider.registrationState)."
            })
        }
        catch {
            $checks.Add([pscustomobject]@{ name = "provider-$namespace"; status = 'warn'; detail = $_.Exception.Message })
        }
    }

    try {
        $null = Invoke-MiOpsAzJson -Arguments @('sql', 'mi', 'show', '--ids', [string]$Config.resource.id)
        $checks.Add([pscustomobject]@{
            name = 'mi-read-permission'
            status = 'pass'
            detail = 'Managed Instance can be read. Lifecycle write permissions are only proven by an approved action.'
        })
    }
    catch {
        $checks.Add([pscustomobject]@{ name = 'mi-read-permission'; status = 'fail'; detail = $_.Exception.Message })
    }

    $checks.Add([pscustomobject]@{
        name = 'sql-diagnostics'
        status = if ($Config.sqlDiagnostics.enabled) { 'warn' } else { 'info' }
        detail = 'Optional SQL adapter is separate from Azure RBAC and is not exercised by preflight.'
    })
    $checks.Add([pscustomobject]@{
        name = 'support-submission'
        status = 'info'
        detail = 'Phase 1 creates support drafts only. Support REST API submission and entitlement are not assumed.'
    })

    $result = [pscustomobject]@{
        checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        checks = $checks
        ready = -not (@($checks | Where-Object status -eq 'fail').Count)
        tenantValidated = $false
        note = 'Preflight observes login, provider registration, and read access. It cannot prove all write permissions or MI feature eligibility.'
    }
    Write-MiOpsAudit -Config $Config -Event 'preflight.completed' -Data $result
    return $result
}

function Get-MiOpsSchedule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $resourceId = [string]$Config.resource.id
    if (-not (Test-MiOpsResourceAllowed -Config $Config -ResourceId $resourceId)) {
        throw "Resource is not allowlisted: $resourceId"
    }
    try {
        $schedule = Invoke-MiOpsAzJson -Arguments @('sql', 'mi', 'start-stop-schedule', 'show', '--ids', $resourceId)
        $result = [pscustomobject]@{
            supported = $true
            schedule = $schedule
            note = 'Inspection only. Phase 1 does not create or update automatic stop schedules.'
        }
    }
    catch {
        $result = [pscustomobject]@{
            supported = $false
            schedule = $null
            reason = $_.Exception.Message
            note = 'The Azure CLI command, MI configuration, API version, or permissions may not support schedule inspection.'
        }
    }
    Write-MiOpsAudit -Config $Config -Event 'schedule.read' -Data $result
    return $result
}

function New-MiOpsSchedulePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $result = [pscustomobject]@{
        mode = 'plan-only'
        resourceId = [string]$Config.resource.id
        automaticExecutionImplemented = $false
        requiredReview = @(
            'Confirm Azure schedule support for this MI configuration.',
            'Define timezone and weekly start/stop pairs.',
            'Review business impact and exception dates.',
            'Apply outside this MVP through an approved change process.'
        )
        note = 'Phase 1 intentionally does not create or update schedules because that would enable automatic stop.'
    }
    Write-MiOpsAudit -Config $Config -Event 'schedule.plan' -Data $result
    return $result
}

function Remove-MiOpsSchedule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [switch]$Apply,
        [string]$ApproveResourceId
    )

    $resourceId = [string]$Config.resource.id
    $approved = Assert-MiOpsMutationApproval -Config $Config -ResourceId $resourceId -Apply:$Apply -ApproveResourceId $ApproveResourceId
    $scheduleId = "$resourceId/startStopSchedules/default"
    if (-not $approved) {
        $result = [pscustomobject]@{
            mode = 'dry-run'
            action = 'delete-existing-schedule'
            scheduleId = $scheduleId
            message = "No schedule was deleted. Re-run with -Apply -ApproveResourceId '$resourceId'."
        }
        Write-MiOpsAudit -Config $Config -Event 'schedule.delete.dry-run' -Data $result
        return $result
    }

    $null = Invoke-MiOpsAzJson -Arguments @('sql', 'mi', 'start-stop-schedule', 'delete', '--ids', $resourceId, '--yes') -AllowEmpty
    $result = [pscustomobject]@{
        mode = 'apply'
        action = 'delete-existing-schedule'
        scheduleId = $scheduleId
        status = 'submitted'
        note = 'Deletion disables the Azure-native automatic start/stop schedule. Verify with schedule-show.'
    }
    Write-MiOpsAudit -Config $Config -Event 'schedule.delete.submitted' -Data $result
    return $result
}

function Get-MiOpsEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [int]$LookbackHours = 0
    )

    Initialize-MiOpsState -Config $Config
    if ($LookbackHours -le 0) {
        $LookbackHours = [int]$Config.evidence.defaultLookbackHours
    }
    if ($LookbackHours -lt 1 -or $LookbackHours -gt 168) {
        throw 'LookbackHours must be between 1 and 168.'
    }

    $resourceId = [string]$Config.resource.id
    if (-not (Test-MiOpsResourceAllowed -Config $Config -ResourceId $resourceId)) {
        throw "Resource is not allowlisted: $resourceId"
    }

    $end = [DateTime]::UtcNow
    $start = $end.AddHours(-$LookbackHours)
    $gaps = [System.Collections.Generic.List[string]]::new()
    $resource = Invoke-MiOpsAzJson -Arguments @('sql', 'mi', 'show', '--ids', $resourceId)

    $activityLimit = 1000
    try {
        $activity = Invoke-MiOpsAzJson -Arguments @(
            'monitor', 'activity-log', 'list',
            '--resource-id', $resourceId,
            '--start-time', $start.ToString('o'),
            '--end-time', $end.ToString('o'),
            '--max-events', [string]$activityLimit
        )
        if (@($activity).Count -ge $activityLimit) {
            $gaps.Add("Activity Log reached the explicit $activityLimit-event limit and may be truncated.")
        }
    }
    catch {
        $activity = @()
        $gaps.Add("Activity Log unavailable: $($_.Exception.Message)")
    }

    try {
        $healthUrl = "https://management.azure.com$resourceId/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=$($Config.azure.resourceHealthApiVersion)"
        $health = Invoke-MiOpsAzJson -Arguments @('rest', '--method', 'get', '--url', $healthUrl)
    }
    catch {
        $health = $null
        $gaps.Add("Resource Health unavailable: $($_.Exception.Message)")
    }

    $metrics = [ordered]@{}
    try {
        $definitions = Invoke-MiOpsAzJson -Arguments @('monitor', 'metrics', 'list-definitions', '--resource', $resourceId)
        $availableMetricNames = @($definitions | ForEach-Object { [string]$_.name.value })
        foreach ($metricName in @($Config.evidence.metricNames)) {
            if ($metricName -notin $availableMetricNames) {
                $gaps.Add("Configured metric '$metricName' is not advertised for this resource.")
                continue
            }
            try {
                $metrics[$metricName] = Invoke-MiOpsAzJson -Arguments @(
                    'monitor', 'metrics', 'list',
                    '--resource', $resourceId,
                    '--metric', [string]$metricName,
                    '--start-time', $start.ToString('o'),
                    '--end-time', $end.ToString('o'),
                    '--interval', 'PT1H',
                    '--aggregation', 'Average', 'Maximum'
                )
            }
            catch {
                $gaps.Add("Metric '$metricName' unavailable: $($_.Exception.Message)")
            }
        }
    }
    catch {
        $gaps.Add("Metric definitions unavailable: $($_.Exception.Message)")
    }

    $bundle = [ordered]@{
        schemaVersion = 1
        collectedAtUtc = $end.ToString('o')
        window = [ordered]@{ startUtc = $start.ToString('o'); endUtc = $end.ToString('o') }
        resource = $resource
        activityLog = $activity
        resourceHealth = $health
        metrics = $metrics
        sqlDiagnostics = [ordered]@{
            included = $false
            reason = 'SQL adapter is optional and not invoked by Azure evidence collection. Azure RBAC does not grant DMV or Query Store access.'
        }
        evidenceGaps = @($gaps)
        limitations = @(
            'This bundle contains Azure control-plane and monitoring evidence only.',
            'Metric availability and retention vary by resource and monitoring configuration.',
            'No capacity resize or remediation is executed.'
        )
        tenantValidated = $false
    }

    $safeBundle = ConvertTo-MiOpsRedactedObject -InputObject $bundle
    $fileName = "evidence-$($end.ToString('yyyyMMddTHHmmssZ')).json"
    $path = Join-Path (Join-Path $Config.state.directory 'evidence') $fileName
    $safeBundle | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8
    Write-MiOpsAudit -Config $Config -Event 'evidence.collected' -Data @{
        resourceId = $resourceId
        path = $path
        evidenceGaps = @($gaps)
    }
    return [pscustomobject]@{
        path = $path
        evidenceGaps = @($gaps)
        bundle = $safeBundle
    }
}

function New-MiOpsSupportDraft {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Impact
    )

    if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
        throw "Evidence bundle not found: $EvidencePath"
    }
    Initialize-MiOpsState -Config $Config
    $evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json -Depth 100
    if ([string]$evidence.resource.id -and -not (Test-MiOpsResourceAllowed -Config $Config -ResourceId ([string]$evidence.resource.id))) {
        throw 'Evidence bundle resource is not allowlisted.'
    }

    $draft = [ordered]@{
        schemaVersion = 1
        status = 'Drafted'
        submissionEnabled = $false
        title = $Title
        affectedResourceId = [string]$Config.resource.id
        impact = $Impact
        incidentWindow = $evidence.window
        currentState = $evidence.resource.state
        provisioningState = $evidence.resource.provisioningState
        resourceHealth = if ($evidence.resourceHealth) { $evidence.resourceHealth.properties } else { $null }
        evidenceGaps = $evidence.evidenceGaps
        troubleshootingPerformed = @(
            'Collected Azure Resource Manager configuration.',
            'Collected available Azure Activity Log events.',
            'Collected available Resource Health status.',
            'Collected configured Azure Monitor metrics where advertised.'
        )
        requestedAssistance = 'Please help validate the service condition and identify additional Azure-side diagnostics or mitigation.'
        excludedData = @(
            'Credentials, tokens, and connection strings',
            'SQL query text and result values',
            'DMV and Query Store data unless separately reviewed and attached'
        )
        prerequisiteNotice = 'Microsoft Support REST API creation is not implemented in phase 1. Eligibility depends on support plan, tenant entitlement, provider registration, and authorization.'
        sourceEvidencePath = [System.IO.Path]::GetFileName($EvidencePath)
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        tenantValidated = $false
    }

    $safeDraft = ConvertTo-MiOpsRedactedObject -InputObject $draft
    $path = Join-Path (Join-Path $Config.state.directory 'support') "support-draft-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')).json"
    $safeDraft | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path -Encoding utf8
    Write-MiOpsAudit -Config $Config -Event 'support.draft.created' -Data @{
        path = $path
        resourceId = [string]$Config.resource.id
        title = $Title
    }
    return [pscustomobject]@{
        path = $path
        draft = $safeDraft
        note = 'Draft only. Review redaction and entitlement before any future API submission.'
    }
}

function Get-MiOpsSqlAdapterStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    return [pscustomobject]@{
        enabled = [bool]$Config.sqlDiagnostics.enabled
        adapter = $Config.sqlDiagnostics.adapter
        implemented = $false
        requiredBoundary = 'Use a separate least-privilege SQL identity and reviewed read-only DMV/Query Store queries. Do not require sysadmin.'
        note = 'Phase 1 does not fabricate or infer SQL-engine diagnostics from Azure control-plane evidence.'
    }
}

Export-ModuleMember -Function @(
    'Get-MiOpsConfig',
    'Test-MiOpsResourceAllowed',
    'Test-MiOpsTenantId',
    'Test-MiOpsSubscriptionId',
    'Get-MiOpsPropertyValue',
    'Select-MiOpsNumberedItem',
    'Test-MiOpsTypedConfirmation',
    'Invoke-MiOpsAzLogin',
    'ConvertTo-MiOpsTenantChoices',
    'Get-MiOpsTenants',
    'Resolve-MiOpsTenant',
    'Get-MiOpsEnabledSubscriptions',
    'Set-MiOpsSubscription',
    'Get-MiOpsManagedInstances',
    'New-MiOpsLocalConfig',
    'ConvertTo-MiOpsRedactedObject',
    'Invoke-MiOpsPreflight',
    'Get-MiOpsStatus',
    'Get-MiOpsLifecycleEligibility',
    'Assert-MiOpsMutationApproval',
    'Save-MiOpsOperation',
    'Get-MiOpsOperation',
    'Invoke-MiOpsLifecycle',
    'Update-MiOpsOperation',
    'Get-MiOpsSchedule',
    'New-MiOpsSchedulePlan',
    'Remove-MiOpsSchedule',
    'Get-MiOpsEvidence',
    'New-MiOpsSupportDraft',
    'Get-MiOpsSqlAdapterStatus'
)
