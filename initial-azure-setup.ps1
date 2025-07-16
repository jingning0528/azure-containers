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
