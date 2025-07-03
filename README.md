[![Merge](https://github.com/bcgov/quickstart-azure-containers/actions/workflows/merge.yml/badge.svg)](https://github.com/bcgov/quickstart-azure-containers/actions/workflows/merge.yml)
[![PR](https://github.com/bcgov/quickstart-azure-containers/actions/workflows/pr-open.yml/badge.svg)](https://github.com/bcgov/quickstart-azure-containers/actions/workflows/pr-open.yml)
[![PR Validate](https://github.com/bcgov/quickstart-azure-containers/actions/workflows/pr-validate.yml/badge.svg)](https://github.com/bcgov/quickstart-azure-containers/actions/workflows/pr-validate.yml)
[![CodeQL](https://github.com/bcgov/quickstart-azure-containers/actions/workflows/github-code-scanning/codeql/badge.svg)](https://github.com/bcgov/quickstart-azure-containers/actions/workflows/github-code-scanning/codeql)
[![Pause Azure Resources](https://github.com/bcgov/quickstart-azure-containers/actions/workflows/pause-resources.yml/badge.svg)](https://github.com/bcgov/quickstart-azure-containers/actions/workflows/pause-resources.yml)
[![Resume Azure Resources](https://github.com/bcgov/quickstart-azure-containers/actions/workflows/resume-resources.yml/badge.svg)](https://github.com/bcgov/quickstart-azure-containers/actions/workflows/resume-resources.yml)
# Quickstart for Azure Landing Zone Container Deployments

A secure, compliant infrastructure template for deploying containerized applications to Azure Landing Zone environments. This template follows all Azure Landing Zone security guardrails and best practices for B.C. government cloud deployments.

## 🛡️ Azure Landing Zone Compliance

This template is specifically designed for Azure Landing Zone environments and includes:

- ✅ **No Public IPs** - All resources use private endpoints and internal networking
- ✅ **Private Endpoints** - PostgreSQL, Storage, and Container Registry accessible only privately  
- ✅ **Centralized DNS** - Uses Landing Zone managed Private DNS zones
- ✅ **HTTPS/TLS 1.2** - Enforced across all services
- ✅ **WAF Protection** - Web Application Firewall in Prevention mode
- ✅ **Key Vault Security** - Soft delete, purge protection, and network restrictions
- ✅ **Network Isolation** - All traffic through approved subnets and firewalls
- ✅ **Canada Regions Only** - Deploys to Canada Central/East as required
- ✅ **RBAC Authorization** - Role-based access control throughout
- ✅ **Audit Logging** - Comprehensive logging and monitoring

## 🚀 Quick Start

### Prerequisites
1. Access to an Azure Landing Zone Project Set subscription
2. VNet and subnets provisioned by your Landing Zone team
3. Security group membership (Reader/Contributor/Owner)
4. Terraform state storage account and container

### Deploy
```powershell
# Clone and navigate to project
git clone https://github.com/bcgov/quickstart-azure-containers.git
cd quickstart-azure-containers

# Deploy infrastructure (adjust parameters for your environment)
.\deploy.ps1 `
  -SubscriptionId "12345678-1234-1234-1234-123456789abc" `
  -ResourceGroup "rg-tfstate-central" `
  -StorageAccount "tfstatecentral" `
  -Container "tfstate" `
  -Environment "dev" `
  -Command "apply"
```

## 📖 Documentation

- **[Azure Landing Zone Deployment Guide](AZURE_LANDING_ZONE_GUIDE.md)** - Complete deployment instructions
- **[Compliance Checklist](AZURE_LANDING_ZONE_CHECKLIST.md)** - Pre and post-deployment validation
- **[Sample Configuration](terraform/SAMPLE_TERRAGRUNT_CONFIG.hcl)** - Example terragrunt configuration

## 🏗️ Architecture

The template deploys a three-tier application architecture:

1. **Database Tier**: Azure PostgreSQL Flexible Server with private endpoint
2. **API Tier**: Azure Container Apps with internal load balancer  
3. **Frontend Tier**: Static web app on Azure Storage with Front Door CDN

All components communicate through private networks and follow Azure Landing Zone security patterns.

## 🔧 Customization

Update the terragrunt configurations in `terraform/{module}/{environment}/terragrunt.hcl` with your specific Landing Zone resource names:

```hcl
# VNet configuration (existing Landing Zone resources)
vnet_name = "vnet-landingzone-dev"
vnet_resource_group_name = "rg-networking-dev"
database_subnet_name = "subnet-database-dev"
container_apps_subnet_name = "subnet-container-apps-dev"
private_endpoints_subnet_name = "subnet-private-endpoints-dev"

# Centralized DNS
centralized_dns_resource_group_name = "rg-dns-central"
```

Contact your Landing Zone team for the correct resource names and configurations.

