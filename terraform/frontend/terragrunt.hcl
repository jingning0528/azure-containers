terraform {
  source = "../../..//infrastructure//frontend"
}

locals {
  azure_region            = "Canada Central"
  app_env                 = get_env("app_env")
  stack_prefix            = get_env("stack_prefix")
  # Terraform remote Azure Storage config
  tf_remote_state_prefix  = "terraform-remote-state"
  target_env              = get_env("target_env")
  azure_subscription_id   = get_env("azure_subscription_id")
  azure_tenant_id         = get_env("azure_tenant_id")
  storage_account_name    = "${local.tf_remote_state_prefix}${replace(local.azure_subscription_id, "-", "")}" 
  statefile_key           = "${local.stack_prefix}/${local.app_env}/frontend/terraform.tfstate"
  container_name          = "tfstate"
}

# Remote Azure Storage backend for Terraform
generate "remote_state" {
  path      = "backend.tf"
  if_exists = "overwrite"
  contents  = <<EOF
terraform {
  backend "azurerm" {
    storage_account_name = "${local.storage_account_name}"
    container_name       = "${local.container_name}"
    key                  = "${local.statefile_key}"
  }
}
EOF
}

# Remote state dependency for API
dependency "api" {
  config_path = "../api"
  
  mock_outputs = {
    container_app_fqdn = "mock-api.canadacentral.azurecontainerapps.io"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Remote state dependency for database (to get resource group)
dependency "database" {
  config_path = "../database"
  
  mock_outputs = {
    resource_group_name = "rg-quickstart-containers-dev"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

generate "tfvars" {
  path              = "terragrunt.auto.tfvars"
  if_exists         = "overwrite"
  disable_signature = true
  contents          = <<-EOF    app_env = "${local.app_env}"
    app_name = "${local.stack_prefix}-${local.app_env}"
    container_app_fqdn = "${dependency.api.outputs.container_app_fqdn}"
    resource_group_name = "${dependency.database.outputs.resource_group_name}"
    subscription_id = "${local.azure_subscription_id}"
    tenant_id = "${local.azure_tenant_id}"
EOF
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = <<EOF
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "${local.azure_subscription_id}"
  tenant_id      = "${local.azure_tenant_id}"
}
EOF
}