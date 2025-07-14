output "log_analytics_workspace_id" {
  description = "ID of the Log Analytics Workspace"
  value       = azurerm_log_analytics_workspace.main.id
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
# Outputs for App Services configuration
output "app_service_url" {
  description = "The URL of the App Service"
  value       = "https://${azurerm_linux_web_app.api.default_hostname}"
}

output "frontend_app_service_url" {
  description = "The URL of the Frontend App Service"
  value       = "https://${azurerm_linux_web_app.frontend.default_hostname}"
}
/* 

output "application_gateway_fqdn" {
  description = "FQDN of the Application Gateway public IP"
  value       = azurerm_public_ip.app_gateway.fqdn
}

output "application_gateway_public_ip" {
  description = "Public IP address of the Application Gateway"
  value       = azurerm_public_ip.app_gateway.ip_address
}

output "application_gateway_url" {
  description = "URL of the Application Gateway"
  value       = azurerm_public_ip.app_gateway.fqdn != null ? "https://${azurerm_public_ip.app_gateway.fqdn}" : "https://${azurerm_public_ip.app_gateway.ip_address}"
} */