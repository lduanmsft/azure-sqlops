[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet(
        'preflight',
        'setup',
        'interactive',
        'inventory',
        'status',
        'database-list',
        'backup-check',
        'configure-restore-target',
        'restore-plan',
        'restore-apply',
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
    [string]$DataRoot = $PSScriptRoot,
    [string]$OperationId,
    [string]$EvidencePath,
    [string]$Title = 'Azure SQL Managed Instance incident',
    [string]$Impact = 'Describe the customer or business impact.',
    [string]$TenantId,
    [string]$SubscriptionId,
    [ValidateSet('all', 'vm', 'mi')]
    [string]$ResourceKind,
    [string]$ManagedInstanceId,
    [string]$SourceManagedInstanceId,
    [string]$TargetManagedInstanceId,
    [string]$SourceDatabase,
    [string]$TargetDatabase,
    [string]$RestoreTimeUtc,
    [string]$ApproveManagedInstanceId,
    [string]$ApproveSourceResourceId,
    [string]$ApproveTargetResourceId,
    [int]$LookbackHours,
    [switch]$UseDeviceCode,
    [switch]$UseSqlHistory,
    [switch]$Apply,
    [string]$ApproveResourceId,
    [string]$TypedConfirmation
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/MiOps.psm1') -Force

$resolvedDataRoot = [System.IO.Path]::GetFullPath($DataRoot)
$resolvedConfigPath = if ([System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath
}
else {
    Join-Path $resolvedDataRoot $ConfigPath
}

function Show-NumberedItems {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$Formatter
    )
    for ($index = 0; $index -lt $Items.Count; $index++) {
        Write-Host ("[{0}] {1}" -f ($index + 1), (& $Formatter $Items[$index]))
    }
}

function Invoke-Setup {
    if ($TenantId -and -not (Test-MiOpsTenantId -TenantId $TenantId)) {
        throw '-TenantId must be a tenant domain name or GUID.'
    }
    if ($SubscriptionId -and -not (Test-MiOpsSubscriptionId -SubscriptionId $SubscriptionId)) {
        throw '-SubscriptionId must be a GUID.'
    }

    $loginTarget = if ($TenantId) { "tenant '$TenantId'" } else { 'your Azure account' }
    Write-Host "Starting Azure CLI interactive login for $loginTarget."
    Write-Host 'Complete authentication in the browser opened by Azure CLI. This tool never requests or stores passwords, tokens, or client secrets.'
    if ($UseDeviceCode) {
        Write-Host 'Device-code mode is enabled. Follow the Azure CLI instructions locally in this terminal and browser.'
    }
    $loginContext = Invoke-MiOpsAzLogin -TenantId $TenantId -UseDeviceCode:$UseDeviceCode
    $loginSubscriptions = @($loginContext.subscriptions)
    $tenant = $null
    if ($TenantId) {
        $loginTenantGuid = [string](Get-MiOpsPropertyValue -InputObject $loginContext.account -Name 'tenantId')
        if ([string]::IsNullOrWhiteSpace($loginTenantGuid)) {
            throw "Azure CLI login succeeded for '$TenantId', but az account show returned no tenantId."
        }
        if (Test-MiOpsSubscriptionId -SubscriptionId $TenantId) {
            if ($loginTenantGuid -ine $TenantId) {
                throw "Azure CLI login returned tenant '$loginTenantGuid', not requested tenant '$TenantId'."
            }
        }
        $tenantChoices = @(ConvertTo-MiOpsTenantChoices -Subscriptions $loginSubscriptions)
        $tenant = @($tenantChoices | Where-Object {
            [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'tenantId') -ieq $loginTenantGuid
        }) | Select-Object -First 1
        if (-not $tenant) {
            $tenant = [pscustomobject]@{
                tenantId = $loginTenantGuid
                defaultDomain = if ($TenantId -notmatch '^(?i)[0-9a-f]{8}-') { $TenantId } else { '' }
                displayName = ''
            }
        }
    }
    elseif ($SubscriptionId) {
        $subscriptionMatch = @($loginSubscriptions | Where-Object {
            [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'state') -eq 'Enabled' -and
            [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'id') -ieq $SubscriptionId
        })
        if ($subscriptionMatch.Count -ne 1) {
            throw "Subscription '$SubscriptionId' is not an accessible enabled subscription."
        }
        $tenantGuidFromSubscription = [string](Get-MiOpsPropertyValue -InputObject $subscriptionMatch[0] -Name 'tenantId')
        $tenant = @(ConvertTo-MiOpsTenantChoices -Subscriptions $loginSubscriptions | Where-Object {
            [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'tenantId') -ieq $tenantGuidFromSubscription
        }) | Select-Object -First 1
        if (-not $tenant) {
            throw "Azure CLI could not resolve the tenant for subscription '$SubscriptionId'."
        }
    }
    else {
        $tenants = @(ConvertTo-MiOpsTenantChoices -Subscriptions @($loginSubscriptions | Where-Object {
            [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'state') -eq 'Enabled'
        }))
        if ($tenants.Count -eq 0) {
            throw 'No signed-in Azure tenants were returned by Azure CLI.'
        }
        Write-Host 'Accessible tenants:'
        Show-NumberedItems -Items $tenants -Formatter {
            param($item)
            $domain = [string](Get-MiOpsPropertyValue -InputObject $item -Name 'defaultDomain')
            $displayName = [string](Get-MiOpsPropertyValue -InputObject $item -Name 'displayName')
            $guid = [string](Get-MiOpsPropertyValue -InputObject $item -Name 'tenantId')
            "$domain | $displayName | $guid"
        }
        $tenant = Select-MiOpsNumberedItem -Items $tenants -Prompt 'Select a tenant'
        if (-not $tenant) {
            Write-Host 'Setup cancelled; no configuration was changed.'
            return
        }
    }
    $tenantGuid = [string](Get-MiOpsPropertyValue -InputObject $tenant -Name 'tenantId')
    $subscriptions = @($loginSubscriptions | Where-Object {
        [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'state') -eq 'Enabled' -and
        [string](Get-MiOpsPropertyValue -InputObject $_ -Name 'tenantId') -ieq $tenantGuid
    } | Sort-Object name, id)
    if ($subscriptions.Count -eq 0) {
        throw "No accessible enabled subscriptions were found for tenant '$tenantGuid'."
    }

    $selectedSubscription = $null
    if ($SubscriptionId) {
        $selectedSubscription = @($subscriptions | Where-Object { [string]$_.id -ieq $SubscriptionId }) | Select-Object -First 1
        if (-not $selectedSubscription) {
            throw "Subscription '$SubscriptionId' is not an accessible enabled subscription in tenant '$tenantGuid'."
        }
    }
    else {
        Write-Host 'Accessible enabled subscriptions:'
        Show-NumberedItems -Items $subscriptions -Formatter { param($item) "$($item.name) | $($item.id)" }
        $selectedSubscription = Select-MiOpsNumberedItem -Items $subscriptions -Prompt 'Select a subscription'
        if (-not $selectedSubscription) {
            Write-Host 'Setup cancelled; no configuration was changed.'
            return
        }
    }

    $account = Set-MiOpsSubscription -SubscriptionId ([string]$selectedSubscription.id) -TenantGuid $tenantGuid
    Write-Host "Confirmed active tenant $($account.tenantId) and subscription $($account.name) ($($account.id))."

    $instances = @(Get-MiOpsManagedInstances -SubscriptionId ([string]$account.id))
    if ($instances.Count -eq 0) {
        throw "No Azure SQL Managed Instances were found in subscription '$($account.id)'. No configuration was changed."
    }
    $selectedInstance = $null
    if ($ManagedInstanceId) {
        $selectedInstance = @($instances | Where-Object { [string]$_.id -ieq $ManagedInstanceId }) | Select-Object -First 1
        if (-not $selectedInstance) {
            throw 'The supplied -ManagedInstanceId was not returned by Azure SQL MI discovery.'
        }
    }
    else {
        Write-Host 'Discovered Azure SQL Managed Instances:'
        Show-NumberedItems -Items $instances -Formatter {
            param($item)
            $tier = if ($item.sku) { [string]$item.sku.tier } else { '' }
            "$($item.name) | resource group: $($item.resourceGroup) | location: $($item.location) | state: $($item.state) | tier: $tier | $($item.id)"
        }
        $selectedInstance = Select-MiOpsNumberedItem -Items $instances -Prompt 'Select a Managed Instance'
        if (-not $selectedInstance) {
            Write-Host 'Setup cancelled; no configuration was changed.'
            return
        }
    }

    $expected = "CONFIGURE $($selectedInstance.name)"
    Write-Host "Selected: $($selectedInstance.name) | state: $($selectedInstance.state) | $($selectedInstance.id)"
    $confirmation = if ($ApproveManagedInstanceId) {
        if ($ApproveManagedInstanceId -cne [string]$selectedInstance.id) {
            throw '-ApproveManagedInstanceId must exactly match the selected Managed Instance resource ID.'
        }
        $expected
    }
    else {
        Read-Host "Type '$expected' to create or update $resolvedConfigPath"
    }
    if (-not (Test-MiOpsTypedConfirmation -Action CONFIGURE -ManagedInstanceName ([string]$selectedInstance.name) -Confirmation $confirmation)) {
        Write-Host 'Setup cancelled; no configuration was changed.'
        return
    }

    $examplePath = Join-Path $PSScriptRoot 'config/miops.example.json'
    $null = New-MiOpsLocalConfig -ExamplePath $examplePath -DestinationPath $resolvedConfigPath `
        -ResourceId ([string]$selectedInstance.id) -TenantId $tenantGuid -SubscriptionId ([string]$account.id) `
        -RepositoryRoot $resolvedDataRoot
    Write-Host "Configured exact MI allowlist in ignored local file: $resolvedConfigPath"
    Write-Host 'Run: pwsh .\miops.ps1 interactive'
}

function Invoke-Interactive {
    param([Parameter(Mandatory)][hashtable]$Config)

    $resourceId = [string]$Config.resource.id
    $miName = ($resourceId -split '/')[-1]
    while ($true) {
        Write-Host ''
        Write-Host "Azure SQL MI operations: $miName"
        Write-Host '[1] Status'
        Write-Host '[2] Evidence collection'
        Write-Host '[3] Start dry-run'
        Write-Host '[4] Stop dry-run'
        Write-Host '[5] Apply start'
        Write-Host '[6] Apply stop'
        Write-Host '[7] Schedule show'
        Write-Host '[8] Operation poll'
        Write-Host '[9] Support draft guidance'
        Write-Host '[0] Exit'
        $choice = Read-Host 'Select an action'
        switch ($choice) {
            '1' { Get-MiOpsStatus -Config $Config }
            '2' { Get-MiOpsEvidence -Config $Config }
            '3' { Invoke-MiOpsLifecycle -Config $Config -Action Start }
            '4' { Invoke-MiOpsLifecycle -Config $Config -Action Stop }
            '5' {
                $status = Get-MiOpsStatus -Config $Config
                Write-Host "Apply START to name: $miName | state: $($status.state) | resource: $resourceId"
                $confirmation = Read-Host "Type 'START $miName' to continue"
                if (Test-MiOpsTypedConfirmation -Action START -ManagedInstanceName $miName -Confirmation $confirmation) {
                    Invoke-MiOpsLifecycle -Config $Config -Action Start -Apply -ApproveResourceId $resourceId
                }
                else {
                    Write-Host 'Start cancelled; no mutation was submitted.'
                }
            }
            '6' {
                $status = Get-MiOpsStatus -Config $Config
                Write-Host "Apply STOP to name: $miName | state: $($status.state) | resource: $resourceId"
                $confirmation = Read-Host "Type 'STOP $miName' to continue"
                if (Test-MiOpsTypedConfirmation -Action STOP -ManagedInstanceName $miName -Confirmation $confirmation) {
                    Invoke-MiOpsLifecycle -Config $Config -Action Stop -Apply -ApproveResourceId $resourceId
                }
                else {
                    Write-Host 'Stop cancelled; no mutation was submitted.'
                }
            }
            '7' { Get-MiOpsSchedule -Config $Config }
            '8' {
                $id = Read-Host 'Enter the local operation ID'
                if (-not [string]::IsNullOrWhiteSpace($id)) {
                    Update-MiOpsOperation -Config $Config -OperationId $id
                }
            }
            '9' {
                Write-Host 'Collect evidence first, then create a local redacted draft with:'
                Write-Host "pwsh .\miops.ps1 support-draft -EvidencePath '.miops\evidence\evidence-<timestamp>.json'"
                Write-Host 'This toolkit does not submit a Microsoft Support API request.'
            }
            '0' { return }
            default { Write-Warning 'Select a number from 0 through 9.' }
        }
    }
}

function Assert-CommandTypedConfirmation {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][ValidateSet('START', 'STOP', 'DELETE-SCHEDULE')][string]$Action
    )

    if (-not $Apply) {
        return
    }

    $resourceId = [string]$Config.resource.id
    $miName = ($resourceId -split '/')[-1]
    if ($Action -in @('START', 'STOP')) {
        $status = Get-MiOpsStatus -Config $Config
        Write-Host "Apply $Action to name: $miName | state: $($status.state) | resource: $resourceId"
    }
    else {
        $schedule = Get-MiOpsSchedule -Config $Config
        Write-Host "Delete the existing start/stop schedule for: $miName | resource: $resourceId"
        $schedule
    }

    $expected = if ($Action -eq 'DELETE-SCHEDULE') { "DELETE SCHEDULE $miName" } else { "$Action $miName" }
    $confirmation = if ($TypedConfirmation) {
        $TypedConfirmation
    }
    else {
        Read-Host "Type '$expected' to continue"
    }
    if (-not (Test-MiOpsTypedConfirmation -Action $Action -ManagedInstanceName $miName -Confirmation $confirmation)) {
        throw "Typed confirmation did not exactly match '$expected'. No mutation was submitted."
    }
}

switch ($Command) {
    'setup' {
        Invoke-Setup
    }
    'interactive' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        Invoke-Interactive -Config $config
    }
    'inventory' {
        if (-not $ResourceKind) {
            throw '-ResourceKind is required for inventory and must be one of: all, vm, mi.'
        }
        $config = if (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf) {
            Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        }
        else {
            $null
        }
        Get-MiOpsInventory -ResourceKind $ResourceKind -Config $config -DataRoot $resolvedDataRoot -SubscriptionId $SubscriptionId
    }
    'preflight' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        Invoke-MiOpsPreflight -Config $config
    }
    'status' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        Get-MiOpsStatus -Config $config
    }
    'database-list' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        Get-MiOpsDatabaseList -Config $config -ManagedInstanceId $ManagedInstanceId
    }
    'backup-check' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        Get-MiOpsBackupHealth -Config $config -ManagedInstanceId $ManagedInstanceId -UseSqlHistory:$UseSqlHistory
    }
    'configure-restore-target' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        if (-not $TargetManagedInstanceId) {
            throw '-TargetManagedInstanceId is required for configure-restore-target.'
        }
        $targetName = (Get-MiOpsResourceParts -ResourceId $TargetManagedInstanceId).name
        $expected = "CONFIGURE RESTORE TARGET $targetName"
        $confirmation = if ($TypedConfirmation) {
            $TypedConfirmation
        }
        else {
            Read-Host "Type '$expected' to add this exact restore target"
        }
        Add-MiOpsRestoreTarget -Config $config -TargetManagedInstanceId $TargetManagedInstanceId -TypedConfirmation $confirmation
    }
    'restore-plan' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        foreach ($required in @(
            @{ name = '-SourceDatabase'; value = $SourceDatabase },
            @{ name = '-TargetManagedInstanceId'; value = $TargetManagedInstanceId },
            @{ name = '-TargetDatabase'; value = $TargetDatabase },
            @{ name = '-RestoreTimeUtc'; value = $RestoreTimeUtc }
        )) {
            if ([string]::IsNullOrWhiteSpace([string]$required.value)) {
                throw "$($required.name) is required for restore-plan."
            }
        }
        Invoke-MiOpsRestore -Config $config -SourceManagedInstanceId $SourceManagedInstanceId `
            -SourceDatabase $SourceDatabase -TargetManagedInstanceId $TargetManagedInstanceId `
            -TargetDatabase $TargetDatabase -RestoreTimeUtc $RestoreTimeUtc
    }
    'restore-apply' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        foreach ($required in @(
            @{ name = '-SourceDatabase'; value = $SourceDatabase },
            @{ name = '-TargetManagedInstanceId'; value = $TargetManagedInstanceId },
            @{ name = '-TargetDatabase'; value = $TargetDatabase },
            @{ name = '-RestoreTimeUtc'; value = $RestoreTimeUtc },
            @{ name = '-ApproveSourceResourceId'; value = $ApproveSourceResourceId },
            @{ name = '-ApproveTargetResourceId'; value = $ApproveTargetResourceId }
        )) {
            if ([string]::IsNullOrWhiteSpace([string]$required.value)) {
                throw "$($required.name) is required for restore-apply."
            }
        }
        $targetName = (Get-MiOpsResourceParts -ResourceId $TargetManagedInstanceId).name
        $expected = "RESTORE $SourceDatabase TO $targetName/$TargetDatabase AT $RestoreTimeUtc"
        Write-Host "Source MI/database: $SourceManagedInstanceId / $SourceDatabase"
        Write-Host "Target MI/database: $TargetManagedInstanceId / $TargetDatabase"
        Write-Host "UTC restore time: $RestoreTimeUtc"
        $confirmation = if ($TypedConfirmation) {
            $TypedConfirmation
        }
        else {
            Read-Host "Type '$expected' to submit the non-blocking restore"
        }
        Invoke-MiOpsRestore -Config $config -SourceManagedInstanceId $SourceManagedInstanceId `
            -SourceDatabase $SourceDatabase -TargetManagedInstanceId $TargetManagedInstanceId `
            -TargetDatabase $TargetDatabase -RestoreTimeUtc $RestoreTimeUtc -Apply `
            -ApproveSourceResourceId $ApproveSourceResourceId -ApproveTargetResourceId $ApproveTargetResourceId `
            -TypedConfirmation $confirmation
    }
    'start' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        Assert-CommandTypedConfirmation -Config $config -Action START
        Invoke-MiOpsLifecycle -Config $config -Action Start -Apply:$Apply -ApproveResourceId $ApproveResourceId
    }
    'stop' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        Assert-CommandTypedConfirmation -Config $config -Action STOP
        Invoke-MiOpsLifecycle -Config $config -Action Stop -Apply:$Apply -ApproveResourceId $ApproveResourceId
    }
    'operation-poll' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        if (-not $OperationId) {
            throw '-OperationId is required for operation-poll.'
        }
        Update-MiOpsOperation -Config $config -OperationId $OperationId
    }
    'schedule-show' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        Get-MiOpsSchedule -Config $config
    }
    'schedule-plan' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        New-MiOpsSchedulePlan -Config $config
    }
    'schedule-delete' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        Assert-CommandTypedConfirmation -Config $config -Action DELETE-SCHEDULE
        Remove-MiOpsSchedule -Config $config -Apply:$Apply -ApproveResourceId $ApproveResourceId
    }
    'evidence' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        $arguments = @{ Config = $config }
        if ($LookbackHours -gt 0) {
            $arguments.LookbackHours = $LookbackHours
        }
        Get-MiOpsEvidence @arguments
    }
    'support-draft' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        if (-not $EvidencePath) {
            throw '-EvidencePath is required for support-draft.'
        }
        $resolvedEvidencePath = if ([System.IO.Path]::IsPathRooted($EvidencePath)) {
            $EvidencePath
        }
        else {
            Join-Path $resolvedDataRoot $EvidencePath
        }
        New-MiOpsSupportDraft -Config $config -EvidencePath $resolvedEvidencePath -Title $Title -Impact $Impact
    }
    'sql-adapter-status' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $resolvedDataRoot
        Get-MiOpsSqlAdapterStatus -Config $config
    }
}
