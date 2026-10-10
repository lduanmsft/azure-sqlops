function Get-MiOpsResourceParts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ResourceId)

    $pattern = '^/subscriptions/(?<subscription>[^/]+)/resourceGroups/(?<resourceGroup>[^/]+)/providers/Microsoft\.Sql/managedInstances/(?<name>[^/]+)$'
    $match = [regex]::Match($ResourceId.TrimEnd('/'), $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw "Invalid Azure SQL Managed Instance resource ID: $ResourceId"
    }
    return [pscustomobject]@{
        resourceId = $ResourceId.TrimEnd('/')
        subscriptionId = $match.Groups['subscription'].Value
        resourceGroup = $match.Groups['resourceGroup'].Value
        name = $match.Groups['name'].Value
    }
}

function Invoke-MiOpsAzAdapter {
    param(
        [Parameter(Mandatory)][scriptblock]$Invoker,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowEmpty
    )

    return & $Invoker $Arguments ([bool]$AllowEmpty)
}

function Test-MiOpsSystemDatabase {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    return $Name -iin @('master', 'model', 'msdb', 'tempdb')
}

function ConvertTo-MiOpsDatabaseItems {
    [CmdletBinding()]
    param([object[]]$Databases)

    return @($Databases | ForEach-Object {
        $name = [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'name')
        $status = [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'status')
        if ([string]::IsNullOrWhiteSpace($status)) {
            $status = [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'state')
        }
        $creationDate = Get-MiOpsPropertyValue -InputObject $_ -Name 'creationDate'
        if (-not $creationDate) {
            $creationDate = Get-MiOpsPropertyValue -InputObject $_ -Name 'creationDateTime'
        }
        $sourceDatabaseId = Get-MiOpsPropertyValue -InputObject $_ -Name 'sourceDatabaseId'
        if (-not $sourceDatabaseId) {
            $sourceDatabaseId = Get-MiOpsPropertyValue -InputObject $_ -Name 'sourceDatabaseResourceId'
        }
        [pscustomobject][ordered]@{
            name = $name
            status = $status
            creationDate = if ($creationDate) { [string]$creationDate } else { $null }
            earliestRestoreDate = if (Get-MiOpsPropertyValue -InputObject $_ -Name 'earliestRestoreDate') {
                [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'earliestRestoreDate')
            } else { $null }
            sourceDatabaseId = if ($sourceDatabaseId) { [string]$sourceDatabaseId } else { $null }
            restorePointInTime = if (Get-MiOpsPropertyValue -InputObject $_ -Name 'restorePointInTime') {
                [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'restorePointInTime')
            } else { $null }
            resourceId = [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'id')
            isSystemDatabase = Test-MiOpsSystemDatabase -Name $name
        }
    })
}

function Get-MiOpsDatabaseList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$ManagedInstanceId,
        [scriptblock]$AzInvoker
    )

    if (-not $ManagedInstanceId) {
        $ManagedInstanceId = [string]$Config.resource.id
    }
    if (-not (Test-MiOpsResourceAllowed -Config $Config -ResourceId $ManagedInstanceId)) {
        throw "Database inventory source is not allowlisted: $ManagedInstanceId"
    }
    if (-not $AzInvoker) {
        $AzInvoker = { param($Arguments, $AllowEmpty) Invoke-MiOpsAzJson -Arguments $Arguments -AllowEmpty:$AllowEmpty }
    }

    $parts = Get-MiOpsResourceParts -ResourceId $ManagedInstanceId
    try {
        $instance = Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @('sql', 'mi', 'show', '--ids', $ManagedInstanceId)
    }
    catch {
        Write-MiOpsAudit -Config $Config -Event 'database.list.failed' -Data @{
            managedInstanceId = $ManagedInstanceId
            reason = $_.Exception.Message
        }
        throw "Unable to read the allowlisted Managed Instance before listing databases. Verify Azure login and Microsoft.Sql read permission. $($_.Exception.Message)"
    }

    $instanceState = [string](Get-MiOpsPropertyValue -InputObject $instance -Name 'state')
    $provisioningState = [string](Get-MiOpsPropertyValue -InputObject $instance -Name 'provisioningState')
    if ($instanceState -in @('Stopped', 'Stopping', 'Starting') -or $provisioningState -in @('Failed', 'Canceled', 'Cancelled')) {
        $result = [pscustomobject][ordered]@{
            collectedAtUtc = [DateTime]::UtcNow.ToString('o')
            managedInstanceId = $ManagedInstanceId
            managedInstanceName = $parts.name
            instanceState = $instanceState
            provisioningState = $provisioningState
            available = $false
            count = 0
            databases = @()
            excludedSystemDatabases = @()
            evidenceGaps = @("Database inventory was not attempted because the Managed Instance state is '$instanceState' and provisioning state is '$provisioningState'.")
        }
        Write-MiOpsAudit -Config $Config -Event 'database.list.unavailable' -Data $result
        return $result
    }

    try {
        $raw = @(Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @(
            'sql', 'midb', 'list',
            '--resource-group', $parts.resourceGroup,
            '--managed-instance', $parts.name,
            '--subscription', $parts.subscriptionId
        ))
    }
    catch {
        Write-MiOpsAudit -Config $Config -Event 'database.list.failed' -Data @{
            managedInstanceId = $ManagedInstanceId
            reason = $_.Exception.Message
        }
        throw "Unable to list databases for '$($parts.name)'. The instance may be unavailable, the caller may lack Microsoft.Sql database read permission, or the Azure CLI schema may differ. $($_.Exception.Message)"
    }

    $shaped = @(ConvertTo-MiOpsDatabaseItems -Databases $raw)
    $system = @($shaped | Where-Object isSystemDatabase)
    $user = @($shaped | Where-Object { -not $_.isSystemDatabase })
    $result = [pscustomobject][ordered]@{
        collectedAtUtc = [DateTime]::UtcNow.ToString('o')
        managedInstanceId = $ManagedInstanceId
        managedInstanceName = $parts.name
        instanceState = $instanceState
        provisioningState = $provisioningState
        available = $true
        count = $user.Count
        databases = $user
        excludedSystemDatabases = @($system | Select-Object -ExpandProperty name)
        evidenceGaps = @()
        note = if ($user.Count -eq 0) {
            'Azure returned no user databases. System databases are excluded from operational inventory and restore.'
        } else {
            'System databases are excluded. Fields not exposed by the current Azure CLI/API schema are null.'
        }
    }
    Write-MiOpsAudit -Config $Config -Event 'database.list.read' -Data @{
        managedInstanceId = $ManagedInstanceId
        query = 'az sql midb list'
        count = $user.Count
        excludedSystemDatabaseCount = $system.Count
    }
    return $result
}

function Test-MiOpsUtcTimestamp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Timestamp)

    if ($Timestamp -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$') {
        return $false
    }
    $parsed = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParse(
        $Timestamp,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
        [ref]$parsed
    )
}

function Test-MiOpsDatabaseName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if (Test-MiOpsSystemDatabase -Name $Name) {
        return $false
    }
    return $Name -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
}

function Test-MiOpsRestoreTargetAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ResourceId
    )

    $normalized = $ResourceId.TrimEnd('/').ToLowerInvariant()
    return @($Config.restoreTargets.allowedResourceIds | ForEach-Object {
        ([string]$_).TrimEnd('/').ToLowerInvariant()
    }) -contains $normalized
}

function Add-MiOpsRestoreTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$TargetManagedInstanceId,
        [Parameter(Mandatory)][string]$TypedConfirmation,
        [scriptblock]$AzInvoker
    )

    $parts = Get-MiOpsResourceParts -ResourceId $TargetManagedInstanceId
    $expected = "CONFIGURE RESTORE TARGET $($parts.name)"
    if ($TypedConfirmation -cne $expected) {
        throw "Typed confirmation did not exactly match '$expected'. No restore target was configured."
    }
    if (-not $AzInvoker) {
        $AzInvoker = { param($Arguments, $AllowEmpty) Invoke-MiOpsAzJson -Arguments $Arguments -AllowEmpty:$AllowEmpty }
    }
    $target = Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @('sql', 'mi', 'show', '--ids', $TargetManagedInstanceId)
    if ([string](Get-MiOpsPropertyValue -InputObject $target -Name 'id') -ine $TargetManagedInstanceId) {
        throw 'Azure returned a different Managed Instance than the requested restore target.'
    }

    $path = [string]$Config._configPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw 'The loaded configuration has no writable source path.'
    }
    $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    if (-not $raw.ContainsKey('restoreTargets')) {
        $raw.restoreTargets = @{ allowedResourceIds = @() }
    }
    $targets = @($raw.restoreTargets.allowedResourceIds)
    if ($targets -notcontains $TargetManagedInstanceId) {
        $raw.restoreTargets.allowedResourceIds = @($targets + $TargetManagedInstanceId)
        $raw | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8
    }
    Write-MiOpsAudit -Config $Config -Event 'restore.target.configured' -Data @{
        targetManagedInstanceId = $TargetManagedInstanceId
        targetManagedInstanceName = $parts.name
    }
    return Get-MiOpsConfig -Path $path -RepositoryRoot ([string]$Config._repositoryRoot)
}

function Test-MiOpsRestoreConfirmation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDatabase,
        [Parameter(Mandatory)][string]$TargetManagedInstanceName,
        [Parameter(Mandatory)][string]$TargetDatabase,
        [Parameter(Mandatory)][string]$RestoreTimeUtc,
        [Parameter(Mandatory)][string]$Confirmation
    )

    return $Confirmation -ceq "RESTORE $SourceDatabase TO $TargetManagedInstanceName/$TargetDatabase AT $RestoreTimeUtc"
}

function Get-MiOpsSubscriptionTenants {
    param([Parameter(Mandatory)][scriptblock]$AzInvoker)

    $subscriptions = @(Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @('account', 'list', '--all'))
    $map = @{}
    foreach ($subscription in $subscriptions) {
        $id = [string](Get-MiOpsPropertyValue -InputObject $subscription -Name 'id')
        $tenantId = [string](Get-MiOpsPropertyValue -InputObject $subscription -Name 'tenantId')
        if ($id -and $tenantId) {
            $map[$id.ToLowerInvariant()] = $tenantId
        }
    }
    return $map
}

function Get-MiOpsRestorePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$SourceDatabase,
        [Parameter(Mandatory)][string]$TargetManagedInstanceId,
        [Parameter(Mandatory)][string]$TargetDatabase,
        [Parameter(Mandatory)][string]$RestoreTimeUtc,
        [string]$SourceManagedInstanceId,
        [scriptblock]$AzInvoker
    )

    if (-not $SourceManagedInstanceId) {
        $SourceManagedInstanceId = [string]$Config.resource.id
    }
    if (-not (Test-MiOpsResourceAllowed -Config $Config -ResourceId $SourceManagedInstanceId)) {
        throw "Restore source is not allowlisted: $SourceManagedInstanceId"
    }
    if (-not (Test-MiOpsRestoreTargetAllowed -Config $Config -ResourceId $TargetManagedInstanceId)) {
        throw "Restore target is not explicitly allowlisted: $TargetManagedInstanceId. Configure it with configure-restore-target first."
    }
    if (-not (Test-MiOpsDatabaseName -Name $SourceDatabase)) {
        throw "Source database name is unsafe or is a system database: $SourceDatabase"
    }
    if (-not (Test-MiOpsDatabaseName -Name $TargetDatabase)) {
        throw "Target database name is unsafe or is a system database: $TargetDatabase"
    }
    if (-not (Test-MiOpsUtcTimestamp -Timestamp $RestoreTimeUtc)) {
        throw 'RestoreTimeUtc must be strict ISO-8601 UTC, for example 2026-10-10T01:00:00Z.'
    }
    $restoreTime = [DateTimeOffset]::Parse($RestoreTimeUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    if ($restoreTime -ge [DateTimeOffset]::UtcNow) {
        throw 'RestoreTimeUtc must be earlier than the current UTC time.'
    }
    if (-not $AzInvoker) {
        $AzInvoker = { param($Arguments, $AllowEmpty) Invoke-MiOpsAzJson -Arguments $Arguments -AllowEmpty:$AllowEmpty }
    }

    $sourceParts = Get-MiOpsResourceParts -ResourceId $SourceManagedInstanceId
    $targetParts = Get-MiOpsResourceParts -ResourceId $TargetManagedInstanceId
    $sourceMi = Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @('sql', 'mi', 'show', '--ids', $SourceManagedInstanceId)
    $targetMi = Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @('sql', 'mi', 'show', '--ids', $TargetManagedInstanceId)
    foreach ($item in @(
        @{ label = 'source'; value = $sourceMi },
        @{ label = 'target'; value = $targetMi }
    )) {
        $state = [string](Get-MiOpsPropertyValue -InputObject $item.value -Name 'state')
        $provisioning = [string](Get-MiOpsPropertyValue -InputObject $item.value -Name 'provisioningState')
        if ($state -ne 'Ready' -or $provisioning -ne 'Succeeded') {
            throw "The $($item.label) Managed Instance must be Ready with provisioningState Succeeded. Observed state '$state', provisioningState '$provisioning'."
        }
    }
    $sourceLocation = [string](Get-MiOpsPropertyValue -InputObject $sourceMi -Name 'location')
    $targetLocation = [string](Get-MiOpsPropertyValue -InputObject $targetMi -Name 'location')
    $sourceSku = Get-MiOpsPropertyValue -InputObject $sourceMi -Name 'sku'
    $targetSku = Get-MiOpsPropertyValue -InputObject $targetMi -Name 'sku'
    if ($sourceLocation -ine $targetLocation) {
        throw "Point-in-time restore requires source and target Managed Instances in the same region. Source '$sourceLocation', target '$targetLocation'."
    }
    if ($sourceParts.subscriptionId -ine $targetParts.subscriptionId) {
        $tenantMap = Get-MiOpsSubscriptionTenants -AzInvoker $AzInvoker
        if (-not $tenantMap.ContainsKey($sourceParts.subscriptionId.ToLowerInvariant()) -or
            -not $tenantMap.ContainsKey($targetParts.subscriptionId.ToLowerInvariant())) {
            throw 'Unable to verify the source and target subscription tenants from Azure CLI account metadata.'
        }
        if ($tenantMap[$sourceParts.subscriptionId.ToLowerInvariant()] -ine $tenantMap[$targetParts.subscriptionId.ToLowerInvariant()]) {
            throw 'Cross-subscription point-in-time restore requires both subscriptions to be in the same Microsoft Entra tenant.'
        }
    }

    $sourceInventory = Get-MiOpsDatabaseList -Config $Config -ManagedInstanceId $SourceManagedInstanceId -AzInvoker $AzInvoker
    if (-not $sourceInventory.available) {
        throw 'Source database inventory is unavailable because the source Managed Instance is not operational.'
    }
    $sourceMatches = @($sourceInventory.databases | Where-Object name -CEQ $SourceDatabase)
    if ($sourceMatches.Count -ne 1) {
        throw "Source database '$SourceDatabase' was not found exactly once on '$($sourceParts.name)'."
    }
    $source = $sourceMatches[0]
    if ([string]$source.status -and [string]$source.status -ne 'Online') {
        throw "Source database '$SourceDatabase' is not Online. Observed status '$($source.status)'."
    }
    if ($source.earliestRestoreDate) {
        $earliest = [DateTimeOffset]::Parse([string]$source.earliestRestoreDate, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        if ($restoreTime -lt $earliest) {
            throw "RestoreTimeUtc is earlier than the source database earliestRestoreDate '$($source.earliestRestoreDate)'."
        }
    }

    $targetConfig = $Config.Clone()
    $targetConfig.resource = @{ id = $TargetManagedInstanceId; allowedResourceIds = @($TargetManagedInstanceId) }
    $targetInventory = Get-MiOpsDatabaseList -Config $targetConfig -ManagedInstanceId $TargetManagedInstanceId -AzInvoker $AzInvoker
    if (-not $targetInventory.available) {
        throw 'Target database inventory is unavailable because the target Managed Instance is not operational.'
    }
    if (@($targetInventory.databases | Where-Object name -CEQ $TargetDatabase).Count -gt 0) {
        throw "Target database '$TargetDatabase' already exists on '$($targetParts.name)'. Restore never overwrites an existing database."
    }

    $arguments = @(
        'sql', 'midb', 'restore',
        '--source-sub', $sourceParts.subscriptionId,
        '--resource-group', $sourceParts.resourceGroup,
        '--managed-instance', $sourceParts.name,
        '--name', $SourceDatabase,
        '--dest-name', $TargetDatabase,
        '--dest-mi', $targetParts.name,
        '--dest-resource-group', $targetParts.resourceGroup,
        '--time', $RestoreTimeUtc,
        '--subscription', $targetParts.subscriptionId,
        '--no-wait'
    )
    $plan = [pscustomobject][ordered]@{
        mode = 'dry-run'
        sourceManagedInstanceId = $SourceManagedInstanceId
        sourceManagedInstanceName = $sourceParts.name
        sourceDatabase = $SourceDatabase
        targetManagedInstanceId = $TargetManagedInstanceId
        targetManagedInstanceName = $targetParts.name
        targetDatabase = $TargetDatabase
        restoreTimeUtc = $RestoreTimeUtc
        sourceSubscriptionId = $sourceParts.subscriptionId
        targetSubscriptionId = $targetParts.subscriptionId
        sourceLocation = $sourceLocation
        targetLocation = $targetLocation
        sourceServiceTier = [string](Get-MiOpsPropertyValue -InputObject $sourceSku -Name 'tier')
        targetServiceTier = [string](Get-MiOpsPropertyValue -InputObject $targetSku -Name 'tier')
        earliestRestoreDate = $source.earliestRestoreDate
        detectedConstraints = @(
            'Only user databases are supported; system databases are rejected.',
            'The restore creates a new database and never overwrites an existing destination.',
            'Source and target Managed Instances must be Ready and in the same region.',
            'Cross-subscription PITR requires subscriptions in the same tenant and supported subscription types.',
            'Service endpoint policies, storage capacity, BYOK, primary-instance/primary-region rules, permissions, and backup availability can still cause Azure rejection.'
        )
        requiredConfirmation = "RESTORE $SourceDatabase TO $($targetParts.name)/$TargetDatabase AT $RestoreTimeUtc"
        azureCliArguments = $arguments
    }
    Write-MiOpsAudit -Config $Config -Event 'restore.plan' -Data @{
        sourceManagedInstanceId = $SourceManagedInstanceId
        sourceDatabase = $SourceDatabase
        targetManagedInstanceId = $TargetManagedInstanceId
        targetDatabase = $TargetDatabase
        restoreTimeUtc = $RestoreTimeUtc
    }
    return $plan
}

function Invoke-MiOpsRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$SourceDatabase,
        [Parameter(Mandatory)][string]$TargetManagedInstanceId,
        [Parameter(Mandatory)][string]$TargetDatabase,
        [Parameter(Mandatory)][string]$RestoreTimeUtc,
        [string]$SourceManagedInstanceId,
        [switch]$Apply,
        [string]$ApproveSourceResourceId,
        [string]$ApproveTargetResourceId,
        [string]$TypedConfirmation,
        [scriptblock]$AzInvoker
    )

    if (-not $AzInvoker) {
        $AzInvoker = { param($Arguments, $AllowEmpty) Invoke-MiOpsAzJson -Arguments $Arguments -AllowEmpty:$AllowEmpty }
    }
    $plan = Get-MiOpsRestorePlan -Config $Config -SourceDatabase $SourceDatabase `
        -TargetManagedInstanceId $TargetManagedInstanceId -TargetDatabase $TargetDatabase `
        -RestoreTimeUtc $RestoreTimeUtc -SourceManagedInstanceId $SourceManagedInstanceId -AzInvoker $AzInvoker
    if (-not $Apply) {
        return $plan
    }
    if ([string]::IsNullOrWhiteSpace($ApproveSourceResourceId) -or
        [string]::IsNullOrWhiteSpace($ApproveTargetResourceId) -or
        $ApproveSourceResourceId.TrimEnd('/') -ine $plan.sourceManagedInstanceId.TrimEnd('/') -or
        $ApproveTargetResourceId.TrimEnd('/') -ine $plan.targetManagedInstanceId.TrimEnd('/')) {
        throw 'Restore apply requires exact -ApproveSourceResourceId and -ApproveTargetResourceId values matching the plan.'
    }
    if (-not (Test-MiOpsRestoreConfirmation -SourceDatabase $SourceDatabase `
        -TargetManagedInstanceName $plan.targetManagedInstanceName -TargetDatabase $TargetDatabase `
        -RestoreTimeUtc $RestoreTimeUtc -Confirmation $TypedConfirmation)) {
        throw "Typed confirmation did not exactly match '$($plan.requiredConfirmation)'. No restore was submitted."
    }

    $operation = [ordered]@{
        operationId = [Guid]::NewGuid().ToString()
        action = 'restore'
        status = 'Ready'
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        sourceManagedInstanceId = $plan.sourceManagedInstanceId
        sourceDatabase = $SourceDatabase
        targetManagedInstanceId = $plan.targetManagedInstanceId
        targetDatabase = $TargetDatabase
        restoreTimeUtc = $RestoreTimeUtc
        azureCliArguments = $plan.azureCliArguments
        azureOperationId = $null
        azureResponse = $null
        verification = $null
    }
    $null = Save-MiOpsOperation -Config $Config -Operation $operation
    Write-MiOpsAudit -Config $Config -Event 'restore.ready' -Data $operation
    $operation.status = 'Submitting'
    $operation.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $null = Save-MiOpsOperation -Config $Config -Operation $operation
    try {
        $response = Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @($plan.azureCliArguments) -AllowEmpty
        $operation.azureResponse = $response
        if ($response) {
            $operation.azureOperationId = @('operationId', 'azureAsyncOperation', 'name') |
                ForEach-Object { Get-MiOpsPropertyValue -InputObject $response -Name $_ } |
                Where-Object { $_ } |
                Select-Object -First 1
        }
        $operation.status = 'Submitted'
    }
    catch {
        $operation.status = 'Failed'
        $operation.error = $_.Exception.Message
        $operation.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        $null = Save-MiOpsOperation -Config $Config -Operation $operation
        Write-MiOpsAudit -Config $Config -Event 'restore.failed' -Data $operation
        throw
    }
    $operation.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $path = Save-MiOpsOperation -Config $Config -Operation $operation
    Write-MiOpsAudit -Config $Config -Event 'restore.submitted' -Data $operation
    return [pscustomobject]@{
        mode = 'apply'
        message = 'Azure accepted the non-blocking restore request. Submission is not completion; poll the local operation until Verified or Failed.'
        operation = $operation
        operationPath = $path
    }
}

function Get-MiOpsRestorePollState {
    [CmdletBinding()]
    param(
        $Database,
        [string]$ErrorMessage
    )

    if ($ErrorMessage) {
        if ($ErrorMessage -match '(?i)(ResourceNotFound|not found|could not be found)') {
            return [pscustomobject]@{ status = 'InProgress'; observedState = 'NotFoundYet'; provisioningState = $null }
        }
        return [pscustomobject]@{ status = 'Failed'; observedState = 'ReadFailed'; provisioningState = $null; error = $ErrorMessage }
    }
    $status = [string](Get-MiOpsPropertyValue -InputObject $Database -Name 'status')
    if (-not $status) {
        $status = [string](Get-MiOpsPropertyValue -InputObject $Database -Name 'state')
    }
    $provisioning = [string](Get-MiOpsPropertyValue -InputObject $Database -Name 'provisioningState')
    if ($status -eq 'Online' -and (!$provisioning -or $provisioning -eq 'Succeeded')) {
        return [pscustomobject]@{ status = 'Verified'; observedState = $status; provisioningState = $provisioning }
    }
    if ($status -in @('Failed', 'Inaccessible', 'Offline', 'Emergency') -or $provisioning -in @('Failed', 'Canceled', 'Cancelled')) {
        return [pscustomobject]@{ status = 'Failed'; observedState = $status; provisioningState = $provisioning }
    }
    return [pscustomobject]@{ status = 'InProgress'; observedState = $status; provisioningState = $provisioning }
}

function Update-MiOpsRestoreOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Operation,
        [scriptblock]$AzInvoker
    )

    if (-not (Test-MiOpsResourceAllowed -Config $Config -ResourceId ([string]$Operation.sourceManagedInstanceId))) {
        throw "Restore source is no longer allowlisted: $($Operation.sourceManagedInstanceId)"
    }
    if (-not (Test-MiOpsRestoreTargetAllowed -Config $Config -ResourceId ([string]$Operation.targetManagedInstanceId))) {
        throw "Restore target is no longer allowlisted: $($Operation.targetManagedInstanceId)"
    }
    if ([string]$Operation.status -eq 'Verified') {
        return [pscustomobject]@{
            operation = $Operation
            operationPath = Join-Path (Join-Path $Config.state.directory 'operations') "$($Operation.operationId).json"
        }
    }
    if ([string]$Operation.status -notin @('Submitted', 'InProgress')) {
        throw "Restore operation '$($Operation.operationId)' cannot be polled because its status is '$($Operation.status)'."
    }
    if (-not $AzInvoker) {
        $AzInvoker = { param($Arguments, $AllowEmpty) Invoke-MiOpsAzJson -Arguments $Arguments -AllowEmpty:$AllowEmpty }
    }
    $target = Get-MiOpsResourceParts -ResourceId ([string]$Operation.targetManagedInstanceId)
    try {
        $database = Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @(
            'sql', 'midb', 'show',
            '--resource-group', $target.resourceGroup,
            '--managed-instance', $target.name,
            '--name', [string]$Operation.targetDatabase,
            '--subscription', $target.subscriptionId
        )
        $poll = Get-MiOpsRestorePollState -Database $database
    }
    catch {
        $poll = Get-MiOpsRestorePollState -ErrorMessage $_.Exception.Message
    }
    $Operation.status = $poll.status
    $Operation.verification = [ordered]@{
        observedState = $poll.observedState
        provisioningState = $poll.provisioningState
        checkedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $pollError = Get-MiOpsPropertyValue -InputObject $poll -Name 'error'
    if ($pollError) {
        $Operation.verification.error = $pollError
    }
    $Operation.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $path = Save-MiOpsOperation -Config $Config -Operation $Operation
    Write-MiOpsAudit -Config $Config -Event 'restore.polled' -Data $Operation
    return [pscustomobject]@{ operation = $Operation; operationPath = $path }
}

function Test-MiOpsLongTermRetentionConfigured {
    [CmdletBinding()]
    param($Policy)

    if (-not $Policy) {
        return $false
    }
    foreach ($name in @('weeklyRetention', 'monthlyRetention', 'yearlyRetention')) {
        $value = [string](Get-MiOpsPropertyValue -InputObject $Policy -Name $name)
        if ($value -and $value -notin @('P0D', 'PT0S', '0')) {
            return $true
        }
    }
    return $false
}

function Get-MiOpsBackupFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Database,
        $ShortTermPolicy,
        $LongTermPolicy,
        [object[]]$LongTermBackups = @(),
        $SqlHistory,
        [Parameter(Mandatory)][hashtable]$Thresholds,
        [string[]]$EvidenceGaps = @(),
        [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $name = [string]$Database.name
    $status = [string]$Database.status
    $latestLtrBackupUtc = $null
    if ($status -and $status -ne 'Online') {
        $findings.Add([pscustomobject]@{ code = 'database-not-online'; severity = 'warning'; confidence = 'high'; evidenceSource = 'azure-control-plane'; detail = "Database status is '$status'." })
    }

    $retention = if ($ShortTermPolicy) { Get-MiOpsPropertyValue -InputObject $ShortTermPolicy -Name 'retentionDays' } else { $null }
    if ($null -eq $retention) {
        $findings.Add([pscustomobject]@{ code = 'str-policy-unavailable'; severity = 'insufficient-evidence'; confidence = 'high'; evidenceSource = 'azure-control-plane'; detail = 'Short-term retention policy could not be read.' })
    }
    elseif ([int]$retention -lt [int]$Thresholds.minimumShortTermRetentionDays) {
        $findings.Add([pscustomobject]@{ code = 'str-retention-below-threshold'; severity = 'warning'; confidence = 'high'; evidenceSource = 'azure-control-plane'; detail = "STR retention is $retention days; minimum expected is $($Thresholds.minimumShortTermRetentionDays)." })
    }

    $ltrConfigured = Test-MiOpsLongTermRetentionConfigured -Policy $LongTermPolicy
    if ([bool]$Thresholds.requireLongTermRetention -and -not $ltrConfigured) {
        $findings.Add([pscustomobject]@{ code = 'ltr-policy-required-absent'; severity = if ($LongTermPolicy) { 'warning' } else { 'insufficient-evidence' }; confidence = 'high'; evidenceSource = 'azure-control-plane'; detail = 'Long-term retention is required but no enabled LTR policy was observed.' })
    }
    if ($ltrConfigured) {
        $backupTimes = @($LongTermBackups | ForEach-Object {
            $value = Get-MiOpsPropertyValue -InputObject $_ -Name 'backupTime'
            if (-not $value) { $value = Get-MiOpsPropertyValue -InputObject $_ -Name 'backupTimeUtc' }
            if ($value) { [DateTimeOffset]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal) }
        })
        if ($backupTimes.Count -eq 0) {
            $findings.Add([pscustomobject]@{ code = 'ltr-backup-unavailable'; severity = 'insufficient-evidence'; confidence = 'medium'; evidenceSource = 'azure-control-plane'; detail = 'LTR is configured, but no readable LTR backup record was returned. A newly enabled policy can take up to seven days to produce its first visible backup.' })
        }
        else {
            $latest = @($backupTimes | Sort-Object -Descending)[0]
            $latestLtrBackupUtc = $latest.ToString('o')
            if ([bool]$Thresholds.requireLongTermRetention -and
                ($NowUtc - $latest).TotalDays -gt [int]$Thresholds.maximumLatestLongTermBackupAgeDays) {
                $findings.Add([pscustomobject]@{ code = 'ltr-latest-too-old'; severity = 'warning'; confidence = 'high'; evidenceSource = 'azure-control-plane'; detail = "Latest LTR backup is '$($latest.ToString('o'))', older than $($Thresholds.maximumLatestLongTermBackupAgeDays) days." })
            }
        }
    }

    if ($SqlHistory) {
        foreach ($check in @(
            @{ field = 'latestFullBackupUtc'; limit = [int]$Thresholds.maximumFullBackupAgeHours; unit = 'hours'; code = 'sql-full-history-gap' },
            @{ field = 'latestDifferentialBackupUtc'; limit = [int]$Thresholds.maximumDifferentialBackupAgeHours; unit = 'hours'; code = 'sql-differential-history-gap' },
            @{ field = 'latestLogBackupUtc'; limit = [int]$Thresholds.maximumLogBackupAgeMinutes; unit = 'minutes'; code = 'sql-log-history-gap' }
        )) {
            $value = Get-MiOpsPropertyValue -InputObject $SqlHistory -Name $check.field
            if (-not $value) {
                $findings.Add([pscustomobject]@{ code = $check.code; severity = 'insufficient-evidence'; confidence = 'medium'; evidenceSource = 'sql-msdb'; detail = "No $($check.field) value was returned from the fixed SQL history query." })
                continue
            }
            $age = $NowUtc - [DateTimeOffset]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
            $actual = if ($check.unit -eq 'hours') { $age.TotalHours } else { $age.TotalMinutes }
            if ($actual -gt $check.limit) {
                $findings.Add([pscustomobject]@{ code = $check.code; severity = 'warning'; confidence = 'medium'; evidenceSource = 'sql-msdb'; detail = "$($check.field) is '$value', older than $($check.limit) $($check.unit)." })
            }
        }
    }
    foreach ($gap in $EvidenceGaps) {
        $findings.Add([pscustomobject]@{ code = 'evidence-gap'; severity = 'insufficient-evidence'; confidence = 'high'; evidenceSource = 'collection'; detail = $gap })
    }
    return [pscustomobject]@{
        database = $name
        evidence = [pscustomobject]@{
            databaseStatus = $status
            earliestRestoreDate = Get-MiOpsPropertyValue -InputObject $Database -Name 'earliestRestoreDate'
            shortTermRetentionDays = $retention
            longTermRetentionConfigured = $ltrConfigured
            latestLongTermBackupUtc = $latestLtrBackupUtc
            sqlHistoryIncluded = [bool]$SqlHistory
        }
        findings = @($findings)
        warningCount = @($findings | Where-Object severity -eq 'warning').Count
        insufficientEvidenceCount = @($findings | Where-Object severity -eq 'insufficient-evidence').Count
    }
}

function Invoke-MiOpsSqlBackupHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Server,
        [scriptblock]$SqlInvoker
    )

    if (-not $Config.sqlDiagnostics.enabled) {
        return [pscustomobject]@{ included = $false; rows = @(); evidenceGaps = @('SQL backup history adapter is disabled by configuration.') }
    }
    $queryId = 'backup-history-v1'
    $query = "SET NOCOUNT ON; SELECT TOP ($([int]$Config.sqlDiagnostics.maxRows)) d.name,ISNULL(CONVERT(varchar(33),MAX(CASE WHEN b.type='D' THEN b.backup_finish_date END),126),''),ISNULL(CONVERT(varchar(33),MAX(CASE WHEN b.type='I' THEN b.backup_finish_date END),126),''),ISNULL(CONVERT(varchar(33),MAX(CASE WHEN b.type='L' THEN b.backup_finish_date END),126),'') FROM sys.databases d LEFT JOIN msdb.dbo.backupset b ON b.database_name=d.name WHERE d.database_id>4 GROUP BY d.name ORDER BY d.name;"
    if (-not $SqlInvoker) {
        $sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
        if (-not $sqlcmd) {
            return [pscustomobject]@{ included = $false; rows = @(); evidenceGaps = @('sqlcmd is not installed or not on PATH.') }
        }
        $SqlInvoker = {
            param($Executable, $Arguments)
            $output = @(& $Executable @Arguments 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
            }
            return $output
        }
        $executable = $sqlcmd.Source
    }
    else {
        $executable = 'sqlcmd'
    }
    $arguments = @(
        '-S', $Server,
        '-d', 'msdb',
        '-G',
        '-l', [string][int]$Config.sqlDiagnostics.connectTimeoutSeconds,
        '-t', [string][int]$Config.sqlDiagnostics.queryTimeoutSeconds,
        '-W', '-s', '|', '-h', '-1', '-Q', $query
    )
    Write-MiOpsAudit -Config $Config -Event 'sql.backup-history.query' -Data @{
        queryId = $queryId
        server = $Server
        authentication = 'Microsoft Entra'
        maxRows = [int]$Config.sqlDiagnostics.maxRows
        timeoutSeconds = [int]$Config.sqlDiagnostics.queryTimeoutSeconds
    }
    try {
        $output = @(& $SqlInvoker $executable $arguments)
    }
    catch {
        return [pscustomobject]@{
            included = $false
            rows = @()
            evidenceGaps = @("SQL backup history unavailable. Verify private network reachability, Microsoft Entra sqlcmd authentication, and least-privilege msdb backup-history permissions. $($_.Exception.Message)")
        }
    }
    $rows = @($output | ForEach-Object {
        $line = [string]$_
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\(\d+ rows affected\)$') { return }
        $parts = $line.Split('|')
        if ($parts.Count -ne 4) { return }
        [pscustomobject]@{
            database = $parts[0].Trim()
            latestFullBackupUtc = if ($parts[1].Trim()) { "$($parts[1].Trim())Z" } else { $null }
            latestDifferentialBackupUtc = if ($parts[2].Trim()) { "$($parts[2].Trim())Z" } else { $null }
            latestLogBackupUtc = if ($parts[3].Trim()) { "$($parts[3].Trim())Z" } else { $null }
        }
    })
    return [pscustomobject]@{ included = $true; queryId = $queryId; rows = $rows; evidenceGaps = @() }
}

function Get-MiOpsBackupHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$ManagedInstanceId,
        [switch]$UseSqlHistory,
        [scriptblock]$AzInvoker,
        [scriptblock]$SqlInvoker
    )

    if (-not $ManagedInstanceId) {
        $ManagedInstanceId = [string]$Config.resource.id
    }
    if (-not $AzInvoker) {
        $AzInvoker = { param($Arguments, $AllowEmpty) Invoke-MiOpsAzJson -Arguments $Arguments -AllowEmpty:$AllowEmpty }
    }
    $inventory = Get-MiOpsDatabaseList -Config $Config -ManagedInstanceId $ManagedInstanceId -AzInvoker $AzInvoker
    $parts = Get-MiOpsResourceParts -ResourceId $ManagedInstanceId
    $instance = Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @('sql', 'mi', 'show', '--ids', $ManagedInstanceId)
    $sqlEvidence = [pscustomobject]@{ included = $false; queryId = $null; rows = @(); evidenceGaps = @() }
    if ($UseSqlHistory) {
        if (-not $Config.sqlDiagnostics.enabled) {
            $sqlEvidence = [pscustomobject]@{ included = $false; queryId = $null; rows = @(); evidenceGaps = @('SQL history was requested, but sqlDiagnostics.enabled is false.') }
        }
        else {
            $server = [string](Get-MiOpsPropertyValue -InputObject $instance -Name 'fullyQualifiedDomainName')
            if (-not $server) {
                $sqlEvidence = [pscustomobject]@{ included = $false; queryId = $null; rows = @(); evidenceGaps = @('Managed Instance fullyQualifiedDomainName was not exposed by Azure.') }
            }
            else {
                $sqlEvidence = Invoke-MiOpsSqlBackupHistory -Config $Config -Server $server -SqlInvoker $SqlInvoker
            }
        }
    }

    $deleted = @()
    $globalGaps = [System.Collections.Generic.List[string]]::new()
    foreach ($gap in @($inventory.evidenceGaps)) {
        $globalGaps.Add([string]$gap)
    }
    try {
        $deleted = @(Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @(
            'sql', 'midb', 'list-deleted',
            '--resource-group', $parts.resourceGroup,
            '--managed-instance', $parts.name,
            '--subscription', $parts.subscriptionId
        ))
    }
    catch {
        $globalGaps.Add("Restorable deleted database evidence unavailable: $($_.Exception.Message)")
    }

    $perDatabase = [System.Collections.Generic.List[object]]::new()
    foreach ($database in @($inventory.databases)) {
        $gaps = [System.Collections.Generic.List[string]]::new()
        $shortTerm = $null
        $longTerm = $null
        $ltrBackups = @()
        try {
            $shortTerm = Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @(
                'sql', 'midb', 'short-term-retention-policy', 'show',
                '--resource-group', $parts.resourceGroup,
                '--managed-instance', $parts.name,
                '--name', [string]$database.name,
                '--subscription', $parts.subscriptionId
            )
        }
        catch {
            $gaps.Add("Short-term retention policy unavailable: $($_.Exception.Message)")
        }
        try {
            $longTerm = Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @(
                'sql', 'midb', 'ltr-policy', 'show',
                '--resource-group', $parts.resourceGroup,
                '--managed-instance', $parts.name,
                '--name', [string]$database.name,
                '--subscription', $parts.subscriptionId
            )
        }
        catch {
            $gaps.Add("Long-term retention policy unavailable: $($_.Exception.Message)")
        }
        if ([bool]$Config.backupHealth.requireLongTermRetention -or (Test-MiOpsLongTermRetentionConfigured -Policy $longTerm)) {
            try {
                $ltrBackups = @(Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @(
                    'sql', 'midb', 'ltr-backup', 'list',
                    '--location', [string](Get-MiOpsPropertyValue -InputObject $instance -Name 'location'),
                    '--resource-group', $parts.resourceGroup,
                    '--managed-instance', $parts.name,
                    '--database', [string]$database.name,
                    '--subscription', $parts.subscriptionId
                ))
            }
            catch {
                $gaps.Add("Long-term backup records unavailable: $($_.Exception.Message)")
            }
        }
        $sqlRow = @($sqlEvidence.rows | Where-Object database -CEQ $database.name) | Select-Object -First 1
        $perDatabase.Add((Get-MiOpsBackupFindings -Database $database -ShortTermPolicy $shortTerm `
            -LongTermPolicy $longTerm -LongTermBackups $ltrBackups -SqlHistory $sqlRow `
            -Thresholds $Config.backupHealth -EvidenceGaps @($gaps)))
    }
    foreach ($gap in @($sqlEvidence.evidenceGaps)) {
        $globalGaps.Add($gap)
    }
    $result = [pscustomobject][ordered]@{
        collectedAtUtc = [DateTime]::UtcNow.ToString('o')
        managedInstanceId = $ManagedInstanceId
        managedInstanceState = $inventory.instanceState
        databaseCount = @($inventory.databases).Count
        databases = @($perDatabase)
        restorableDeletedDatabases = @(ConvertTo-MiOpsDatabaseItems -Databases $deleted)
        sqlHistory = [pscustomobject]@{
            requested = [bool]$UseSqlHistory
            included = [bool]$sqlEvidence.included
            queryId = $sqlEvidence.queryId
        }
        evidenceGaps = @($globalGaps)
        limitations = @(
            'Azure ARM/CLI exposes durable database state, retention policies, restorable deleted databases, and LTR backup records where authorized.',
            'Azure ARM does not expose every individual short-term full, differential, and log backup record.',
            'Optional msdb history is recent SQL data-plane transparency, can be incomplete, and does not replace Azure backup durability evidence.'
        )
    }
    Write-MiOpsAudit -Config $Config -Event 'backup.health.checked' -Data @{
        managedInstanceId = $ManagedInstanceId
        databaseCount = $result.databaseCount
        warningCount = @($perDatabase | ForEach-Object warningCount | Measure-Object -Sum).Sum
        evidenceGapCount = @($globalGaps).Count
        sqlHistoryIncluded = [bool]$sqlEvidence.included
    }
    return $result
}
