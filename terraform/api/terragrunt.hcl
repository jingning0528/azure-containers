terraform {
  source = "../../..//infrastructure//api"
}

locals {
  azure_region            = "Canada Central"
  stack_prefix            = get_env("stack_prefix")
  # Terraform remote Azure Storage config
  tf_remote_state_prefix  = "terraform-remote-state"
  target_env              = get_env("target_env")
  azure_subscription_id   = get_env("azure_subscription_id")
  azure_tenant_id         = get_env("azure_tenant_id")
  app_env                 = get_env("app_env")
  storage_account_name    = "${local.tf_remote_state_prefix}${replace(local.azure_subscription_id, "-", "")}" 
  statefile_key           = "${local.stack_prefix}/${local.app_env}/api/terraform.tfstate"
  container_name          = "tfstate"
  flyway_image            = get_env("flyway_image")
  api_image               = get_env("api_image")
  rds_app_env = (contains(["dev", "test", "prod"], "${local.app_env}") ? "${local.app_env}" : "dev")
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

# Remote state dependency for database
dependency "database" {
  config_path = "../database"
  
  mock_outputs = {
    postgresql_server_fqdn = "mock-postgresql-server.postgres.database.azure.com"
    key_vault_name = "mock-keyvault"
    postgresql_admin_username_secret_name = "postgresql-admin-username"
    postgresql_admin_password_secret_name = "postgresql-admin-password"
    database_name = "app"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

generate "tfvars" {
  path              = "terragrunt.auto.tfvars"
  if_exists         = "overwrite"
  disable_signature = true
  contents          = <<-EOF
  app_name = "${local.stack_prefix}-${local.app_env}"
  app_env = "${local.app_env}"
  api_image = "${local.api_image}"
  flyway_image = "${local.flyway_image}"
    # Database configuration
  postgresql_server_fqdn = "${dependency.database.outputs.postgresql_server_fqdn}"
  database_key_vault_name = "${dependency.database.outputs.key_vault_name}"
  postgresql_admin_username_secret_name = "${dependency.database.outputs.postgresql_admin_username_secret_name}"
  postgresql_admin_password_secret_name = "${dependency.database.outputs.postgresql_admin_password_secret_name}"
  database_name = "${dependency.database.outputs.database_name}"
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