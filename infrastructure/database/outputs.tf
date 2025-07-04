output "postgresql_server_fqdn" {
  description = "Fully qualified domain name of the PostgreSQL server"
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "postgresql_server_name" {
  description = "Name of the PostgreSQL server"
  value       = azurerm_postgresql_flexible_server.main.name
}

output "database_name" {
  description = "Name of the created database"
  value       = azurerm_postgresql_flexible_server_database.main.name
}

output "ha_enabled" {
  description = "Whether high availability is enabled"
  value       = var.ha_enabled
}

output "resource_group_name" {
  description = "Name of the created resource group"
  value       = azurerm_resource_group.main.name
}

output "postgresql_connection_string" {
  description = "Connection string for PostgreSQL database (without credentials)"
  value       = "postgresql://${azurerm_postgresql_flexible_server.main.fqdn}:5432/${azurerm_postgresql_flexible_server_database.main.name}"
  sensitive   = false
}

output "postgresql_jdbc_connection_string" {
  description = "JDBC Connection string for PostgreSQL database (without credentials)"
  value       = "jdbc:postgresql://${azurerm_postgresql_flexible_server.main.fqdn}:5432/${azurerm_postgresql_flexible_server_database.main.name}?sslmode=require"
  sensitive   = false
}

output "postgresql_admin_username" {
  description = "Administrator username for PostgreSQL server"
  value       = var.postgresql_admin_username
  sensitive   = true
}

output "database_endpoint" {
  description = "Full endpoint for the database including port"
  value       = "${azurerm_postgresql_flexible_server.main.fqdn}:5432"
  sensitive   = false
}
