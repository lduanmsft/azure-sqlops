[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet(
        'preflight',
        'setup',
        'interactive',
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
    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$ManagedInstanceId,
    [string]$ApproveManagedInstanceId,
    [int]$LookbackHours,
    [switch]$UseDeviceCode,
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
    Invoke-MiOpsAzLogin -TenantId $TenantId -UseDeviceCode:$UseDeviceCode
    $tenant = $null
    if ($TenantId) {
        $tenant = Resolve-MiOpsTenant -TenantId $TenantId
    }
    elseif ($SubscriptionId) {
        $subscriptionMatch = @(Get-MiOpsEnabledSubscriptions | Where-Object { [string]$_.id -ieq $SubscriptionId })
        if ($subscriptionMatch.Count -ne 1) {
            throw "Subscription '$SubscriptionId' is not an accessible enabled subscription."
        }
        $tenantGuidFromSubscription = [string]$subscriptionMatch[0].tenantId
        $tenant = @(Get-MiOpsTenants | Where-Object { [string]$_.tenantId -ieq $tenantGuidFromSubscription }) | Select-Object -First 1
        if (-not $tenant) {
            throw "Azure CLI could not resolve the tenant for subscription '$SubscriptionId'."
        }
    }
    else {
        $tenants = @(Get-MiOpsTenants)
        if ($tenants.Count -eq 0) {
            throw 'No signed-in Azure tenants were returned by Azure CLI.'
        }
        Write-Host 'Accessible tenants:'
        Show-NumberedItems -Items $tenants -Formatter {
            param($item)
            "$($item.defaultDomain) | $($item.displayName) | $($item.tenantId)"
        }
        $tenant = Select-MiOpsNumberedItem -Items $tenants -Prompt 'Select a tenant'
        if (-not $tenant) {
            Write-Host 'Setup cancelled; no configuration was changed.'
            return
        }
    }
    $tenantGuid = [string]$tenant.tenantId
    $subscriptions = @(Get-MiOpsEnabledSubscriptions -TenantGuid $tenantGuid)
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
        -ResourceId ([string]$selectedInstance.id) -TenantId $tenantGuid -SubscriptionId ([string]$account.id)
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

switch ($Command) {
    'setup' {
        Invoke-Setup
    }
    'interactive' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $PSScriptRoot
        Invoke-Interactive -Config $config
    }
    'preflight' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $PSScriptRoot
        Invoke-MiOpsPreflight -Config $config
    }
    'status' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $PSScriptRoot
        Get-MiOpsStatus -Config $config
    }
    'start' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $PSScriptRoot
        Invoke-MiOpsLifecycle -Config $config -Action Start -Apply:$Apply -ApproveResourceId $ApproveResourceId
    }
    'stop' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $PSScriptRoot
        Invoke-MiOpsLifecycle -Config $config -Action Stop -Apply:$Apply -ApproveResourceId $ApproveResourceId
    }
    'operation-poll' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $PSScriptRoot
        if (-not $OperationId) {
            throw '-OperationId is required for operation-poll.'
        }
        Update-MiOpsOperation -Config $config -OperationId $OperationId
    }
    'schedule-show' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $PSScriptRoot
        Get-MiOpsSchedule -Config $config
    }
    'schedule-plan' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $PSScriptRoot
        New-MiOpsSchedulePlan -Config $config
    }
    'schedule-delete' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $PSScriptRoot
        Remove-MiOpsSchedule -Config $config -Apply:$Apply -ApproveResourceId $ApproveResourceId
    }
    'evidence' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $PSScriptRoot
        $arguments = @{ Config = $config }
        if ($LookbackHours -gt 0) {
            $arguments.LookbackHours = $LookbackHours
        }
        Get-MiOpsEvidence @arguments
    }
    'support-draft' {
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $PSScriptRoot
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
        $config = Get-MiOpsConfig -Path $resolvedConfigPath -RepositoryRoot $PSScriptRoot
        Get-MiOpsSqlAdapterStatus -Config $config
    }
}
