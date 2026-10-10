function ConvertTo-MiOpsLtrRetention {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][ValidateSet('Weekly', 'Monthly', 'Yearly')][string]$Dimension,
        [switch]$FromAzure
    )

    $disabledValues = @('PT0S')
    if ($FromAzure) {
        $disabledValues += @('', '0', 'P0D', 'P0W', 'P0M', 'P0Y')
    }
    if ($null -eq $Value -or $Value -cin $disabledValues) {
        return [pscustomobject][ordered]@{
            dimension = $Dimension
            normalized = 'PT0S'
            enabled = $false
            quantity = 0
            comparisonDays = 0
        }
    }

    $match = [regex]::Match($Value, '^P(?<quantity>[1-9][0-9]*)(?<unit>[DWMY])$')
    if (-not $match.Success) {
        throw "$Dimension retention must be PT0S or one normalized single-unit ISO-8601 value: P<n>D, P<n>W, P<n>M, or P<n>Y."
    }

    $quantity = [int]$match.Groups['quantity'].Value
    $unit = $match.Groups['unit'].Value
    $comparisonDays = switch ($unit) {
        'D' { [double]$quantity }
        'W' { [double]($quantity * 7) }
        'M' { [double]($quantity * (365.0 / 12.0)) }
        'Y' { [double]($quantity * 365.0) }
    }
    $maximum = switch ($unit) {
        'D' { 3650 }
        'W' { 521 }
        'M' { 120 }
        'Y' { 10 }
    }
    if ($comparisonDays -lt 7 -or $quantity -gt $maximum) {
        throw "$Dimension retention must be at least 7 days and no more than 10 years."
    }
    return [pscustomobject][ordered]@{
        dimension = $Dimension
        normalized = "P$quantity$unit"
        enabled = $true
        quantity = $quantity
        comparisonDays = $comparisonDays
    }
}

function ConvertTo-MiOpsLtrPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Policy,
        [switch]$FromAzure
    )

    $weekly = ConvertTo-MiOpsLtrRetention -Value ([string](Get-MiOpsPropertyValue -InputObject $Policy -Name 'weeklyRetention')) -Dimension Weekly -FromAzure:$FromAzure
    $monthly = ConvertTo-MiOpsLtrRetention -Value ([string](Get-MiOpsPropertyValue -InputObject $Policy -Name 'monthlyRetention')) -Dimension Monthly -FromAzure:$FromAzure
    $yearly = ConvertTo-MiOpsLtrRetention -Value ([string](Get-MiOpsPropertyValue -InputObject $Policy -Name 'yearlyRetention')) -Dimension Yearly -FromAzure:$FromAzure
    $rawWeek = Get-MiOpsPropertyValue -InputObject $Policy -Name 'weekOfYear'
    $weekOfYear = if ($yearly.enabled) { [int]$rawWeek } else { 0 }
    if ($yearly.enabled -and ($weekOfYear -lt 1 -or $weekOfYear -gt 52)) {
        throw "WeekOfYear must be between 1 and 52 when yearly retention is enabled. Observed '$rawWeek'."
    }

    return [pscustomobject][ordered]@{
        weeklyRetention = $weekly.normalized
        monthlyRetention = $monthly.normalized
        yearlyRetention = $yearly.normalized
        weekOfYear = $weekOfYear
        weeklyEnabled = $weekly.enabled
        monthlyEnabled = $monthly.enabled
        yearlyEnabled = $yearly.enabled
        allDisabled = -not ($weekly.enabled -or $monthly.enabled -or $yearly.enabled)
        quantities = [pscustomobject]@{
            weekly = $weekly.quantity
            monthly = $monthly.quantity
            yearly = $yearly.quantity
        }
        comparisonDays = [pscustomobject]@{
            weekly = $weekly.comparisonDays
            monthly = $monthly.comparisonDays
            yearly = $yearly.comparisonDays
        }
    }
}

function New-MiOpsLtrRequestedPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WeeklyRetention,
        [Parameter(Mandatory)][string]$MonthlyRetention,
        [Parameter(Mandatory)][string]$YearlyRetention,
        [Parameter(Mandatory)][int]$WeekOfYear
    )

    $policy = ConvertTo-MiOpsLtrPolicy -Policy ([pscustomobject]@{
        weeklyRetention = $WeeklyRetention
        monthlyRetention = $MonthlyRetention
        yearlyRetention = $YearlyRetention
        weekOfYear = $WeekOfYear
    })
    if ($policy.allDisabled) {
        throw 'At least one LTR retention dimension must remain enabled. Clearing or disabling the entire LTR policy is not supported.'
    }
    if (-not $policy.yearlyEnabled -and $WeekOfYear -ne 0) {
        throw 'WeekOfYear must be 0 when yearly retention is PT0S.'
    }
    return $policy
}

function Test-MiOpsLtrPolicyReduction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Current,
        [Parameter(Mandatory)]$Requested
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    foreach ($dimension in @('weekly', 'monthly', 'yearly')) {
        $enabledName = "${dimension}Enabled"
        $currentEnabled = [bool](Get-MiOpsPropertyValue -InputObject $Current -Name $enabledName)
        $requestedEnabled = [bool](Get-MiOpsPropertyValue -InputObject $Requested -Name $enabledName)
        if ($currentEnabled -and -not $requestedEnabled) {
            $reasons.Add("$dimension retention would be disabled")
            continue
        }
        if ($currentEnabled -and $requestedEnabled) {
            $currentDays = [double](Get-MiOpsPropertyValue -InputObject $Current.comparisonDays -Name $dimension)
            $requestedDays = [double](Get-MiOpsPropertyValue -InputObject $Requested.comparisonDays -Name $dimension)
            if ($requestedDays -lt $currentDays) {
                $reasons.Add("$dimension retention would decrease")
            }
        }
    }
    return [pscustomobject]@{
        isReduction = $reasons.Count -gt 0
        reasons = @($reasons)
    }
}

function Test-MiOpsLtrConfirmation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)][bool]$IsReduction,
        [Parameter(Mandatory)][string]$Confirmation
    )

    $verb = if ($IsReduction) { 'REDUCE LTR' } else { 'SET LTR' }
    $expected = "$verb $Database WEEKLY $($Policy.weeklyRetention) MONTHLY $($Policy.monthlyRetention) YEARLY $($Policy.yearlyRetention) WEEK $($Policy.weekOfYear)"
    return $Confirmation -ceq $expected
}

function Assert-MiOpsLtrDatabase {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ManagedInstanceId,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][scriptblock]$AzInvoker
    )

    if (-not (Test-MiOpsResourceAllowed -Config $Config -ResourceId $ManagedInstanceId)) {
        throw "LTR policy source is not allowlisted: $ManagedInstanceId"
    }
    if (-not (Test-MiOpsDatabaseName -Name $Database)) {
        throw "Database name is unsafe or is a system database: $Database"
    }
    $inventory = Get-MiOpsDatabaseList -Config $Config -ManagedInstanceId $ManagedInstanceId -AzInvoker $AzInvoker
    if (-not $inventory.available) {
        throw 'Database inventory is unavailable because the Managed Instance is not operational.'
    }
    $matches = @($inventory.databases | Where-Object name -CEQ $Database)
    if ($matches.Count -ne 1) {
        throw "Database '$Database' was not found exactly once on the allowlisted Managed Instance."
    }
    return $matches[0]
}

function Get-MiOpsLtrPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Database,
        [string]$ManagedInstanceId,
        [scriptblock]$AzInvoker
    )

    if (-not $ManagedInstanceId) {
        $ManagedInstanceId = [string]$Config.resource.id
    }
    if (-not $AzInvoker) {
        $AzInvoker = { param($Arguments, $AllowEmpty) Invoke-MiOpsAzJson -Arguments $Arguments -AllowEmpty:$AllowEmpty }
    }
    $databaseItem = Assert-MiOpsLtrDatabase -Config $Config -ManagedInstanceId $ManagedInstanceId -Database $Database -AzInvoker $AzInvoker
    $parts = Get-MiOpsResourceParts -ResourceId $ManagedInstanceId
    $raw = Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @(
        'sql', 'midb', 'ltr-policy', 'show',
        '--resource-group', $parts.resourceGroup,
        '--managed-instance', $parts.name,
        '--name', $Database,
        '--subscription', $parts.subscriptionId
    )
    $policy = ConvertTo-MiOpsLtrPolicy -Policy $raw -FromAzure
    $result = [pscustomobject][ordered]@{
        collectedAtUtc = [DateTime]::UtcNow.ToString('o')
        managedInstanceId = $ManagedInstanceId
        managedInstanceName = $parts.name
        subscriptionId = $parts.subscriptionId
        database = $Database
        databaseResourceId = $databaseItem.resourceId
        policy = $policy
        notes = @(
            'Azure SQL Managed Instance LTR retains selected automated full backups for up to 10 years.',
            'PT0S means that one individual retention dimension is disabled; this tool never allows all three dimensions to be disabled.',
            'Changes affect future LTR backups. Existing retained backups keep the retention assigned when they were created.'
        )
    }
    Write-MiOpsAudit -Config $Config -Event 'ltr.policy.read' -Data @{
        managedInstanceId = $ManagedInstanceId
        database = $Database
        policy = $policy
    }
    return $result
}

function Get-MiOpsLtrPolicyPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$WeeklyRetention,
        [Parameter(Mandatory)][string]$MonthlyRetention,
        [Parameter(Mandatory)][string]$YearlyRetention,
        [Parameter(Mandatory)][int]$WeekOfYear,
        [string]$ManagedInstanceId,
        [scriptblock]$AzInvoker
    )

    if (-not $ManagedInstanceId) {
        $ManagedInstanceId = [string]$Config.resource.id
    }
    if (-not $AzInvoker) {
        $AzInvoker = { param($Arguments, $AllowEmpty) Invoke-MiOpsAzJson -Arguments $Arguments -AllowEmpty:$AllowEmpty }
    }
    $requested = New-MiOpsLtrRequestedPolicy -WeeklyRetention $WeeklyRetention -MonthlyRetention $MonthlyRetention -YearlyRetention $YearlyRetention -WeekOfYear $WeekOfYear
    $currentResult = Get-MiOpsLtrPolicy -Config $Config -ManagedInstanceId $ManagedInstanceId -Database $Database -AzInvoker $AzInvoker
    $reduction = Test-MiOpsLtrPolicyReduction -Current $currentResult.policy -Requested $requested
    $parts = Get-MiOpsResourceParts -ResourceId $ManagedInstanceId
    $arguments = @(
        'sql', 'midb', 'ltr-policy', 'set',
        '--resource-group', $parts.resourceGroup,
        '--managed-instance', $parts.name,
        '--name', $Database,
        '--weekly-retention', $requested.weeklyRetention,
        '--monthly-retention', $requested.monthlyRetention,
        '--yearly-retention', $requested.yearlyRetention
    )
    if ($requested.yearlyEnabled) {
        $arguments += @('--week-of-year', [string]$requested.weekOfYear)
    }
    $arguments += @('--subscription', $parts.subscriptionId)
    $verb = if ($reduction.isReduction) { 'REDUCE LTR' } else { 'SET LTR' }
    $plan = [pscustomobject][ordered]@{
        mode = 'dry-run'
        managedInstanceId = $ManagedInstanceId
        managedInstanceName = $parts.name
        subscriptionId = $parts.subscriptionId
        database = $Database
        currentPolicy = $currentResult.policy
        requestedPolicy = $requested
        isRetentionReduction = $reduction.isReduction
        reductionReasons = $reduction.reasons
        requiredConfirmation = "$verb $Database WEEKLY $($requested.weeklyRetention) MONTHLY $($requested.monthlyRetention) YEARLY $($requested.yearlyRetention) WEEK $($requested.weekOfYear)"
        azureCliArguments = $arguments
        warnings = @(
            'Longer retention can increase Azure backup storage cost.',
            'Policy changes apply to future retained backups and do not necessarily delete existing LTR backups immediately.',
            'Validate legal, regulatory, and organizational compliance requirements before applying this policy.',
            'The first visible LTR backup can take up to seven days after enabling LTR.',
            'Azure SQL Managed Instance LTR backups cannot currently be configured as immutable.',
            'Geo-replication/failover configurations need equivalent LTR policy on the secondary for continuity after failover.',
            'LTR depends on successful automated full backups; transaction-log pressure or features that delay log truncation can delay LTR creation.',
            'Azure remains authoritative for regional availability, permissions, backup health, and platform constraints.'
        )
    }
    Write-MiOpsAudit -Config $Config -Event 'ltr.policy.plan' -Data $plan
    return $plan
}

function Test-MiOpsLtrPolicyMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Observed
    )

    return (
        [string]$Expected.weeklyRetention -ceq [string]$Observed.weeklyRetention -and
        [string]$Expected.monthlyRetention -ceq [string]$Observed.monthlyRetention -and
        [string]$Expected.yearlyRetention -ceq [string]$Observed.yearlyRetention -and
        [int]$Expected.weekOfYear -eq [int]$Observed.weekOfYear
    )
}

function Invoke-MiOpsLtrPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$WeeklyRetention,
        [Parameter(Mandatory)][string]$MonthlyRetention,
        [Parameter(Mandatory)][string]$YearlyRetention,
        [Parameter(Mandatory)][int]$WeekOfYear,
        [string]$ManagedInstanceId,
        [switch]$Apply,
        [string]$ApproveResourceId,
        [switch]$AllowRetentionReduction,
        [string]$TypedConfirmation,
        [scriptblock]$AzInvoker
    )

    if (-not $AzInvoker) {
        $AzInvoker = { param($Arguments, $AllowEmpty) Invoke-MiOpsAzJson -Arguments $Arguments -AllowEmpty:$AllowEmpty }
    }
    $plan = Get-MiOpsLtrPolicyPlan -Config $Config -ManagedInstanceId $ManagedInstanceId -Database $Database `
        -WeeklyRetention $WeeklyRetention -MonthlyRetention $MonthlyRetention -YearlyRetention $YearlyRetention `
        -WeekOfYear $WeekOfYear -AzInvoker $AzInvoker
    if (-not $Apply) {
        return $plan
    }
    if ([string]::IsNullOrWhiteSpace($ApproveResourceId) -or
        $ApproveResourceId.TrimEnd('/') -ine $plan.managedInstanceId.TrimEnd('/')) {
        throw 'LTR apply requires -Apply and -ApproveResourceId matching the exact allowlisted Managed Instance resource ID.'
    }
    if ($plan.isRetentionReduction -and -not $AllowRetentionReduction) {
        throw "The requested policy weakens retention: $($plan.reductionReasons -join '; '). Re-run only with -AllowRetentionReduction and the REDUCE confirmation after compliance review."
    }
    if (-not (Test-MiOpsLtrConfirmation -Database $Database -Policy $plan.requestedPolicy `
        -IsReduction $plan.isRetentionReduction -Confirmation $TypedConfirmation)) {
        throw "Typed confirmation did not exactly match '$($plan.requiredConfirmation)'. No LTR policy was submitted."
    }

    $operation = [ordered]@{
        operationId = [Guid]::NewGuid().ToString()
        action = 'ltr-policy-set'
        status = 'Ready'
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        managedInstanceId = $plan.managedInstanceId
        database = $Database
        currentPolicy = $plan.currentPolicy
        requestedPolicy = $plan.requestedPolicy
        retentionReduction = $plan.isRetentionReduction
        reductionReasons = $plan.reductionReasons
        azureCliArguments = $plan.azureCliArguments
        azureResponse = $null
        verification = $null
    }
    $null = Save-MiOpsOperation -Config $Config -Operation $operation
    Write-MiOpsAudit -Config $Config -Event 'ltr.policy.ready' -Data $operation
    $operation.status = 'Submitting'
    $operation.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $null = Save-MiOpsOperation -Config $Config -Operation $operation
    try {
        $operation.azureResponse = Invoke-MiOpsAzAdapter -Invoker $AzInvoker -Arguments @($plan.azureCliArguments)
        $operation.status = 'Submitted'
        $operation.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        $null = Save-MiOpsOperation -Config $Config -Operation $operation
        Write-MiOpsAudit -Config $Config -Event 'ltr.policy.submitted' -Data $operation

        $observedResult = Get-MiOpsLtrPolicy -Config $Config -ManagedInstanceId $plan.managedInstanceId -Database $Database -AzInvoker $AzInvoker
        $matches = Test-MiOpsLtrPolicyMatch -Expected $plan.requestedPolicy -Observed $observedResult.policy
        $operation.verification = [ordered]@{
            matchesRequestedPolicy = $matches
            observedPolicy = $observedResult.policy
            checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        $operation.status = if ($matches) { 'Verified' } else { 'VerificationMismatch' }
    }
    catch {
        $operation.status = 'Failed'
        $operation.error = $_.Exception.Message
        $operation.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        $null = Save-MiOpsOperation -Config $Config -Operation $operation
        Write-MiOpsAudit -Config $Config -Event 'ltr.policy.failed' -Data $operation
        throw
    }
    $operation.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $path = Save-MiOpsOperation -Config $Config -Operation $operation
    $auditEvent = if ($operation.status -eq 'Verified') { 'ltr.policy.verified' } else { 'ltr.policy.verification-mismatch' }
    Write-MiOpsAudit -Config $Config -Event $auditEvent -Data $operation
    return [pscustomobject]@{
        mode = 'apply'
        message = if ($operation.status -eq 'Verified') {
            'Azure returned success and the independent read-back exactly matched the requested normalized LTR policy.'
        } else {
            'Azure CLI returned success, but independent read-back did not match. The operation is not verified.'
        }
        operation = $operation
        operationPath = $path
    }
}
