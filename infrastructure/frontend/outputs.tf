output "frontdoor_endpoint_hostname" {
  description = "Hostname of the Front Door endpoint"
  value       = azurerm_cdn_frontdoor_endpoint.frontend.host_name
}

output "frontdoor_endpoint_id" {
  description = "ID of the Front Door endpoint"
  value       = azurerm_cdn_frontdoor_endpoint.frontend.id
}

output "storage_account_name" {
  description = "Name of the storage account"
  value       = azurerm_storage_account.frontend.name
}

output "storage_account_primary_web_endpoint" {
  description = "Primary web endpoint of the storage account"
  value       = azurerm_storage_account.frontend.primary_web_endpoint
}

output "frontdoor_url" {
  description = "URL of the Front Door distribution"
  value       = "https://${azurerm_cdn_frontdoor_endpoint.frontend.host_name}"
}