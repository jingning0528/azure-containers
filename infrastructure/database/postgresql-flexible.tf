# Azure PostgreSQL Flexible Server for Landing Zone compatibility

data "azurerm_client_config" "current" {}

# Data source for existing virtual network
data "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  resource_group_name = var.vnet_resource_group_name
}

# Data source for existing private endpoints subnet
data "azurerm_subnet" "private_endpoints" {
  name                 = "privateendpoints-subnet"
  virtual_network_name = data.azurerm_virtual_network.main.name
  resource_group_name  = var.vnet_resource_group_name
}


# PostgreSQL Flexible Server
resource "azurerm_postgresql_flexible_server" "main" {
  name                = "${var.app_name}-postgresql-${var.app_env}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location

  administrator_login    = var.postgresql_admin_username
  administrator_password = var.db_master_password

  sku_name   = var.postgresql_sku_name
  version    = "16"
  
  storage_mb                   = var.postgresql_storage_mb
  backup_retention_days        = var.backup_retention_period
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled

  # Private network integration using delegated subnet
  # Note: PostgreSQL Flexible Server uses delegated subnet integration
  # rather than traditional private endpoints
  delegated_subnet_id = data.azurerm_subnet.private_endpoints.id
  
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
  
  tags = var.common_tags
  
  # Lifecycle block to handle automatic DNS zone associations by Azure Policy
  lifecycle {
    ignore_changes = [
      # Ignore changes to private_dns_zone_id as it is managed by Azure Policy
      private_dns_zone_id
    ]
  }
}

# Create database
resource "azurerm_postgresql_flexible_server_database" "main" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

# Note: PostgreSQL Flexible Server uses delegated subnet integration
# and does not require a separate private endpoint resource

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
  tags     = var.common_tags
}
