# Azure Initial Setup Script for GitHub OIDC Authentication and Network Configuration
# Prerequisites: 
# - Azure CLI (az) must be installed and authenticated
# - User must have appropriate permissions in Azure subscription

#Requires -Version 5.1

<#
.SYNOPSIS
    Sets up GitHub OIDC authentication with Azure, creates required network subnets, and configures Terraform backend storage
.DESCRIPTION
    This script automates the setup of OpenID Connect (OIDC) authentication between GitHub Actions and Azure,
    creates private endpoints, app, and web subnets within a specified virtual network, and sets up a storage 
    account for Terraform state backend with proper configuration for GitHub Actions workflows.
.PARAMETER SubscriptionId
    Azure subscription ID (mandatory)
.PARAMETER GitHubRepository
    GitHub repository in format "owner/repo" (mandatory)
.PARAMETER VNetName
    Name of the virtual network where subnets will be created (mandatory)
.PARAMETER VNetResourceGroup
    Resource group containing the virtual network (mandatory)
.PARAMETER VNetAddressSpace
    Address space for the virtual network in CIDR format (e.g., "10.0.0.0/16") (mandatory)
.PARAMETER ApplicationName
    Name for the Azure AD Application (optional, defaults to repository name)
.PARAMETER Environment
    Environment suffix for resources (optional, defaults to "dev")
.EXAMPLE
    .\initial-azure-setup.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789abc" -GitHubRepository "myorg/myrepo" -VNetName "my-vnet" -VNetResourceGroup "network-rg" -VNetAddressSpace "10.0.0.0/16"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$GitHubRepository,
    
    [Parameter(Mandatory = $true)]
    [string]$VNetName,
    
    [Parameter(Mandatory = $true)]
    [string]$VNetResourceGroup,
    
    [Parameter(Mandatory = $true)]
    [string]$VNetAddressSpace,
    
    [Parameter(Mandatory = $false)]
    [string]$ApplicationName = "",
    
    [Parameter(Mandatory = $false)]
    [string]$Environment = "dev"
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

# Function to validate CIDR blocks
function Test-CidrBlock {
    param([string]$Cidr)
    
    if ($Cidr -match '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$') {
        return $true
    }
    return $false
}

# Function to create or update Entra ID Application
function New-EntraIdApplication {
    param(
        [string]$AppName,
        [string]$GitHubRepo
    )
    
    Write-ColorOutput "Creating Entra ID Application: $AppName" "Cyan"
    
    # Check if application already exists
    $existingApp = az ad app list --display-name $AppName --output json | ConvertFrom-Json
    
    if ($existingApp.Count -gt 0) {
        Write-ColorOutput "Application '$AppName' already exists. Using existing application." "Yellow"
        $appId = $existingApp[0].appId
    }
    else {
        # Create new application
        $app = az ad app create --display-name $AppName --output json | ConvertFrom-Json
        $appId = $app.appId
        Write-ColorOutput " Created Entra ID Application: $AppName" "Green"
    }
    
    return $appId
}

# Function to create Service Principal
function New-ServicePrincipal {
    param(
        [string]$AppId
    )
    
    Write-ColorOutput "Creating Service Principal for Application ID: $AppId" "Cyan"
    
    # Check if service principal already exists
    $existingSp = az ad sp list --filter "appId eq '$AppId'" --output json | ConvertFrom-Json
    
    if ($existingSp.Count -gt 0) {
        Write-ColorOutput "Service Principal already exists for this application." "Yellow"
        $spObjectId = $existingSp[0].id
    }
    else {
        # Create service principal
        $sp = az ad sp create --id $AppId --output json | ConvertFrom-Json
        $spObjectId = $sp.id
        Write-ColorOutput " Created Service Principal" "Green"
    }
    
    return $spObjectId
}

# Function to add federated credentials
function Add-FederatedCredentials {
    param(
        [string]$AppId,
        [string]$GitHubRepo
    )
    
    Write-ColorOutput "Adding federated credentials for GitHub repository: $GitHubRepo" "Cyan"
    
    # Check existing federated credentials
    $existingCredentials = az ad app federated-credential list --id $AppId --output json | ConvertFrom-Json
    
    # Create federated credential for main branch
    $mainBranchCredentialName = "github-main-branch"
    $mainBranchExists = $existingCredentials | Where-Object { $_.name -eq $mainBranchCredentialName }
    
    if ($mainBranchExists) {
        Write-ColorOutput "Federated credential for main branch already exists" "Yellow"
    }
    else {
        $mainBranchCredential = @{
            name = $mainBranchCredentialName
            issuer = "https://token.actions.githubusercontent.com"
            subject = "repo:$GitHubRepo`:ref:refs/heads/main"
            audiences = @("api://AzureADTokenExchange")
        } | ConvertTo-Json -Depth 3
        
        $tempMainFile = $null
        try {
            # Write JSON to temp file to avoid PowerShell parsing issues
            $tempMainFile = [System.IO.Path]::GetTempFileName()
            $mainBranchCredential | Out-File -FilePath $tempMainFile -Encoding UTF8
            az ad app federated-credential create --id $AppId --parameters "@$tempMainFile" | Out-Null
            Write-ColorOutput " Added federated credential for main branch" "Green"
        }
        finally {
            if ($tempMainFile -and (Test-Path $tempMainFile)) {
                Remove-Item $tempMainFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
    
    # Create federated credential for pull requests
    $prCredentialName = "github-pull-requests"
    $prExists = $existingCredentials | Where-Object { $_.name -eq $prCredentialName }
    
    if ($prExists) {
        Write-ColorOutput "Federated credential for pull requests already exists" "Yellow"
    }
    else {
        $prCredential = @{
            name = $prCredentialName
            issuer = "https://token.actions.githubusercontent.com"
            subject = "repo:$GitHubRepo`:pull_request"
            audiences = @("api://AzureADTokenExchange")
        } | ConvertTo-Json -Depth 3
        
        $tempPrFile = $null
        try {
            # Write JSON to temp file to avoid PowerShell parsing issues
            $tempPrFile = [System.IO.Path]::GetTempFileName()
            $prCredential | Out-File -FilePath $tempPrFile -Encoding UTF8
            az ad app federated-credential create --id $AppId --parameters "@$tempPrFile" | Out-Null
            Write-ColorOutput " Added federated credential for pull requests" "Green"
        }
        finally {
            if ($tempPrFile -and (Test-Path $tempPrFile)) {
                Remove-Item $tempPrFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
    # Create federated credential for environment deployments
    $envCredentialName = "github-environment"
    $envExists = $existingCredentials | Where-Object { $_.name -eq $envCredentialName }
    
    if ($envExists) {
        Write-ColorOutput "Federated credential for environments already exists" "Yellow"
    }
    else {
        $envCredential = @{
            name = $envCredentialName
            issuer = "https://token.actions.githubusercontent.com"
            subject = "repo:$GitHubRepo`:environment:*"
            audiences = @("api://AzureADTokenExchange")
        } | ConvertTo-Json -Depth 3
        
        $tempEnvFile = $null
        try {
            # Write JSON to temp file to avoid PowerShell parsing issues
            $tempEnvFile = [System.IO.Path]::GetTempFileName()
            $envCredential | Out-File -FilePath $tempEnvFile -Encoding UTF8
            az ad app federated-credential create --id $AppId --parameters "@$tempEnvFile" | Out-Null
            Write-ColorOutput " Added federated credential for GitHub environments" "Green"
        }
        finally {
            if ($tempEnvFile -and (Test-Path $tempEnvFile)) {
                Remove-Item $tempEnvFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# Function to assign Azure roles
function Set-AzureRoleAssignments {
    param(
        [string]$ServicePrincipalId,
        [string]$SubscriptionId
    )
    
    Write-ColorOutput "Assigning Azure roles to Service Principal" "Cyan"
    
    # Check if Contributor role is already assigned
    $existingAssignment = az role assignment list --assignee $ServicePrincipalId --role "Contributor" --scope "/subscriptions/$SubscriptionId" --output json | ConvertFrom-Json
    
    if ($existingAssignment.Count -gt 0) {
        Write-ColorOutput "Contributor role already assigned" "Yellow"
    }
    else {
        # Assign Contributor role at subscription level
        az role assignment create --assignee $ServicePrincipalId --role "Contributor" --scope "/subscriptions/$SubscriptionId" | Out-Null
        Write-ColorOutput " Assigned Contributor role" "Green"
    }
}

# Function to create or update virtual network
function New-VirtualNetwork {
    param(
        [string]$VNetName,
        [string]$ResourceGroup,
        [string]$AddressSpace,
        [string]$Location = "Canada Central"
    )
    
    Write-ColorOutput "Creating/updating virtual network: $VNetName" "Cyan"
    
    # Ensure resource group exists
    New-ResourceGroupIfNotExists -ResourceGroupName $ResourceGroup -Location $Location
    
    # Check if VNet exists - handle "not found" gracefully
    $existingVNet = $null
    try {
        $vnetJson = az network vnet show --name $VNetName --resource-group $ResourceGroup --output json 2>$null
        if ($vnetJson -and $vnetJson.Trim() -ne "") {
            $existingVNet = $vnetJson | ConvertFrom-Json
        }
    }
    catch {
        # VNet doesn't exist, which is fine
        $existingVNet = $null
    }
    
    if ($existingVNet) {
        Write-ColorOutput "Virtual network '$VNetName' already exists" "Yellow"
    }
    else {
        # Create virtual network
        az network vnet create --name $VNetName --resource-group $ResourceGroup --address-prefixes $AddressSpace --location $Location | Out-Null
        Write-ColorOutput " Created virtual network: $VNetName" "Green"
    }
}

# Function to create Network Security Group with rules based on subnet type
function New-NetworkSecurityGroup {
    param(
        [string]$ResourceGroup,
        [string]$NsgName,
        [string]$SubnetType,
        [string]$AppSubnetCidr = "",
        [string]$WebSubnetCidr = "",
        [string]$Location = "Canada Central"
    )
    
    Write-ColorOutput "Creating Network Security Group: $NsgName" "Cyan"
    
    # Check if NSG already exists
    $existingNsg = $null
    try {
        $nsgJson = az network nsg show --name $NsgName --resource-group $ResourceGroup --output json 2>$null
        if ($nsgJson -and $nsgJson.Trim() -ne "") {
            $existingNsg = $nsgJson | ConvertFrom-Json
        }
    }
    catch {
        # NSG doesn't exist, which is fine
        $existingNsg = $null
    }
    
    if ($existingNsg) {
        Write-ColorOutput "NSG '$NsgName' already exists, checking rules..." "Yellow"
        
        # Check if rules exist and add missing ones
        $existingRules = az network nsg rule list --nsg-name $NsgName --resource-group $ResourceGroup --output json 2>$null | ConvertFrom-Json
        
        switch ($SubnetType.ToLower()) {
            "privateendpoints" {
                $inboundAppRuleExists = $existingRules | Where-Object { $_.name -eq "AllowInboundFromApp" }
                
                if (-not $inboundAppRuleExists -and -not [string]::IsNullOrEmpty($AppSubnetCidr)) {
                    az network nsg rule create --nsg-name $NsgName --resource-group $ResourceGroup --name "AllowInboundFromApp" --priority 100 --source-address-prefixes $AppSubnetCidr --destination-port-ranges "*" --access Allow --protocol "*" --direction Inbound | Out-Null
                    Write-ColorOutput "  Added inbound rule from app subnet" "Green"
                }
            }
            "app" {
                if ([string]::IsNullOrEmpty($WebSubnetCidr)) {
                    throw "WebSubnetCidr is required for app subnet NSG rules"
                }
                $inboundRuleExists = $existingRules | Where-Object { $_.name -eq "AllowAppFromWeb" }
                $outboundRuleExists = $existingRules | Where-Object { $_.name -eq "AllowAppToWeb" }
                
                if (-not $inboundRuleExists) {
                    az network nsg rule create --nsg-name $NsgName --resource-group $ResourceGroup --name "AllowAppFromWeb" --priority 100 --source-address-prefixes $WebSubnetCidr --destination-port-ranges 3000-9000 --access Allow --protocol Tcp --direction Inbound | Out-Null
                    Write-ColorOutput "  Added missing app inbound rule" "Green"
                }
                if (-not $outboundRuleExists) {
                    az network nsg rule create --nsg-name $NsgName --resource-group $ResourceGroup --name "AllowAppToWeb" --priority 101 --destination-address-prefixes $WebSubnetCidr --source-port-ranges "*" --destination-port-ranges 3000-9000 --access Allow --protocol Tcp --direction Outbound | Out-Null
                    Write-ColorOutput "  Added missing app outbound rule" "Green"
                }
            }
            "web" {
                $httpRuleExists = $existingRules | Where-Object { $_.name -eq "AllowHTTPFromInternet" }
                
                if (-not $httpRuleExists) {
                    az network nsg rule create --nsg-name $NsgName --resource-group $ResourceGroup --name "AllowHTTPFromInternet" --priority 100 --source-address-prefixes "*" --destination-port-ranges "80,443" --access Allow --protocol Tcp --direction Inbound | Out-Null
                    Write-ColorOutput "  Added missing HTTP/HTTPS rule" "Green"
                }
            }
        }
        
        return $true
    }
    
    try {
        # Create the NSG
        az network nsg create --name $NsgName --resource-group $ResourceGroup --location $Location | Out-Null
        Write-ColorOutput " Created NSG: $NsgName" "Green"
        
        # Add security rules based on subnet type
        switch ($SubnetType.ToLower()) {
            "privateendpoints" {
                # Allow inbound and outbound traffic from both app and web subnets
                if (-not [string]::IsNullOrEmpty($AppSubnetCidr)) {
                    az network nsg rule create --nsg-name $NsgName --resource-group $ResourceGroup --name "AllowInboundFromApp" --priority 100 --source-address-prefixes $AppSubnetCidr --destination-port-ranges "*" --access Allow --protocol "*" --direction Inbound | Out-Null
                    az network nsg rule create --nsg-name $NsgName --resource-group $ResourceGroup --name "AllowOutboundToApp" --priority 101 --destination-address-prefixes $AppSubnetCidr --source-port-ranges "*" --destination-port-ranges "*" --access Allow --protocol "*" --direction Outbound | Out-Null
                    Write-ColorOutput "  Added inbound and outbound rules for app subnet" "Green"
                }
                if (-not [string]::IsNullOrEmpty($WebSubnetCidr)) {
                    az network nsg rule create --nsg-name $NsgName --resource-group $ResourceGroup --name "AllowInboundFromWeb" --priority 102 --source-address-prefixes $WebSubnetCidr --destination-port-ranges "*" --access Allow --protocol "*" --direction Inbound | Out-Null
                    az network nsg rule create --nsg-name $NsgName --resource-group $ResourceGroup --name "AllowOutboundToWeb" --priority 103 --destination-address-prefixes $WebSubnetCidr --source-port-ranges "*" --destination-port-ranges "*" --access Allow --protocol "*" --direction Outbound | Out-Null
                    Write-ColorOutput "  Added inbound and outbound rules for web subnet" "Green"
                }
                Write-ColorOutput "  Created security rules for private endpoints subnet" "Green"
            }
            "app" {
                if ([string]::IsNullOrEmpty($WebSubnetCidr)) {
                    throw "WebSubnetCidr is required for app subnet NSG rules"
                }
                # Allow app traffic from web subnet (ports 3000-9000)
                az network nsg rule create --nsg-name $NsgName --resource-group $ResourceGroup --name "AllowAppFromWeb" --priority 100 --source-address-prefixes $WebSubnetCidr --destination-port-ranges 3000-9000 --access Allow --protocol Tcp --direction Inbound | Out-Null
                az network nsg rule create --nsg-name $NsgName --resource-group $ResourceGroup --name "AllowAppToWeb" --priority 101 --destination-address-prefixes $WebSubnetCidr --source-port-ranges "*" --destination-port-ranges 3000-9000 --access Allow --protocol Tcp --direction Outbound | Out-Null
                Write-ColorOutput "  Added application rules for app subnet" "Green"
            }
            "web" {
                # Allow HTTP/HTTPS traffic from internet on standard ports only
                az network nsg rule create --nsg-name $NsgName --resource-group $ResourceGroup --name "AllowHTTPFromInternet" --priority 100 --source-address-prefixes "*" --destination-port-ranges "80,443" --access Allow --protocol Tcp --direction Inbound | Out-Null
                Write-ColorOutput "  Added HTTP/HTTPS rules for web subnet" "Green"
            }
            default {
                Write-ColorOutput "  No specific rules added for subnet type: $SubnetType" "Yellow"
            }
        }
        
        return $true
    }
    catch {
        Write-ColorOutput "Failed to create NSG '$NsgName': $($_.Exception.Message)" "Red"
        return $false
    }
}

# Function to create subnet with associated NSG
function New-Subnet {
    param(
        [string]$VNetName,
        [string]$ResourceGroup,
        [string]$SubnetName,
        [string]$AddressPrefix,
        [string]$SubnetType,
        [string]$AppSubnetCidr = "",
        [string]$WebSubnetCidr = ""
    )
    
    Write-ColorOutput "Creating subnet: $SubnetName" "Cyan"
    
    # Check if subnet exists - handle "not found" gracefully
    $existingSubnet = $null
    try {
        $subnetJson = az network vnet subnet show --vnet-name $VNetName --resource-group $ResourceGroup --name $SubnetName --output json 2>$null
        if ($subnetJson -and $subnetJson.Trim() -ne "") {
            $existingSubnet = $subnetJson | ConvertFrom-Json
        }
    }
    catch {
        # Subnet doesn't exist, which is fine
        $existingSubnet = $null
    }
    
    if ($existingSubnet) {
        Write-ColorOutput "Subnet '$SubnetName' already exists" "Yellow"
        
        # Check if app subnet has required delegation for Container Apps
        if ($SubnetType.ToLower() -eq "app") {
            $delegations = $existingSubnet.delegations
            $hasContainerAppsDelegation = $false
            
            if ($delegations -and $delegations.Count -gt 0) {
                foreach ($delegation in $delegations) {
                    if ($delegation.serviceName -eq "Microsoft.App/environments") {
                        $hasContainerAppsDelegation = $true
                        break
                    }
                }
            }
            
            if (-not $hasContainerAppsDelegation) {
                Write-ColorOutput "Adding missing Container Apps delegation to existing app subnet..." "Yellow"
                try {
                    # Add delegation to existing subnet
                    az network vnet subnet update --vnet-name $VNetName --resource-group $ResourceGroup --name $SubnetName --delegations "Microsoft.App/environments" | Out-Null
                    Write-ColorOutput " Added Container Apps delegation to existing subnet" "Green"
                }
                catch {
                    Write-ColorOutput "Failed to add delegation to existing subnet '$SubnetName': $($_.Exception.Message)" "Red"
                    return $false
                }
            }
            else {
                Write-ColorOutput "Subnet already has Container Apps delegation" "Green"
            }
        }
        
        return $true
    }
    
    try {
        # Generate NSG name: ResourceGroupPrefix-SubnetName-nsg
        $resourceGroupPrefix = $ResourceGroup -replace '-rg$', ''
        $subnetBaseName = $SubnetName -replace '-subnet$', ''  # Remove -subnet suffix for NSG naming
        $nsgName = "$resourceGroupPrefix-$subnetBaseName-nsg"
        
        # Create NSG first
        $nsgCreated = New-NetworkSecurityGroup -ResourceGroup $ResourceGroup -NsgName $nsgName -SubnetType $SubnetType -AppSubnetCidr $AppSubnetCidr -WebSubnetCidr $WebSubnetCidr
        
        if (-not $nsgCreated) {
            Write-ColorOutput "Failed to create NSG for subnet '$SubnetName'" "Red"
            return $false
        }
        
        # Create subnet with NSG association and delegation if needed
        if ($SubnetType.ToLower() -eq "app") {
            # App subnet needs delegation for Azure Container Apps
            az network vnet subnet create --vnet-name $VNetName --resource-group $ResourceGroup --name $SubnetName --address-prefixes $AddressPrefix --network-security-group $nsgName --delegations "Microsoft.App/environments" | Out-Null
            Write-ColorOutput " Created subnet: $SubnetName ($AddressPrefix) with NSG: $nsgName and Container Apps delegation" "Green"
        }
        else {
            # Other subnets don't need delegation
            az network vnet subnet create --vnet-name $VNetName --resource-group $ResourceGroup --name $SubnetName --address-prefixes $AddressPrefix --network-security-group $nsgName | Out-Null
            Write-ColorOutput " Created subnet: $SubnetName ($AddressPrefix) with NSG: $nsgName" "Green"
        }
        return $true
    }
    catch {
        Write-ColorOutput "Failed to create subnet '$SubnetName': $($_.Exception.Message)" "Red"
        return $false
    }
}

# Function to ensure resource group exists
function New-ResourceGroupIfNotExists {
    param(
        [string]$ResourceGroupName,
        [string]$Location = "Canada Central"
    )
    
    # Check if resource group exists - handle "not found" gracefully
    $existingRg = $null
    try {
        $rgJson = az group show --name $ResourceGroupName --output json 2>$null
        if ($rgJson -and $rgJson.Trim() -ne "") {
            $existingRg = $rgJson | ConvertFrom-Json
        }
    }
    catch {
        # Resource group doesn't exist, which is fine
        $existingRg = $null
    }
    
    if ($existingRg) {
        Write-ColorOutput "Resource group '$ResourceGroupName' already exists" "Yellow"
    }
    else {
        az group create --name $ResourceGroupName --location $Location | Out-Null
        Write-ColorOutput " Created resource group: $ResourceGroupName" "Green"
    }
}

# Function to display GitHub secrets configuration
function Show-GitHubSecretsInfo {
    param(
        [string]$SubscriptionId,
        [string]$ClientId,
        [string]$TenantId,
        [string]$GitHubRepo
    )
    
    Write-ColorOutput "`n" "White"
    Write-ColorOutput "======================================" "Cyan"
    Write-ColorOutput "GitHub Secrets Configuration" "Cyan"
    Write-ColorOutput "======================================" "Cyan"
    Write-ColorOutput "Please add the following secrets to your GitHub repository: $GitHubRepo" "Yellow"
    Write-ColorOutput "`nGo to: https://github.com/$GitHubRepo/settings/secrets/actions" "Yellow"
    Write-ColorOutput "`nSecrets to add:" "White"
    Write-ColorOutput "AZURE_CLIENT_ID: $ClientId" "Green"
    Write-ColorOutput "AZURE_TENANT_ID: $TenantId" "Green"
    Write-ColorOutput "AZURE_SUBSCRIPTION_ID: $SubscriptionId" "Green"
    Write-ColorOutput "`n" "White"
    Write-ColorOutput "Sample GitHub Actions workflow configuration:" "White"
    Write-ColorOutput "permissions:" "Gray"
    Write-ColorOutput "  id-token: write" "Gray"
    Write-ColorOutput "  contents: read" "Gray"
    Write-ColorOutput "`nsteps:" "Gray"
    Write-ColorOutput "  - name: Azure Login" "Gray"
    Write-ColorOutput "    uses: azure/login@v1" "Gray"
    Write-ColorOutput "    with:" "Gray"
    Write-ColorOutput "      client-id: `${{ secrets.AZURE_CLIENT_ID }}" "Gray"
    Write-ColorOutput "      tenant-id: `${{ secrets.AZURE_TENANT_ID }}" "Gray"
    Write-ColorOutput "      subscription-id: `${{ secrets.AZURE_SUBSCRIPTION_ID }}" "Gray"
    Write-ColorOutput "======================================" "Cyan"
}

# Function to create storage account for Terraform backend
function New-TerraformStorageAccount {
    param(
        [string]$ResourceGroup,
        [string]$StorageAccountName,
        [string]$ContainerName = "tfstate",
        [string]$Location = "Canada Central"
    )
    
    Write-ColorOutput "Creating Terraform backend storage account: $StorageAccountName" "Cyan"
    
    # Check if storage account already exists
    $existingStorageAccount = $null
    try {
        $storageJson = az storage account show --name $StorageAccountName --resource-group $ResourceGroup --output json 2>$null
        if ($storageJson -and $storageJson.Trim() -ne "") {
            $existingStorageAccount = $storageJson | ConvertFrom-Json
        }
    }
    catch {
        # Storage account doesn't exist, which is fine
        $existingStorageAccount = $null
    }
    
    if ($existingStorageAccount) {
        Write-ColorOutput "Storage account '$StorageAccountName' already exists" "Yellow"
    }
    else {
        # Create storage account with policy-compliant settings (no public access)
        az storage account create --name $StorageAccountName --resource-group $ResourceGroup --location $Location --sku Standard_LRS --kind StorageV2 --access-tier Hot --https-only true --min-tls-version TLS1_2 --allow-blob-public-access false | Out-Null
        Write-ColorOutput " Created storage account: $StorageAccountName" "Green"
    }
    
    # Get storage account key - handle case where storage account creation failed
    $storageKey = $null
    try {
        $storageKey = az storage account keys list --account-name $StorageAccountName --resource-group $ResourceGroup --query '[0].value' --output tsv 2>$null
        if (-not $storageKey) {
            throw "Failed to retrieve storage account key"
        }
    }
    catch {
        Write-ColorOutput "Failed to retrieve storage account key for '$StorageAccountName'. Storage account may not have been created." "Red"
        return $null
    }
    
    # Check if container exists - only if we have a valid storage key
    if ($storageKey) {
        $existingContainer = $null
        try {
            $containerJson = az storage container show --name $ContainerName --account-name $StorageAccountName --account-key $storageKey --output json 2>$null
            if ($containerJson -and $containerJson.Trim() -ne "") {
                $existingContainer = $containerJson | ConvertFrom-Json
            }
        }
        catch {
            # Container doesn't exist, which is fine
            $existingContainer = $null
        }
        
        if ($existingContainer) {
            Write-ColorOutput "Storage container '$ContainerName' already exists" "Yellow"
        }
        else {
            # Create container for Terraform state
            try {
                az storage container create --name $ContainerName --account-name $StorageAccountName --account-key $storageKey --public-access off | Out-Null
                Write-ColorOutput " Created storage container: $ContainerName" "Green"
            }
            catch {
                Write-ColorOutput "Failed to create storage container '$ContainerName'. Error: $($_.Exception.Message)" "Red"
                return $null
            }
        }
    }
    else {
        Write-ColorOutput "Cannot create storage container - no valid storage key available" "Red"
        return $null
    }
    
    return @{
        StorageAccountName = $StorageAccountName
        ContainerName = $ContainerName
        ResourceGroup = $ResourceGroup
        StorageKey = $storageKey
    }
}

# Function to display Terraform backend configuration
function Show-TerraformBackendConfig {
    param(
        [hashtable]$StorageInfo,
        [string]$SubscriptionId
    )
    
    Write-ColorOutput "`n" "White"
    Write-ColorOutput "======================================" "Cyan"
    Write-ColorOutput "Terraform Backend Configuration" "Cyan"
    Write-ColorOutput "======================================" "Cyan"
    Write-ColorOutput "Add the following backend configuration to your Terraform files:" "Yellow"
    Write-ColorOutput "`nterraform {" "Green"
    Write-ColorOutput "  backend `"azurerm`" {" "Green"
    Write-ColorOutput "    resource_group_name   = `"$($StorageInfo.ResourceGroup)`"" "Green"
    Write-ColorOutput "    storage_account_name  = `"$($StorageInfo.StorageAccountName)`"" "Green"
    Write-ColorOutput "    container_name        = `"$($StorageInfo.ContainerName)`"" "Green"
    Write-ColorOutput "    key                   = `"terraform.tfstate`"" "Green"
    Write-ColorOutput "    subscription_id       = `"$SubscriptionId`"" "Green"
    Write-ColorOutput "    use_oidc              = true" "Green"
    Write-ColorOutput "  }" "Green"
    Write-ColorOutput "}" "Green"
    Write-ColorOutput "`nFor GitHub Actions, add these environment variables to your workflow:" "Yellow"
    Write-ColorOutput "env:" "Gray"
    Write-ColorOutput "  ARM_CLIENT_ID: `${{ secrets.AZURE_CLIENT_ID }}" "Gray"
    Write-ColorOutput "  ARM_TENANT_ID: `${{ secrets.AZURE_TENANT_ID }}" "Gray"
    Write-ColorOutput "  ARM_SUBSCRIPTION_ID: `${{ secrets.AZURE_SUBSCRIPTION_ID }}" "Gray"
    Write-ColorOutput "  ARM_USE_OIDC: true" "Gray"
    Write-ColorOutput "`nNote: This storage account was created with public access disabled to comply with Azure Policy." "Yellow"
    Write-ColorOutput "======================================" "Cyan"
}

# Function to calculate subnet CIDRs based on VNet address space
function Get-SubnetCidrs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VNetAddressSpace
    )
    
    Write-ColorOutput "Calculating subnet CIDRs from VNet address space: $VNetAddressSpace" "Cyan"
    
    if (-not (Test-CidrBlock -Cidr $VNetAddressSpace)) {
        Write-ColorOutput "Invalid VNet address space format: $VNetAddressSpace" "Red"
        exit 1
    }
    
    # Parse the address space
    $parts = $VNetAddressSpace -split '/'
    $ipBase = $parts[0]
    $vnetPrefix = [int]$parts[1]
    
    # Parse the IP octets
    $octets = $ipBase -split '\.'
    
    # Handle different VNet sizes
    if ($vnetPrefix -eq 24) {
        # For /24 VNet, create subnets with app getting most space, private endpoints medium, web least
        Write-ColorOutput "VNet is /24 - creating subnets with optimized sizing (app: /25, private endpoints: /27, web: /28)" "Yellow"
        
        $baseIp = "$($octets[0]).$($octets[1]).$($octets[2])"
        $appSubnetCidr = "$baseIp.0/25"                 # .0 to .127 (128 addresses)
        $privateEndpointsSubnetCidr = "$baseIp.128/27"  # .128 to .159 (32 addresses)
        $webSubnetCidr = "$baseIp.160/28"               # .160 to .175 (16 addresses)
        
    } elseif ($vnetPrefix -le 22) {
        # For /22 or larger VNet, create three /24 subnets
        Write-ColorOutput "VNet is /$vnetPrefix - creating three /24 subnets" "Yellow"
        
        # Calculate subnet base addresses by incrementing the third octet
        $privateEndpointsSubnetBase = "$($octets[0]).$($octets[1]).$($octets[2]).0"
        $appSubnetBase = "$($octets[0]).$($octets[1]).$([int]$octets[2] + 1).0"
        $webSubnetBase = "$($octets[0]).$($octets[1]).$([int]$octets[2] + 2).0"
        
        $privateEndpointsSubnetCidr = "$privateEndpointsSubnetBase/24"
        $appSubnetCidr = "$appSubnetBase/24"
        $webSubnetCidr = "$webSubnetBase/24"
        
    } elseif ($vnetPrefix -eq 23) {
        # For /23 VNet, create subnets within the two available /24 blocks
        Write-ColorOutput "VNet is /23 - creating mixed subnet sizes" "Yellow"
        
        $baseIp = "$($octets[0]).$($octets[1]).$($octets[2])"
        $privateEndpointsSubnetCidr = "$baseIp.0/25"     # .0 to .127
        $appSubnetCidr = "$baseIp.128/25"                # .128 to .255
        
        # Use the next /24 block for web subnet
        $nextOctet = [int]$octets[2] + 1
        $webSubnetCidr = "$($octets[0]).$($octets[1]).$nextOctet.0/24"
        
    } else {
        # VNet prefix is between 25-32, too small for three subnets
        Write-ColorOutput "VNet address space too small (/$vnetPrefix). Needs to be at least a /24 to accommodate three subnets." "Red"
        exit 1
    }
    
    Write-ColorOutput " Calculated Private Endpoints Subnet CIDR: $privateEndpointsSubnetCidr" "Green"
    Write-ColorOutput " Calculated App Subnet CIDR: $appSubnetCidr" "Green"
    Write-ColorOutput " Calculated Web Subnet CIDR: $webSubnetCidr" "Green"
    
    return @{
        PrivateEndpointsSubnetCidr = $privateEndpointsSubnetCidr
        AppSubnetCidr = $appSubnetCidr
        WebSubnetCidr = $webSubnetCidr
    }
}

# Main execution
try {
    Write-ColorOutput "Starting Azure Initial Setup..." "Cyan"
    Write-ColorOutput "======================================" "Cyan"
    
    # Validate inputs
    if (-not (Test-CidrBlock $VNetAddressSpace)) {
        throw "Invalid VNet address space format: $VNetAddressSpace"
    }
    
    # Set application name if not provided
    if ([string]::IsNullOrEmpty($ApplicationName)) {
        $ApplicationName = "github-actions-" + $GitHubRepository.Split("/")[1] + "-" + $Environment
    }
    
    # Test Azure CLI
    Test-AzureCLI
    
    # Get tenant ID
    $tenantInfo = az account show --output json | ConvertFrom-Json
    $tenantId = $tenantInfo.tenantId
    
    Write-ColorOutput "`n1. Setting up GitHub OIDC Authentication..." "Cyan"
    Write-ColorOutput "======================================" "Cyan"
    
    # Create Entra ID Application
    $appId = New-EntraIdApplication -AppName $ApplicationName -GitHubRepo $GitHubRepository
    
    # Create Service Principal
    $spObjectId = New-ServicePrincipal -AppId $appId
    
    # Add federated credentials
    Add-FederatedCredentials -AppId $appId -GitHubRepo $GitHubRepository
    
    # Assign Azure roles
    Set-AzureRoleAssignments -ServicePrincipalId $spObjectId -SubscriptionId $SubscriptionId
    
    Write-ColorOutput "`n2. Setting up Network Infrastructure..." "Cyan"
    Write-ColorOutput "======================================" "Cyan"
    
    # Create virtual network
    New-VirtualNetwork -VNetName $VNetName -ResourceGroup $VNetResourceGroup -AddressSpace $VNetAddressSpace
    
    # Calculate subnet CIDRs from VNet address space
    $subnetCidrs = Get-SubnetCidrs -VNetAddressSpace $VNetAddressSpace
    $privateEndpointsSubnetCidr = $subnetCidrs.PrivateEndpointsSubnetCidr
    $appSubnetCidr = $subnetCidrs.AppSubnetCidr
    $webSubnetCidr = $subnetCidrs.WebSubnetCidr
    
    # Create subnets with NSGs
    Write-ColorOutput "`nCreating subnets with Network Security Groups..." "Cyan"
    
    # Create private endpoints subnet (for Azure PaaS services like PostgreSQL Flexible Server)
    $privateEndpointsSubnetCreated = New-Subnet -VNetName $VNetName -ResourceGroup $VNetResourceGroup -SubnetName "privateendpoints-subnet" -AddressPrefix $privateEndpointsSubnetCidr -SubnetType "privateendpoints" -AppSubnetCidr $appSubnetCidr

    # Create app subnet (requires web subnet CIDR for NSG rules)
    $appSubnetCreated = New-Subnet -VNetName $VNetName -ResourceGroup $VNetResourceGroup -SubnetName "app-subnet" -AddressPrefix $appSubnetCidr -SubnetType "app" -WebSubnetCidr $webSubnetCidr

    # Create web subnet (only needs internet access)
    $webSubnetCreated = New-Subnet -VNetName $VNetName -ResourceGroup $VNetResourceGroup -SubnetName "web-subnet" -AddressPrefix $webSubnetCidr -SubnetType "web"

    # Check if all subnets were created successfully
    if (-not ($privateEndpointsSubnetCreated -and $appSubnetCreated -and $webSubnetCreated)) {
        Write-ColorOutput "One or more subnets failed to create. Exiting." "Red"
        exit 1
    }
    
    Write-ColorOutput "`n3. Setting up Terraform Backend Storage..." "Cyan"
    Write-ColorOutput "======================================" "Cyan"
    
    # Generate storage account name (must be globally unique and lowercase)
    $repoName = $GitHubRepository.Split("/")[1]
    $storageAccountName = "tfstate$($repoName.ToLower())$($Environment)"
    # Remove any invalid characters and ensure it's not too long
    $storageAccountName = $storageAccountName -replace '[^a-z0-9]', ''
    if ($storageAccountName.Length -gt 24) {
        $storageAccountName = $storageAccountName.Substring(0, 24)
    }
    
    # Create storage account for Terraform backend
    $storageInfo = New-TerraformStorageAccount -ResourceGroup $VNetResourceGroup -StorageAccountName $storageAccountName
    
    # Check if storage account creation was successful
    if (-not $storageInfo) {
        Write-ColorOutput "Failed to create Terraform backend storage account. This may be due to Azure Policy restrictions." "Red"
        Write-ColorOutput "The storage account creation failed, but network infrastructure was created successfully." "Yellow"
        Write-ColorOutput "You may need to create the storage account manually or use a different resource group/subscription for Terraform backend." "Yellow"
        
        # Continue with the rest of the script, but skip storage validation
        $skipStorageValidation = $true
    }
    else {
        $skipStorageValidation = $false
    }
    
    # Final validation - verify all critical resources exist
    Write-ColorOutput "`nValidating created resources..." "Cyan"
    $validationPassed = $true
    
    # Check if VNet exists
    try {
        $vnetCheck = az network vnet show --name $VNetName --resource-group $VNetResourceGroup --output json 2>$null
        if (-not $vnetCheck) {
            Write-ColorOutput "VNet validation failed" "Red"
            $validationPassed = $false
        } else {
            Write-ColorOutput " VNet validated" "Green"
        }
    } catch {
        Write-ColorOutput "VNet validation failed" "Red"
        $validationPassed = $false
    }
    
    # Check subnets and their NSGs
    $subnets = @("privateendpoints-subnet", "app-subnet", "web-subnet")
    foreach ($subnet in $subnets) {
        try {
            $subnetCheck = az network vnet subnet show --vnet-name $VNetName --resource-group $VNetResourceGroup --name $subnet --output json 2>$null
            if (-not $subnetCheck) {
                Write-ColorOutput "Subnet '$subnet' validation failed" "Red"
                $validationPassed = $false
            } else {
                Write-ColorOutput " Subnet '$subnet' validated" "Green"
            }
        } catch {
            Write-ColorOutput "Subnet '$subnet' validation failed" "Red"
            $validationPassed = $false
        }
    }
    
    # Check storage account (only if it was supposed to be created)
    if (-not $skipStorageValidation -and $storageInfo) {
        try {
            $storageCheck = az storage account show --name $storageInfo.StorageAccountName --resource-group $storageInfo.ResourceGroup --output json 2>$null
            if (-not $storageCheck) {
                Write-ColorOutput "Storage account validation failed" "Red"
                $validationPassed = $false
            } else {
                Write-ColorOutput " Storage account validated" "Green"
            }
        } catch {
            Write-ColorOutput "Storage account validation failed" "Red"
            $validationPassed = $false
        }
    }
    else {
        Write-ColorOutput " Storage account creation was skipped due to policy restrictions" "Yellow"
    }
    
    if (-not $validationPassed) {
        Write-ColorOutput "Resource validation failed. Some resources may not have been created properly." "Red"
        exit 1
    }
    
    # Display GitHub secrets configuration
    Show-GitHubSecretsInfo -SubscriptionId $SubscriptionId -ClientId $appId -TenantId $tenantId -GitHubRepo $GitHubRepository
    
    # Display Terraform backend configuration (only if storage was created successfully)
    if ($storageInfo) {
        Show-TerraformBackendConfig -StorageInfo $storageInfo -SubscriptionId $SubscriptionId
    }
    else {
        Write-ColorOutput "`n" "White"
        Write-ColorOutput "======================================" "Cyan"
        Write-ColorOutput "Terraform Backend Configuration" "Cyan"
        Write-ColorOutput "======================================" "Cyan"
        Write-ColorOutput "Storage account creation failed due to Azure Policy restrictions." "Red"
        Write-ColorOutput "You will need to create a Terraform backend storage account manually." "Yellow"
        Write-ColorOutput "Consider using a different resource group or subscription that allows public storage accounts," "Yellow"
        Write-ColorOutput "or work with your Azure administrator to create the storage account with proper exemptions." "Yellow"
        Write-ColorOutput "======================================" "Cyan"
    }
    
    Write-ColorOutput "`n Azure Initial Setup completed!" "Green"
    if ($storageInfo) {
        Write-ColorOutput "All resources including Terraform backend were created successfully!" "Green"
    }
    else {
        Write-ColorOutput "Network infrastructure and OIDC authentication completed. Terraform backend requires manual setup." "Yellow"
    }
    Write-ColorOutput "Next steps:" "Yellow"
    Write-ColorOutput "1. Add the GitHub secrets shown above to your repository" "White"
    Write-ColorOutput "2. Update your GitHub Actions workflows to use OIDC authentication" "White"
    if ($storageInfo) {
        Write-ColorOutput "3. Configure your Terraform backend using the configuration above" "White"
        Write-ColorOutput "4. Configure your application to use the created subnets" "White"
    }
    else {
        Write-ColorOutput "3. Manually create a Terraform backend storage account (see policy restrictions above)" "White"
        Write-ColorOutput "4. Configure your application to use the created subnets" "White"
    }
}
catch {
    Write-ColorOutput "`nError during setup: $($_.Exception.Message)" "Red"
    Write-ColorOutput "Stack trace: $($_.ScriptStackTrace)" "Red"
    exit 1
}
