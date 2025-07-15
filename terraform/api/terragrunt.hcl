terraform {
  source = "../../..//infrastructure//api"
}

locals {
  flyway_image             = get_env("flyway_image")
  api_image                = get_env("api_image")
  frontend_image           = get_env("frontend_image", "ghcr.io/bcgov/quickstart-azure-containers/frontend:manual")
  azure_region             = "Canada Central"
  stack_prefix             = get_env("stack_prefix")
  vnet_resource_group_name = get_env("vnet_resource_group_name") # this is the resource group where the VNet exists and initial setup was done.
  vnet_name                = get_env("vnet_name")                # this is the name of the existing VNet
  storage_account_name     = "tfstatequickstartazureco"
  target_env               = get_env("target_env")               # this is the target environment, like dev, test, prod
  azure_subscription_id    = get_env("azure_subscription_id")
  azure_tenant_id          = get_env("azure_tenant_id")
  azure_client_id          = get_env("azure_client_id")         # this is the client ID of the Azure service principal
  app_env                  = get_env("app_env")                 # this is the environment for the app
  container_name           = "tfstate"
  statefile_key            = "${local.stack_prefix}/${local.app_env}/api/terraform.tfstate"
}

# Remote Azure Storage backend for Terraform
generate "remote_state" {
  path      = "backend.tf"
  if_exists = "overwrite"
  contents  = <<EOF
    terraform {
      backend "azurerm" {
        resource_group_name   = "${local.vnet_resource_group_name}"
        storage_account_name  = "${local.storage_account_name}"
        container_name        = "tfstate"
        key                   = "${local.statefile_key}"
        subscription_id       = "${local.azure_subscription_id}"
        tenant_id             = "${local.azure_tenant_id}"
        client_id             = "${local.azure_client_id}"
        use_oidc              = true
      }
    }
EOF
}


generate "tfvars" {
  path              = "terragrunt.auto.tfvars"
  if_exists         = "overwrite"
  disable_signature = true
  contents          = <<-EOF
    app_name                   = "${local.stack_prefix}-api-${local.app_env}"
    app_env                    = "${local.app_env}"
    resource_group_name        = "${get_env("repo_name")}-${local.app_env}"
    location                   = "${local.azure_region}"
    subscription_id            = "${local.azure_subscription_id}"
    tenant_id                  = "${local.azure_tenant_id}"
    vnet_name                  = "${local.vnet_name}"
    vnet_resource_group_name   = "${local.vnet_resource_group_name}"
    container_apps_subnet_name = "app-subnet"
    api_image                  = "${local.api_image}"
    flyway_image               = "${local.flyway_image}"
    frontend_image             = "${local.frontend_image}"
    postgresql_server_fqdn     = "${get_env("postgresql_server_fqdn")}"
    postgresql_admin_password  = "${get_env("db_master_password")}"
    location = "Canada Central"
    common_tags = {
      "Environment" = "${local.target_env}"
      "AppEnv"      = "${local.app_env}"
      "AppName"     = "${local.stack_prefix}-api-${local.app_env}"
      "RepoName"    = "${get_env("repo_name")}"
      "ManagedBy"   = "Terraform"
    }
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
          version = "~> 4.0"
        }
        random = {
          source  = "hashicorp/random"
          version = "~> 3.0"
        }
      }
    }

    provider "azurerm" {
      features {
        key_vault {
          purge_soft_delete_on_destroy    = true
          recover_soft_deleted_key_vaults = true
        }
        resource_group {
          prevent_deletion_if_contains_resources = false
        }
      }
      subscription_id = "${local.azure_subscription_id}"
      tenant_id       = "${local.azure_tenant_id}"
      use_oidc        = true
      client_id       = "${local.azure_client_id}"
    }
EOF
}