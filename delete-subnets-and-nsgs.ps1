# Azure Subnet and NSG Deletion Script
# This script deletes only the app-subnet and web-subnet (and their NSGs) created by initial-azure-setup.ps1
# Prerequisites: 
# - Azure CLI (az) must be installed and authenticated
# - User must have appropriate permissions in Azure subscription

#Requires -Version 5.1

<#
.SYNOPSIS
    Deletes the app-subnet and web-subnet along with their associated Network Security Groups
.DESCRIPTION
    This script safely deletes the app-subnet and web-subnet created by the initial-azure-setup.ps1 script,
    along with their associated NSGs. It handles dependencies by recursively deleting dependent resources
    and includes safety confirmations.
.PARAMETER SubscriptionId
    Azure subscription ID (mandatory)
.PARAMETER VNetName
    Name of the virtual network containing the subnets (mandatory)
.PARAMETER VNetResourceGroup
    Resource group containing the virtual network (mandatory)
.PARAMETER WhatIf
    Show what would be deleted without actually deleting (optional)
.PARAMETER Force
    Skip confirmation prompts (optional)
.EXAMPLE
    .\delete-subnets-and-nsgs.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789abc" -VNetName "my-vnet" -VNetResourceGroup "network-rg"
.EXAMPLE
    .\delete-subnets-and-nsgs.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789abc" -VNetName "my-vnet" -VNetResourceGroup "network-rg" -WhatIf
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$VNetName,
    
    [Parameter(Mandatory = $true)]
    [string]$VNetResourceGroup,
    
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,
    
    [Parameter(Mandatory = $false)]
    [switch]$Force
)

# Error handling
$ErrorActionPreference = "Stop"

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Function to check if Azure CLI is installed and user is logged in
function Test-AzureCLI {
    try {
        $null = az --version
        Write-ColorOutput " Azure CLI is installed" "Green"
    }
    catch {
        Write-ColorOutput "Azure CLI is not installed or not in PATH" "Red"
        Write-ColorOutput "Please install Azure CLI: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli" "Yellow"
        exit 1
    }

    try {
        $account = az account show --output json | ConvertFrom-Json
        if ($account.id -eq $SubscriptionId) {
            Write-ColorOutput " Logged in to correct Azure subscription: $($account.name)" "Green"
        }
        else {
            Write-ColorOutput "Setting Azure subscription to: $SubscriptionId" "Yellow"
            az account set --subscription $SubscriptionId
        }
    }
    catch {
        Write-ColorOutput "Not logged in to Azure CLI" "Red"
        Write-ColorOutput "Please run 'az login' to authenticate" "Yellow"
        exit 1
    }
}

# Function to get NSG name based on subnet name and resource group
function Get-NSGName {
    param(
        [string]$ResourceGroup,
        [string]$SubnetName
    )
    
    # Generate NSG name: ResourceGroupPrefix-SubnetBaseName-nsg
    $resourceGroupPrefix = $ResourceGroup -replace '-rg$', ''
    $subnetBaseName = $SubnetName -replace '-subnet$', ''  # Remove -subnet suffix for NSG naming
    $nsgName = "$resourceGroupPrefix-$subnetBaseName-nsg"
    
    return $nsgName
}

# Function to check if a resource exists
function Test-AzureResource {
    param(
        [string]$ResourceType,
        [string]$ResourceName,
        [string]$ResourceGroup,
        [string]$VNetName = $null
    )
    
    try {
        switch ($ResourceType.ToLower()) {
            "subnet" {
                $resource = az network vnet subnet show --vnet-name $VNetName --resource-group $ResourceGroup --name $ResourceName --output json 2>$null
            }
            "nsg" {
                $resource = az network nsg show --name $ResourceName --resource-group $ResourceGroup --output json 2>$null
            }
            default {
                throw "Unknown resource type: $ResourceType"
            }
        }
        
        if ($resource -and $resource.Trim() -ne "") {
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

# Function to get subnet dependencies
function Get-SubnetDependencies {
    param(
        [string]$VNetName,
        [string]$ResourceGroup,
        [string]$SubnetName
    )
    
    Write-ColorOutput "Checking dependencies for subnet: $SubnetName" "Cyan"
    
    $dependencies = @()
    
    try {
        # Get subnet details
        $subnetJson = az network vnet subnet show --vnet-name $VNetName --resource-group $ResourceGroup --name $SubnetName --output json 2>$null
        if (-not $subnetJson) {
            Write-ColorOutput "Subnet '$SubnetName' not found" "Yellow"
            return $dependencies
        }
        
        $subnet = $subnetJson | ConvertFrom-Json
        
        # Check for network interfaces
        if ($subnet.ipConfigurations -and $subnet.ipConfigurations.Count -gt 0) {
            foreach ($ipConfig in $subnet.ipConfigurations) {
                $nicId = $ipConfig.id -replace '/ipConfigurations/.*$', ''
                $dependencies += @{
                    Type = "NetworkInterface"
                    Name = ($nicId -split '/')[-1]
                    ResourceGroup = ($nicId -split '/')[4]
                    Id = $nicId
                }
            }
        }
        
        # Check for private endpoints
        if ($subnet.privateEndpoints -and $subnet.privateEndpoints.Count -gt 0) {
            foreach ($pe in $subnet.privateEndpoints) {
                $dependencies += @{
                    Type = "PrivateEndpoint"
                    Name = ($pe.id -split '/')[-1]
                    ResourceGroup = ($pe.id -split '/')[4]
                    Id = $pe.id
                }
            }
        }
        
        # Check for Container App environments (app subnet delegation)
        if ($subnet.delegations -and $subnet.delegations.Count -gt 0) {
            foreach ($delegation in $subnet.delegations) {
                if ($delegation.serviceName -eq "Microsoft.App/environments") {
                    # Look for Container App environments in the subscription that might be using this subnet
                    $containerAppEnvs = az containerapp env list --output json 2>$null | ConvertFrom-Json
                    if ($containerAppEnvs) {
                        foreach ($env in $containerAppEnvs) {
                            if ($env.properties.vnetConfiguration -and 
                                $env.properties.vnetConfiguration.infrastructureSubnetId -like "*$SubnetName*") {
                                $dependencies += @{
                                    Type = "ContainerAppEnvironment"
                                    Name = $env.name
                                    ResourceGroup = $env.resourceGroup
                                    Id = $env.id
                                }
                            }
                        }
                    }
                }
            }
        }
        
        # Check for service endpoints or other Azure services
        if ($subnet.serviceEndpoints -and $subnet.serviceEndpoints.Count -gt 0) {
            Write-ColorOutput "  Found service endpoints (these will be removed with subnet)" "Yellow"
        }
        
    }
    catch {
        Write-ColorOutput "Error checking dependencies for subnet '$SubnetName': $($_.Exception.Message)" "Red"
    }
    
    return $dependencies
}

# Function to delete resource dependencies
function Remove-SubnetDependencies {
    param(
        [array]$Dependencies,
        [bool]$WhatIf = $false
    )
    
    if ($Dependencies.Count -eq 0) {
        Write-ColorOutput "  No dependencies found" "Green"
        return $true
    }
    
    Write-ColorOutput "  Found $($Dependencies.Count) dependencies to remove:" "Yellow"
    foreach ($dep in $Dependencies) {
        Write-ColorOutput "    - $($dep.Type): $($dep.Name) (Resource Group: $($dep.ResourceGroup))" "Yellow"
    }
    
    if ($WhatIf) {
        Write-ColorOutput "  [WHAT-IF] Would delete $($Dependencies.Count) dependent resources" "Cyan"
        return $true
    }
    
    if (-not $Force) {
        $confirm = Read-Host "Do you want to delete these dependent resources? (y/N)"
        if ($confirm -ne 'y' -and $confirm -ne 'Y') {
            Write-ColorOutput "Skipping dependency deletion. Cannot proceed with subnet deletion." "Red"
            return $false
        }
    }
    
    foreach ($dep in $Dependencies) {
        try {
            Write-ColorOutput "  Deleting $($dep.Type): $($dep.Name)" "Yellow"
            
            switch ($dep.Type) {
                "NetworkInterface" {
                    # First, try to detach from VM if attached
                    $nicDetails = az network nic show --name $dep.Name --resource-group $dep.ResourceGroup --output json 2>$null | ConvertFrom-Json
                    if ($nicDetails.virtualMachine) {
                        Write-ColorOutput "    Network interface is attached to a VM. Please detach manually or delete the VM first." "Red"
                        return $false
                    }
                    az network nic delete --name $dep.Name --resource-group $dep.ResourceGroup --yes | Out-Null
                }
                "PrivateEndpoint" {
                    az network private-endpoint delete --name $dep.Name --resource-group $dep.ResourceGroup --yes | Out-Null
                }
                "ContainerAppEnvironment" {
                    # This is more complex - Container App environments may have apps deployed
                    Write-ColorOutput "    Container App Environment found. Checking for apps..." "Yellow"
                    $apps = az containerapp list --environment $dep.Name --output json 2>$null | ConvertFrom-Json
                    if ($apps -and $apps.Count -gt 0) {
                        Write-ColorOutput "    Found $($apps.Count) Container Apps. Deleting apps first..." "Yellow"
                        foreach ($app in $apps) {
                            Write-ColorOutput "      Deleting Container App: $($app.name)" "Yellow"
                            az containerapp delete --name $app.name --resource-group $app.resourceGroup --yes | Out-Null
                        }
                    }
                    Write-ColorOutput "    Deleting Container App Environment: $($dep.Name)" "Yellow"
                    az containerapp env delete --name $dep.Name --resource-group $dep.ResourceGroup --yes | Out-Null
                }
                default {
                    Write-ColorOutput "    Unknown dependency type: $($dep.Type)" "Red"
                    return $false
                }
            }
            Write-ColorOutput "    Successfully deleted: $($dep.Name)" "Green"
        }
        catch {
            Write-ColorOutput "    Failed to delete $($dep.Type) '$($dep.Name)': $($_.Exception.Message)" "Red"
            return $false
        }
    }
    
    return $true
}

# Function to delete subnet
function Remove-Subnet {
    param(
        [string]$VNetName,
        [string]$ResourceGroup,
        [string]$SubnetName,
        [bool]$WhatIf = $false
    )
    
    Write-ColorOutput "Processing subnet: $SubnetName" "Cyan"
    
    # Check if subnet exists
    $subnetExists = Test-AzureResource -ResourceType "subnet" -ResourceName $SubnetName -ResourceGroup $ResourceGroup -VNetName $VNetName
    if (-not $subnetExists) {
        Write-ColorOutput "  Subnet '$SubnetName' not found - skipping" "Yellow"
        return $true
    }
    
    if ($WhatIf) {
        Write-ColorOutput "  [WHAT-IF] Would delete subnet: $SubnetName" "Cyan"
        return $true
    }
    
    # Get and handle dependencies
    $dependencies = Get-SubnetDependencies -VNetName $VNetName -ResourceGroup $ResourceGroup -SubnetName $SubnetName
    
    if ($dependencies.Count -gt 0) {
        $dependenciesRemoved = Remove-SubnetDependencies -Dependencies $dependencies -WhatIf $WhatIf
        if (-not $dependenciesRemoved) {
            Write-ColorOutput "  Failed to remove dependencies for subnet '$SubnetName'" "Red"
            return $false
        }
        
        # Wait a bit for Azure to process the dependency deletions
        if (-not $WhatIf) {
            Write-ColorOutput "  Waiting for dependency deletions to complete..." "Yellow"
            Start-Sleep -Seconds 30
        }
    }
    
    # Delete the subnet
    try {
        Write-ColorOutput "  Deleting subnet: $SubnetName" "Yellow"
        az network vnet subnet delete --vnet-name $VNetName --resource-group $ResourceGroup --name $SubnetName | Out-Null
        Write-ColorOutput "  Successfully deleted subnet: $SubnetName" "Green"
        return $true
    }
    catch {
        Write-ColorOutput "  Failed to delete subnet '$SubnetName': $($_.Exception.Message)" "Red"
        return $false
    }
}

# Function to delete NSG
function Remove-NSG {
    param(
        [string]$ResourceGroup,
        [string]$NsgName,
        [bool]$WhatIf = $false
    )
    
    Write-ColorOutput "Processing NSG: $NsgName" "Cyan"
    
    # Check if NSG exists
    $nsgExists = Test-AzureResource -ResourceType "nsg" -ResourceName $NsgName -ResourceGroup $ResourceGroup
    if (-not $nsgExists) {
        Write-ColorOutput "  NSG '$NsgName' not found - skipping" "Yellow"
        return $true
    }
    
    if ($WhatIf) {
        Write-ColorOutput "  [WHAT-IF] Would delete NSG: $NsgName" "Cyan"
        return $true
    }
    
    # Check if NSG is associated with other subnets
    try {
        $nsgDetails = az network nsg show --name $NsgName --resource-group $ResourceGroup --output json | ConvertFrom-Json
        if ($nsgDetails.subnets -and $nsgDetails.subnets.Count -gt 0) {
            Write-ColorOutput "  NSG '$NsgName' is still associated with other subnets:" "Yellow"
            foreach ($subnet in $nsgDetails.subnets) {
                $subnetName = ($subnet.id -split '/')[-1]
                Write-ColorOutput "    - $subnetName" "Yellow"
            }
            Write-ColorOutput "  Skipping NSG deletion to avoid affecting other subnets" "Yellow"
            return $true
        }
    }
    catch {
        Write-ColorOutput "  Could not check NSG associations: $($_.Exception.Message)" "Yellow"
    }
    
    # Delete the NSG
    try {
        Write-ColorOutput "  Deleting NSG: $NsgName" "Yellow"
        az network nsg delete --name $NsgName --resource-group $ResourceGroup | Out-Null
        Write-ColorOutput "  Successfully deleted NSG: $NsgName" "Green"
        return $true
    }
    catch {
        Write-ColorOutput "  Failed to delete NSG '$NsgName': $($_.Exception.Message)" "Red"
        return $false
    }
}

# Function to display deletion summary
function Show-DeletionSummary {
    param(
        [string]$VNetName,
        [string]$VNetResourceGroup,
        [bool]$WhatIf = $false
    )
    
    $subnetsToDelete = @("app-subnet", "web-subnet")
    
    Write-ColorOutput "`n" "White"
    Write-ColorOutput "======================================" "Cyan"
    if ($WhatIf) {
        Write-ColorOutput "DELETION PREVIEW (What-If Mode)" "Cyan"
    } else {
        Write-ColorOutput "DELETION SUMMARY" "Cyan"
    }
    Write-ColorOutput "======================================" "Cyan"
    Write-ColorOutput "VNet: $VNetName" "White"
    Write-ColorOutput "Resource Group: $VNetResourceGroup" "White"
    Write-ColorOutput "`nSubnets to be deleted:" "Yellow"
    
    foreach ($subnet in $subnetsToDelete) {
        $subnetExists = Test-AzureResource -ResourceType "subnet" -ResourceName $subnet -ResourceGroup $VNetResourceGroup -VNetName $VNetName
        if ($subnetExists) {
            Write-ColorOutput "  [FOUND] $subnet" "Green"
            
            # Get dependencies
            $deps = Get-SubnetDependencies -VNetName $VNetName -ResourceGroup $VNetResourceGroup -SubnetName $subnet
            if ($deps.Count -gt 0) {
                Write-ColorOutput "    Dependencies:" "Yellow"
                foreach ($dep in $deps) {
                    Write-ColorOutput "      - $($dep.Type): $($dep.Name)" "Yellow"
                }
            }
        } else {
            Write-ColorOutput "  [NOT FOUND] $subnet" "Gray"
        }
    }
    
    Write-ColorOutput "`nNSGs to be deleted:" "Yellow"
    foreach ($subnet in $subnetsToDelete) {
        $nsgName = Get-NSGName -ResourceGroup $VNetResourceGroup -SubnetName $subnet
        $nsgExists = Test-AzureResource -ResourceType "nsg" -ResourceName $nsgName -ResourceGroup $VNetResourceGroup
        if ($nsgExists) {
            Write-ColorOutput "  [FOUND] $nsgName" "Green"
        } else {
            Write-ColorOutput "  [NOT FOUND] $nsgName" "Gray"
        }
    }
    
    Write-ColorOutput "======================================" "Cyan"
}

# Main execution
try {
    Write-ColorOutput "Starting Subnet and NSG Deletion..." "Cyan"
    Write-ColorOutput "======================================" "Cyan"
    
    # Test Azure CLI
    Test-AzureCLI
    
    # Define subnets to delete (only app and web, not private endpoints)
    $subnetsToDelete = @("app-subnet", "web-subnet")
    
    # Show what will be deleted
    Show-DeletionSummary -VNetName $VNetName -VNetResourceGroup $VNetResourceGroup -WhatIf $WhatIf
    
    if ($WhatIf) {
        Write-ColorOutput "`nWhat-If mode enabled. No actual deletions will be performed." "Cyan"
        exit 0
    }
    
    # Final confirmation
    if (-not $Force) {
        Write-ColorOutput "`nWARNING: This will permanently delete the specified subnets and NSGs!" "Red"
        Write-ColorOutput "Any resources deployed in these subnets will also be deleted!" "Red"
        $confirm = Read-Host "`nAre you sure you want to proceed? Type 'DELETE' to confirm"
        if ($confirm -ne 'DELETE') {
            Write-ColorOutput "Operation cancelled by user." "Yellow"
            exit 0
        }
    }
    
    Write-ColorOutput "`nProceeding with deletion..." "Cyan"
    
    $allSuccessful = $true
    
    # Delete subnets first (this will handle dependencies)
    Write-ColorOutput "`n1. Deleting Subnets..." "Cyan"
    Write-ColorOutput "======================================" "Cyan"
    
    foreach ($subnet in $subnetsToDelete) {
        $success = Remove-Subnet -VNetName $VNetName -ResourceGroup $VNetResourceGroup -SubnetName $subnet -WhatIf $false
        if (-not $success) {
            $allSuccessful = $false
        }
    }
    
    # Delete NSGs after subnets
    Write-ColorOutput "`n2. Deleting Network Security Groups..." "Cyan"
    Write-ColorOutput "======================================" "Cyan"
    
    foreach ($subnet in $subnetsToDelete) {
        $nsgName = Get-NSGName -ResourceGroup $VNetResourceGroup -SubnetName $subnet
        $success = Remove-NSG -ResourceGroup $VNetResourceGroup -NsgName $nsgName -WhatIf $false
        if (-not $success) {
            $allSuccessful = $false
        }
    }
    
    # Final status
    Write-ColorOutput "`n" "White"
    Write-ColorOutput "======================================" "Cyan"
    Write-ColorOutput "DELETION COMPLETED" "Cyan"
    Write-ColorOutput "======================================" "Cyan"
    
    if ($allSuccessful) {
        Write-ColorOutput "All specified subnets and NSGs have been successfully deleted!" "Green"
        Write-ColorOutput "`nNote: The VNet '$VNetName' and other resources remain unchanged." "Yellow"
    } else {
        Write-ColorOutput "Some deletions failed. Please check the output above for details." "Red"
        Write-ColorOutput "You may need to manually delete remaining resources or resolve dependencies." "Yellow"
        exit 1
    }
}
catch {
    Write-ColorOutput "`nError during deletion: $($_.Exception.Message)" "Red"
    Write-ColorOutput "Stack trace: $($_.ScriptStackTrace)" "Red"
    exit 1
}
