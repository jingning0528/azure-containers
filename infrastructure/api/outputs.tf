output "container_app_fqdn" {
  description = "FQDN of the Container App"
  value       = azurerm_container_app.api.latest_revision_fqdn
}

output "container_app_name" {
  description = "Name of the Container App"
  value       = azurerm_container_app.api.name
}

output "container_app_environment_id" {
  description = "ID of the Container App Environment"
  value       = azurerm_container_app_environment.main.id
}

output "log_analytics_workspace_id" {
  description = "ID of the Log Analytics Workspace"
  value       = azurerm_log_analytics_workspace.main.id
}

output "container_registry_login_server" {
  description = "Login server of the Container Registry"
  value       = var.create_container_registry ? azurerm_container_registry.main[0].login_server : null
}

output "user_assigned_identity_id" {
  description = "ID of the User Assigned Managed Identity"
  value       = azurerm_user_assigned_identity.container_apps.id
}

output "user_assigned_identity_principal_id" {
  description = "Principal ID of the User Assigned Managed Identity"
  value       = azurerm_user_assigned_identity.container_apps.principal_id
}

output "resource_group_name" {
  description = "Name of the API resource group"
  value       = azurerm_resource_group.api.name
}