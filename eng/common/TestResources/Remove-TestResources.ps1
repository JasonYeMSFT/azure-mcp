#!/usr/bin/env pwsh

# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

#Requires -Version 6.0
#Requires -PSEdition Core
#Requires -Modules @{ModuleName='Az.Accounts'; ModuleVersion='1.6.4'}
#Requires -Modules @{ModuleName='Az.Resources'; ModuleVersion='1.8.0'}

[CmdletBinding(DefaultParameterSetName = 'Default', SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param (
    # Limit $BaseName to enough characters to be under limit plus prefixes, and https://docs.microsoft.com/azure/architecture/best-practices/resource-naming.
    [Parameter(ParameterSetName = 'Default')]
    [Parameter(ParameterSetName = 'Default+Provisioner', Mandatory = $true, Position = 0)]
    [ValidatePattern('^[-a-zA-Z0-9\.\(\)_]{0,80}(?<=[a-zA-Z0-9\(\)])$')]
    [string] $BaseName,

    [Parameter(ParameterSetName = 'ResourceGroup')]
    [Parameter(ParameterSetName = 'ResourceGroup+Provisioner')]
    [string] $ResourceGroupName,

    [Parameter(ParameterSetName = 'Default+Provisioner', Mandatory = $true)]
    [Parameter(ParameterSetName = 'ResourceGroup+Provisioner', Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $TenantId,

    [Parameter()]
    [ValidatePattern('^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')]
    [string] $SubscriptionId,

    [Parameter(ParameterSetName = 'Default+Provisioner', Mandatory = $true)]
    [Parameter(ParameterSetName = 'ResourceGroup+Provisioner', Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')]
    [string] $ProvisionerApplicationId,

    [Parameter(ParameterSetName = 'Default+Provisioner')]
    [Parameter(ParameterSetName = 'ResourceGroup+Provisioner')]
    [string] $ProvisionerApplicationSecret,

    [Parameter(ParameterSetName = 'Default', Position = 0)]
    [Parameter(ParameterSetName = 'Default+Provisioner')]
    [Parameter(ParameterSetName = 'ResourceGroup')]
    [Parameter(ParameterSetName = 'ResourceGroup+Provisioner')]
    [string] $ServiceDirectory,

    [Parameter()]
    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud', 'Dogfood')]
    [string] $Environment = 'AzureCloud',

    [Parameter(ParameterSetName = 'ResourceGroup')]
    [Parameter(ParameterSetName = 'ResourceGroup+Provisioner')]
    [switch] $CI,

    [Parameter()]
    [ValidateSet('test', 'perf')]
    [string] $ResourceType = 'test',

    [Parameter(ParameterSetName = 'Default+Provisioner')]
    [Parameter(ParameterSetName = 'ResourceGroup+Provisioner')]
    [Parameter()]
    [switch] $ServicePrincipalAuth,

    # List of CIDR ranges to add to specific resource firewalls, e.g. @(10.100.0.0/16, 10.200.0.0/16)
    [Parameter()]
    [ValidateCount(0,399)]
    [Validatescript({
        foreach ($range in $PSItem) {
            if ($range -like '*/31' -or $range -like '*/32') {
                throw "Firewall IP Ranges cannot contain a /31 or /32 CIDR"
            }
        }
        return $true
    })]
    [array] $AllowIpRanges = @(),

    [Parameter()]
    [switch] $Force,

    # Captures any arguments not declared here (no parameter errors)
    [Parameter(ValueFromRemainingArguments = $true)]
    $RemoveTestResourcesRemainingArguments
)

. (Join-Path $PSScriptRoot .. scripts Helpers Resource-Helpers.ps1)
. (Join-Path $PSScriptRoot TestResources-Helpers.ps1)

# By default stop for any error.
if (!$PSBoundParameters.ContainsKey('ErrorAction')) {
    $ErrorActionPreference = 'Stop'
}

# Support actions to invoke on exit.
$exitActions = @({
    if ($exitActions.Count -gt 1) {
        Write-Verbose 'Running registered exit actions.'
    }
})

trap {
    # Like using try..finally in PowerShell, but without keeping track of more braces or tabbing content.
    $exitActions.Invoke()
}

. $PSScriptRoot/SubConfig-Helpers.ps1
# Source helpers to purge resources.
. "$PSScriptRoot\..\scripts\Helpers\Resource-Helpers.ps1"

function Log($Message) {
    Write-Host ('{0} - {1}' -f [DateTime]::Now.ToLongTimeString(), $Message)
}

function Retry([scriptblock] $Action, [int] $Attempts = 5) {
    $attempt = 0
    $sleep = 5

    while ($attempt -lt $Attempts) {
        try {
            $attempt++
            return $Action.Invoke()
        } catch {
            if ($attempt -lt $Attempts) {
                $sleep *= 2

                Write-Warning "Attempt $attempt failed: $_. Trying again in $sleep seconds..."
                Start-Sleep -Seconds $sleep
            } else {
                Write-Error -ErrorRecord $_
            }
        }
    }
}

if ($ProvisionerApplicationId -and $ServicePrincipalAuth) {
    $null = Disable-AzContextAutosave -Scope Process

    Log "Logging into service principal '$ProvisionerApplicationId'"
    $provisionerSecret = ConvertTo-SecureString -String $ProvisionerApplicationSecret -AsPlainText -Force
    $provisionerCredential = [System.Management.Automation.PSCredential]::new($ProvisionerApplicationId, $provisionerSecret)

    # Use the given subscription ID if provided.
    $subscriptionArgs = if ($SubscriptionId) {
        @{SubscriptionId = $SubscriptionId}
    }

    $provisionerAccount = Retry {
        Connect-AzAccount -Force:$Force -Tenant $TenantId -Credential $provisionerCredential -ServicePrincipal -Environment $Environment @subscriptionArgs
    }

    $exitActions += {
        Write-Verbose "Logging out of service principal '$($provisionerAccount.Context.Account)'"
        $null = Disconnect-AzAccount -AzureContext $provisionerAccount.Context
    }
}

$context = Get-AzContext

if (!$ResourceGroupName) {
    if ($CI) {
        $envVarName = (BuildServiceDirectoryPrefix (GetServiceLeafDirectoryName $ServiceDirectory)) + "RESOURCE_GROUP"
        $ResourceGroupName = [Environment]::GetEnvironmentVariable($envVarName)
        if (!$ResourceGroupName) {
            Write-Error "Could not find resource group name environment variable '$envVarName'. This is likely due to an earlier failure in the 'Deploy Test Resources' step above."
            exit 0
        }
    } else {
        $serviceName = GetServiceLeafDirectoryName $ServiceDirectory
        $BaseName, $ResourceGroupName = GetBaseAndResourceGroupNames `
            -baseNameDefault $BaseName `
            -resourceGroupNameDefault $ResourceGroupName `
            -user (GetUserName) `
            -serviceDirectoryName $serviceName `
            -CI $CI
    }
}

# If no subscription was specified, try to select the Azure SDK Developer Playground subscription.
# Ignore errors to leave the automatically selected subscription.
if ($SubscriptionId) {
    $currentSubcriptionId = $context.Subscription.Id
    if ($currentSubcriptionId -ne $SubscriptionId) {
        Log "Selecting subscription '$SubscriptionId'"
        $null = Select-AzSubscription -Subscription $SubscriptionId

        $exitActions += {
            Log "Selecting previous subscription '$currentSubcriptionId'"
            $null = Select-AzSubscription -Subscription $currentSubcriptionId
        }

        # Update the context.
        $context = Get-AzContext
    }
} else {
    Log "Attempting to select subscription 'Azure SDK Developer Playground (faa080af-c1d8-40ad-9cce-e1a450ca5b57)'"
    $null = Select-AzSubscription -Subscription 'faa080af-c1d8-40ad-9cce-e1a450ca5b57' -ErrorAction Ignore

    # Update the context.
    $context = Get-AzContext

    $SubscriptionId = $context.Subscription.Id
    $PSBoundParameters['SubscriptionId'] = $SubscriptionId
}

# Use cache of well-known team subs without having to be authenticated.
$wellKnownSubscriptions = @{
    'faa080af-c1d8-40ad-9cce-e1a450ca5b57' = 'Azure SDK Developer Playground'
    'a18897a6-7e44-457d-9260-f2854c0aca42' = 'Azure SDK Engineering System'
    '2cd617ea-1866-46b1-90e3-fffb087ebf9b' = 'Azure SDK Test Resources'
}

# Print which subscription is currently selected.
$subscriptionName = $context.Subscription.Id
if ($wellKnownSubscriptions.ContainsKey($subscriptionName)) {
    $subscriptionName = '{0} ({1})' -f $wellKnownSubscriptions[$subscriptionName], $subscriptionName
}

Log "Selected subscription '$subscriptionName'"

if ($ServiceDirectory) {
    $root = "$PSScriptRoot/../../.."
    if($ServiceDirectory) {
      $root = "$root/sdk/$ServiceDirectory"
    }
    $root = $root | Resolve-Path
    
    $preRemovalScript = Join-Path -Path $root -ChildPath "remove-$ResourceType-resources-pre.ps1"
    if (Test-Path $preRemovalScript) {
        Log "Invoking pre resource removal script '$preRemovalScript'"

        if (!$PSCmdlet.ParameterSetName.StartsWith('ResourceGroup')) {
            $PSBoundParameters.Add('ResourceGroupName', $ResourceGroupName);
        }

        &$preRemovalScript @PSBoundParameters
    }

    # Make sure environment files from New-TestResources -OutFile are removed.
    Get-ChildItem -Path $root -Filter "$ResourceType-resources.json.env" -Recurse | Remove-Item -Force:$Force
    Get-ChildItem -Path $root -Filter ".env" -Recurse -Force | Remove-Item -Force
}

$verifyDeleteScript = {
    try {
        $group = Get-AzResourceGroup -name $ResourceGroupName
    } catch {
        if ($_.ToString().Contains("Provided resource group does not exist")) {
            Write-Verbose "Resource group '$ResourceGroupName' not found. Continuing..."
            return
        }
        throw $_
    }

    if ($group.ProvisioningState -ne "Deleting")
    {
        throw "Resource group is in '$($group.ProvisioningState)' state, expected 'Deleting'"
    }
}

# Get any resources that can be purged after the resource group is deleted coerced into a collection even if empty.
$purgeableResources = Get-PurgeableGroupResources $ResourceGroupName

SetResourceNetworkAccessRules -ResourceGroupName $ResourceGroupName -AllowIpRanges $AllowIpRanges -SetFirewall -CI:$CI
Remove-WormStorageAccounts -GroupPrefix $ResourceGroupName -CI:$CI

Log "Deleting resource group '$ResourceGroupName'"
if ($Force -and !$purgeableResources) {
    Remove-AzResourceGroup -Name "$ResourceGroupName" -Force:$Force -AsJob
    Write-Verbose "Running background job to delete resource group '$ResourceGroupName'"

    Retry $verifyDeleteScript 3
} else {
    # Don't swallow interactive confirmation when Force is false
    Remove-AzResourceGroup -Name "$ResourceGroupName" -Force:$Force
}

# Now purge the resources that should have been deleted with the resource group.
Remove-PurgeableResources $purgeableResources

$exitActions.Invoke()

<#
.SYNOPSIS
Deletes the resource group deployed for a service directory from Azure.

.DESCRIPTION
Removes a resource group and all its resources previously deployed using
New-TestResources.ps1.
If you are not currently logged into an account in the Az PowerShell module,
you will be asked to log in with Connect-AzAccount. Alternatively, you (or a
build pipeline) can pass $ProvisionerApplicationId and
$ProvisionerApplicationSecret to authenticate a service principal with access to
create resources.

.PARAMETER BaseName
A name to use in the resource group and passed to the ARM template as 'baseName'.
This will delete the resource group named 'rg-<baseName>'

.PARAMETER ResourceGroupName
The name of the resource group to delete.

.PARAMETER TenantId
The tenant ID of a service principal when a provisioner is specified.

.PARAMETER SubscriptionId
Optional subscription ID to use when deleting resources when logging in as a
provisioner. You can also use Set-AzContext if not provisioning.

If you do not specify a SubscriptionId and are not logged in, one will be
automatically selected for you by the Connect-AzAccount cmdlet.

Once you are logged in (or were previously), the selected SubscriptionId
will be used for subsequent operations that are specific to a subscription.

.PARAMETER ProvisionerApplicationId
A service principal ID to provision test resources when a provisioner is specified.

.PARAMETER ProvisionerApplicationSecret
A service principal secret (password) to provision test resources when a provisioner is specified.

.PARAMETER ServiceDirectory
A directory under 'sdk' in the repository root - optionally with subdirectories
specified - in which to discover pre removal script named 'remove-test-resources-pre.json'.

.PARAMETER Environment
Name of the cloud environment. The default is the Azure Public Cloud
('PublicCloud')

.PARAMETER CI
Run script in CI mode. Infers various environment variable names based on CI convention.

.PARAMETER Force
Force removal of resource group without asking for user confirmation

.PARAMETER ServicePrincipalAuth
Log in with provided Provisioner application credentials.

.EXAMPLE
Remove-TestResources.ps1 keyvault -Force
Use the currently logged-in account to delete the resources created for Key Vault testing.

.EXAMPLE
Remove-TestResources.ps1 `
    -ResourceGroupName "${env:AZURE_RESOURCEGROUP_NAME}" `
    -TenantId '$(TenantId)' `
    -ProvisionerApplicationId '$(AppId)' `
    -ProvisionerApplicationSecret '$(AppSecret)' `
    -Force `
    -Verbose `
When run in the context of an Azure DevOps pipeline, this script removes the
resource group whose name is stored in the environment variable
AZURE_RESOURCEGROUP_NAME.

#>
