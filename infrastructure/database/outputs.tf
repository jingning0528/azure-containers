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

output "key_vault_id" {
  description = "ID of the Key Vault"
  value       = azurerm_key_vault.main.id
}

output "key_vault_name" {
  description = "Name of the Key Vault"
  value       = azurerm_key_vault.main.name
}

output "postgresql_admin_username_secret_name" {
  description = "Name of the Key Vault secret containing PostgreSQL admin username"
  value       = azurerm_key_vault_secret.postgresql_admin_username.name
}

output "postgresql_admin_password_secret_name" {
  description = "Name of the Key Vault secret containing PostgreSQL admin password"
  value       = azurerm_key_vault_secret.postgresql_admin_password.name
}

output "ha_enabled" {
  description = "Whether high availability is enabled"
  value       = var.ha_enabled
}

output "resource_group_name" {
  description = "Name of the created resource group"
  value       = azurerm_resource_group.main.name
}
