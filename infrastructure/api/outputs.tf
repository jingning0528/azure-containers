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

output "application_insights_connection_string" {
  description = "Application Insights connection string"
  value       = azurerm_application_insights.main.connection_string
  sensitive   = true
}

output "application_insights_instrumentation_key" {
  description = "Application Insights instrumentation key"
  value       = azurerm_application_insights.main.instrumentation_key
  sensitive   = true
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics Workspace"
  value       = azurerm_log_analytics_workspace.main.name
}

# APIM Outputs
output "apim_gateway_url" {
  description = "APIM Gateway URL"
  value       = azurerm_api_management.main.gateway_url
}

output "apim_management_api_url" {
  description = "APIM Management API URL"
  value       = azurerm_api_management.main.management_api_url
}

output "apim_name" {
  description = "Name of the API Management instance"
  value       = azurerm_api_management.main.name
}

output "apim_private_ip_addresses" {
  description = "Private IP addresses of the APIM instance"
  value       = azurerm_api_management.main.private_ip_addresses
}