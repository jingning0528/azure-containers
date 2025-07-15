# Azure Front Door and Storage Account for Frontend

data "azurerm_client_config" "current" {}

# Data source for existing virtual network
data "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  resource_group_name = var.vnet_resource_group_name
}

# Data source for existing subnet for private endpoints
data "azurerm_subnet" "private_endpoints" {
  name                 = var.private_endpoints_subnet_name
  virtual_network_name = data.azurerm_virtual_network.main.name
  resource_group_name  = var.vnet_resource_group_name
}

# Storage Account for static website hosting - Landing Zone compliant
resource "azurerm_storage_account" "frontend" {
  name                     = "${replace(var.app_name, "-", "")}fe${var.app_env}"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # Azure Landing Zone security requirements
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  public_network_access_enabled   = false

  static_website {
    index_document     = "index.html"
    error_404_document = "index.html"
  }

  # Restrict access to specific networks
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]

    virtual_network_subnet_ids = [
      data.azurerm_subnet.private_endpoints.id
    ]
  }

  blob_properties {
    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }

    cors_rule {
      allowed_headers    = ["*"]
      allowed_methods    = ["GET", "HEAD", "OPTIONS"]
      allowed_origins    = ["https://${var.app_name}-frontdoor-${var.app_env}.azurefd.net"]
      exposed_headers    = ["*"]
      max_age_in_seconds = 3600
    }
  }

  tags = {
    managed-by  = "terraform"
    environment = var.app_env
  }
}

# Landing Zone uses centralized Private DNS Zones
# Data source for existing centralized Private DNS Zone for Storage
data "azurerm_private_dns_zone" "storage_blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = var.centralized_dns_resource_group_name
}

# Private Endpoint for Storage Account
resource "azurerm_private_endpoint" "storage_blob" {
  name                = "${var.app_name}-storage-pe-${var.app_env}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = data.azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "${var.app_name}-storage-psc-${var.app_env}"
    private_connection_resource_id = azurerm_storage_account.frontend.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "storage-dns-zone-group"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.storage_blob.id]
  }

  tags = {
    managed-by  = "terraform"
    environment = var.app_env
  }
}

# Front Door Profile
resource "azurerm_cdn_frontdoor_profile" "main" {
  name                = "${var.app_name}-frontdoor-${var.app_env}"
  resource_group_name = var.resource_group_name
  sku_name            = "Standard_AzureFrontDoor"

  tags = {
    managed-by  = "terraform"
    environment = var.app_env
  }
}

# Front Door Endpoint
resource "azurerm_cdn_frontdoor_endpoint" "frontend" {
  name                     = "${var.app_name}-frontend-${var.app_env}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  tags = {
    managed-by  = "terraform"
    environment = var.app_env
  }
}

# Front Door Origin Group for Frontend
resource "azurerm_cdn_frontdoor_origin_group" "frontend" {
  name                     = "${var.app_name}-frontend-og-${var.app_env}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  load_balancing {
    sample_size                 = 4
    successful_samples_required = 3
  }

  health_probe {
    path                = "/"
    request_type        = "HEAD"
    protocol            = "Https"
    interval_in_seconds = 100
  }
}

# Front Door Origin for Storage Account
resource "azurerm_cdn_frontdoor_origin" "frontend" {
  name                          = "${var.app_name}-frontend-origin-${var.app_env}"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.frontend.id

  enabled                        = true
  host_name                      = azurerm_storage_account.frontend.primary_web_host
  http_port                      = 80
  https_port                     = 443
  origin_host_header             = azurerm_storage_account.frontend.primary_web_host
  priority                       = 1
  weight                         = 1000
  certificate_name_check_enabled = true
}

# Front Door Origin Group for API
resource "azurerm_cdn_frontdoor_origin_group" "api" {
  name                     = "${var.app_name}-api-og-${var.app_env}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  load_balancing {
    sample_size                 = 4
    successful_samples_required = 3
  }

  health_probe {
    path                = "/api/health"
    request_type        = "GET"
    protocol            = "Https"
    interval_in_seconds = 100
  }
}

# Front Door Origin for API (Container App)
resource "azurerm_cdn_frontdoor_origin" "api" {
  name                          = "${var.app_name}-api-origin-${var.app_env}"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.api.id

  enabled                        = true
  host_name                      = var.container_app_fqdn
  http_port                      = 80
  https_port                     = 443
  origin_host_header             = var.container_app_fqdn
  priority                       = 1
  weight                         = 1000
  certificate_name_check_enabled = true
}

# Front Door Route for Frontend
resource "azurerm_cdn_frontdoor_route" "frontend" {
  name                          = "${var.app_name}-frontend-route-${var.app_env}"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.frontend.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.frontend.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.frontend.id]

  supported_protocols    = ["Http", "Https"]
  patterns_to_match      = ["/*"]
  forwarding_protocol    = "HttpsOnly"
  link_to_default_domain = true
  https_redirect_enabled = true

  cache {
    query_string_caching_behavior = "IgnoreQueryString"
    compression_enabled           = true
    content_types_to_compress = [
      "text/html",
      "text/css",
      "application/javascript",
      "text/javascript",
      "application/json"
    ]
  }
}

# Front Door Route for API
resource "azurerm_cdn_frontdoor_route" "api" {
  name                          = "${var.app_name}-api-route-${var.app_env}"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.frontend.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.api.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.api.id]

  supported_protocols    = ["Https"]
  patterns_to_match      = ["/api/*"]
  forwarding_protocol    = "HttpsOnly"
  link_to_default_domain = true
}

# WAF Policy for Front Door
resource "azurerm_cdn_frontdoor_firewall_policy" "main" {
  name                              = "${replace(var.app_name, "-", "")}waf${var.app_env}"
  resource_group_name               = var.resource_group_name
  sku_name                          = azurerm_cdn_frontdoor_profile.main.sku_name
  enabled                           = true
  mode                              = "Prevention"
  redirect_url                      = "https://www.gov.bc.ca/"
  custom_block_response_status_code = 403
  custom_block_response_body        = base64encode("Access denied by WAF policy")

  managed_rule {
    type    = "DefaultRuleSet"
    version = "1.0"
    action  = "Block"
  }

  managed_rule {
    type    = "Microsoft_BotManagerRuleSet"
    version = "1.0"
    action  = "Block"
  }

  tags = {
    managed-by  = "terraform"
    environment = var.app_env
  }
}

# Associate WAF Policy with Front Door Endpoint
resource "azurerm_cdn_frontdoor_security_policy" "main" {
  name                     = "${var.app_name}-waf-policy-${var.app_env}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.main.id

      association {
        patterns_to_match = ["/*"]
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.frontend.id
        }
      }
    }
  }
}
