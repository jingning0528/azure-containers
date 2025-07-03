# Azure PostgreSQL Flexible Server for Landing Zone compatibility

data "azurerm_client_config" "current" {}

# Data source for existing virtual network
data "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  resource_group_name = var.vnet_resource_group_name
}

# Data source for existing subnet for database
data "azurerm_subnet" "database" {
  name                 = var.database_subnet_name
  virtual_network_name = data.azurerm_virtual_network.main.name
  resource_group_name  = var.vnet_resource_group_name
}

# Random password for PostgreSQL admin
resource "random_password" "postgresql_admin_password" {
  length  = 16
  special = true
}

# Key Vault for storing database credentials - Azure Landing Zone compliant
resource "azurerm_key_vault" "main" {
  name                = "${var.app_name}-kv-${substr(random_id.key_vault_suffix.hex, 0, 6)}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Azure Landing Zone requirements
  enable_rbac_authorization   = true
  soft_delete_retention_days  = 90
  purge_protection_enabled    = true
  
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    
    virtual_network_subnet_ids = [
      data.azurerm_subnet.database.id
    ]
  }

  tags = {
    managed-by = "terraform"
    environment = var.app_env
  }
}

resource "random_id" "key_vault_suffix" {
  byte_length = 4
}

# Store PostgreSQL admin credentials in Key Vault with expiration
resource "azurerm_key_vault_secret" "postgresql_admin_username" {
  name            = "postgresql-admin-username"
  value           = var.postgresql_admin_username
  key_vault_id    = azurerm_key_vault.main.id
  content_type    = "text/plain"
  expiration_date = timeadd(timestamp(), "8760h") # 1 year from now

  depends_on = [azurerm_role_assignment.key_vault_admin]
}

resource "azurerm_key_vault_secret" "postgresql_admin_password" {
  name            = "postgresql-admin-password"
  value           = random_password.postgresql_admin_password.result
  key_vault_id    = azurerm_key_vault.main.id
  content_type    = "password"
  expiration_date = timeadd(timestamp(), "8760h") # 1 year from now

  depends_on = [azurerm_role_assignment.key_vault_admin]
}

# Grant current user Key Vault Administrator role
resource "azurerm_role_assignment" "key_vault_admin" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Landing Zone uses centralized Private DNS Zones - remove local creation
# Private DNS Zone creation is managed by Landing Zone policies
# The landing zone will automatically create DNS records via "DeployIfNotExists" policies

# Data source for existing centralized Private DNS Zone for PostgreSQL
data "azurerm_private_dns_zone" "postgresql" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = var.centralized_dns_resource_group_name
}

# PostgreSQL Flexible Server
resource "azurerm_postgresql_flexible_server" "main" {
  name                = "${var.app_name}-postgresql-${var.app_env}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location

  administrator_login    = var.postgresql_admin_username
  administrator_password = random_password.postgresql_admin_password.result

  sku_name   = var.postgresql_sku_name
  version    = "16"
  
  storage_mb                   = var.postgresql_storage_mb
  backup_retention_days        = var.backup_retention_period
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled

  # Private access configuration for Landing Zone
  delegated_subnet_id = data.azurerm_subnet.database.id
  private_dns_zone_id = data.azurerm_private_dns_zone.postgresql.id

  # High availability configuration
  dynamic "high_availability" {
    for_each = var.ha_enabled ? [1] : []
    content {
      mode                      = "ZoneRedundant"
      standby_availability_zone = var.standby_availability_zone
    }
  }

  # Auto-scaling configuration  
  auto_grow_enabled = var.auto_grow_enabled

  tags = {
    managed-by = "terraform"
    environment = var.app_env
  }

  depends_on = [data.azurerm_private_dns_zone.postgresql]
}

# Create database
resource "azurerm_postgresql_flexible_server_database" "main" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

# PostgreSQL Configuration for performance
resource "azurerm_postgresql_flexible_server_configuration" "shared_preload_libraries" {
  name      = "shared_preload_libraries"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "pg_stat_statements"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_statement" {
  name      = "log_statement"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "all"
}

# Create the main resource group for all application resources
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    managed-by = "terraform"
    environment = var.app_env
  }
}
