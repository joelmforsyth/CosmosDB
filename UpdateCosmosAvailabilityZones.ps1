<#PSScriptInfo
 
.VERSION 2.0
 
.GUID 4c077ade-b16c-40db-91c0-f5ec123edb6f
 
.AUTHOR Joel Forsyth
 
.COMPANYNAME
 
.COPYRIGHT
 
.TAGS Cosmos, ZoneAvailability
 
.LICENSEURI
 
.PROJECTURI
 
.ICONURI
 
.EXTERNALMODULEDEPENDENCIES Az,Az.Cosmos
 
.REQUIREDSCRIPTS
 
.EXTERNALSCRIPTDEPENDENCIES
 
.RELEASENOTES
 
 
.PRIVATEDATA
 
#>
#Requires -Module Az
#Requires -Module Az.Cosmos
<#
 
.DESCRIPTION
This script will upgrade a list of Cosmos accounts to zone redundant in a single region without service interruption. 
     
.PARAMETER subscriptionId
Azure subscription Id associated with the Cosmos accounts
.PARAMETER tenantId
Tenant Id associated with the Cosmos accounts
.PARAMETER resourceGroupName
Name of the resource group where the Cosmos accounts are located
.PARAMETER accounts
Names of the Cosmos accounts to be upgraded to zone-redundant
.PARAMETER primaryLocation
Name of the Azure region where the Cosmos accounts currently reside and should persist
.PARAMETER secondaryLocation
Name of the temporary secondary location that needs to be added in order to hotswap zone availability. This location is only used while upgrading.
    
.EXAMPLE
./UpdateCosmosAvailabilityZones.ps1 -subscriptionId <subscriptionId> -tenantId <tenantId> -resourceGroupName MyResourceGroup -accounts @('accountone', 'accounttwo') -primaryLocation centralus -secondaryLocation eastus 
    
.LINK
https://docs.microsoft.com/en-us/azure/cosmos-db/high-availability
     
.NOTES
Azure does not allow the adding of zone availabilty to an existing Cosmos DB account. We must jump through a series of hoops in order to do this without losing the account data or introducing down time.
This is a seven-step process. The steps are mentioned here: https://docs.microsoft.com/en-us/azure/cosmos-db/high-availability#replica-outages
    1. Add a second region
    2. Disable automatic failover to prevent an accidental move while we are removing regions
    3. Failover to second region
    4. Remove first region
    5. Add back first region with zone redundancy
    6. Failover back to the first region
    7. Remove second region
#>
#>
param (
    [Parameter(Mandatory = $True)][string]$subscriptionId,
    [Parameter(Mandatory = $True)][string]$tenantId,
    [Parameter(Mandatory = $True)][string]$resourceGroupName,
    [Parameter(Mandatory = $True)][string[]]$accounts,
    [Parameter(Mandatory = $True)][string]$primaryLocation,
    [Parameter(Mandatory = $True)][string]$secondaryLocation
)

function Update-CosmosRegions {
    param (
        [string]$ResourceGroupName,
        [string]$CosmosName,
        [Microsoft.Azure.Commands.CosmosDB.Models.PSLocation[]]$Locations
    )

    Write-Host "Updating regions..." -ForegroundColor White

    $account = Update-AzCosmosDBAccountRegion `
    -ResourceGroupName $ResourceGroupName `
    -Name $CosmosName `
    -LocationObject $Locations

    if($account)
    {
        Write-Host "Update Successful." -ForegroundColor Green
        while($true)
        {
            Write-Host "Checking status in 10 seconds..." -ForegroundColor White
            Start-Sleep -Seconds 10
            $account = Get-AzCosmosDBAccount -ResourceGroupName $ResourceGroupName -Name $CosmosName
        
            Write-Host "Account is in the state:" $account.ProvisioningState -ForegroundColor White

            if ($account.ProvisioningState -eq "Succeeded")
            {
                Write-Host "Update complete." -ForegroundColor Green
                break
            }
            elseif ($account.ProvisioningState -eq "Failed")
            {
                Write-Host "Update failed." -ForegroundColor Red
                break
            }
        }
    }
    else
    {
        Write-Host "Update failed." -ForegroundColor Red
    }
}

function Update-CosmosFailover {
    param (
        [string]$ResourceGroupName,
        [string]$CosmosName,
        [string[]]$Locations
    )

    Write-Host "Updating failover priority..." -ForegroundColor White

    $account = Update-AzCosmosDBAccountFailoverPriority -ResourceGroupName $ResourceGroupName -Name $CosmosName -FailoverPolicy $Locations

    if($account)
    {
        Write-Host "Update Successful." -ForegroundColor Green
        while($true)
        {
            Write-Host "Checking status in 10..." -ForegroundColor White
            Start-Sleep -Seconds 10
            $account = Get-AzCosmosDBAccount -ResourceGroupName $ResourceGroupName -Name $CosmosName
        
            Write-Host "Write region is now" $account.WriteLocations.LocationName -ForegroundColor White

            if ($account.ProvisioningState -eq "Succeeded")
            {
                Write-Host "Update complete." -ForegroundColor Green
                break
            }
            elseif ($account.ProvisioningState -eq "Failed")
            {
                Write-Host "Update failed." -ForegroundColor Red
                break
            }
        }
    }
    else
    {
        Write-Host "Update failed." -ForegroundColor Red
    }
}

Write-Host "Getting context..." -ForegroundColor Yellow
Connect-AzAccount -SubscriptionId $subscriptionId -TenantId $tenantId

$stopwatch =  [system.diagnostics.stopwatch]::StartNew()

foreach ( $accountName in $accounts )
{
    Write-Host "Starting on" $accountName -ForegroundColor Cyan
    $account = Get-AzCosmosDBAccount -ResourceGroupName $resourceGroupName -Name $accountName
    if ($account.ProvisioningState -eq "Succeeded")
    {
        Write-Host "Verified Cosmos Account:" $account.DocumentEndpoint
        
        Write-Host "Primary Region is:" $primaryLocation
        Write-Host "Secondary Region is:" $secondaryLocation

        # Add secondary region to setup locations. Regions have to be added before changes can be made
        # The first region cannot have zone redundancy
        Write-Host "Adding primary and secondary regions..." -ForegroundColor Cyan
        $locations = @()
        $locations += New-AzCosmosDBLocationObject -LocationName $primaryLocation -FailoverPriority 0 -IsZoneRedundant 0
        $locations += New-AzCosmosDBLocationObject -LocationName $secondaryLocation -FailoverPriority 1 -IsZoneRedundant 0
        Update-CosmosRegions -ResourceGroupName $resourceGroupName -CosmosName $account.Name -Locations $locations 

        # Disable automatic failover just in case
        Write-Host "Disabling automatic failover..." -ForegroundColor Cyan
        Update-AzCosmosDBAccount -ResourceGroupName $resourceGroupName -Name $account.Name  -EnableAutomaticFailover:$false

        #Swap the failover priority to manually cause failover, allowing us to update the primary region
        Write-Host "Failing over to secondary region..." -ForegroundColor Cyan
        $failoverlocations = @($secondaryLocation, $primaryLocation)
        Update-CosmosFailover -ResourceGroupName $resourceGroupName -CosmosName $account.Name -Locations $failoverlocations

        #Remove the primary region
        Write-Host "Removing the primary region..." -ForegroundColor Cyan
        $locations = @()
        $locations += New-AzCosmosDBLocationObject -LocationName $secondaryLocation -FailoverPriority 0 -IsZoneRedundant 0
        Update-CosmosRegions -ResourceGroupName $resourceGroupName -CosmosName $account.Name -Locations $locations

        #Add back primary region with zone redundancy
        Write-Host "Adding back primary region with zone redundancy..." -ForegroundColor Cyan
        $locations = @()
        $locations += New-AzCosmosDBLocationObject -LocationName $secondaryLocation -FailoverPriority 0 -IsZoneRedundant 0
        $locations += New-AzCosmosDBLocationObject -LocationName $primaryLocation -FailoverPriority 1 -IsZoneRedundant 1
        Update-CosmosRegions -ResourceGroupName $resourceGroupName -CosmosName $account.Name -Locations $locations 

        #Swap back to primary region, allowing us to delete secondary region
        Write-Host "Failing over to primary region..." -ForegroundColor Cyan
        $failoverlocations = @($primaryLocation, $secondaryLocation)
        Update-CosmosFailover -ResourceGroupName $resourceGroupName -CosmosName $account.Name -Locations $failoverlocations

        #Remove the secondary region
        Write-Host "Removing the secondary region..." -ForegroundColor Cyan
        $locations = @()
        $locations += New-AzCosmosDBLocationObject -LocationName $primaryLocation -FailoverPriority 0 -IsZoneRedundant 1
        Update-CosmosRegions -ResourceGroupName $resourceGroupName -CosmosName $account.Name -Locations $locations
    }
    else
    {
        Write-Host "Cannot Process. Account is in the state:" $account.ProvisioningState -ForegroundColor Red
    }
}

Write-Host ("Total time: {0}" -f $stopwatch.Elapsed) -ForegroundColor Cyan

Read-Host -Prompt "Press Enter to exit"
