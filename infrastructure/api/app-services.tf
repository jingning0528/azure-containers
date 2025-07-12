# Azure App Services for API backend with Front Door

# Data source for existing virtual network
data "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  resource_group_name = var.vnet_resource_group_name
}

# Data source for private endpoint subnet
data "azurerm_subnet" "private_endpoint" {
  name                 = var.private_endpoint_subnet_name
  virtual_network_name = data.azurerm_virtual_network.main.name
  resource_group_name  = var.vnet_resource_group_name
}

# Data source for existing subnet for Container Apps/App Services
data "azurerm_subnet" "container_apps" {
  name                 = var.container_apps_subnet_name
  virtual_network_name = data.azurerm_virtual_network.main.name
  resource_group_name  = var.vnet_resource_group_name
}

# Data source for existing web subnet
data "azurerm_subnet" "web" {
  name                 = var.web_subnet_name
  virtual_network_name = data.azurerm_virtual_network.main.name
  resource_group_name  = var.vnet_resource_group_name
}

# Resource group for API resources
resource "azurerm_resource_group" "api" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Log Analytics Workspace
resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.app_name}-logs"
  location            = var.location
  resource_group_name = azurerm_resource_group.api.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  
  tags = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Application Insights for enhanced monitoring and logging
resource "azurerm_application_insights" "main" {
  name                = "${var.app_name}-appinsights"
  location            = var.location
  resource_group_name = azurerm_resource_group.api.name
  application_type    = "other"
  workspace_id        = azurerm_log_analytics_workspace.main.id
  
  tags = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# User Assigned Managed Identity
resource "azurerm_user_assigned_identity" "container_apps" {
  name                = "${var.app_name}-identity"
  location            = var.location
  resource_group_name = azurerm_resource_group.api.name

  tags = var.common_tags
}

# Container Registry (if using private registry) - Landing Zone compliant
resource "azurerm_container_registry" "main" {
  count               = var.create_container_registry ? 1 : 0
  name                = "${replace(var.app_name, "-", "")}acr"
  resource_group_name = azurerm_resource_group.api.name
  location            = var.location
  sku                 = "Premium"
  admin_enabled       = false

  # Azure Landing Zone security requirements
  public_network_access_enabled = false
  tags = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Grant App Services access to Container Registry
resource "azurerm_role_assignment" "acr_pull" {
  count                = var.create_container_registry ? 1 : 0
  scope                = azurerm_container_registry.main[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.container_apps.principal_id
}

# App Service Plan for container-based applications
resource "azurerm_service_plan" "main" {
  name                = "${var.app_name}-asp"
  resource_group_name = azurerm_resource_group.api.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "P1v3"  # Premium v3 for container support and VNet integration

  tags = var.common_tags
  lifecycle {
    ignore_changes = [
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# App Service for API backend with container
resource "azurerm_linux_web_app" "api" {
  name                = "${var.app_name}-api-app"
  resource_group_name = azurerm_resource_group.api.name
  location            = var.location
  service_plan_id     = azurerm_service_plan.main.id

  # VNet integration for secure communication
  virtual_network_subnet_id = data.azurerm_subnet.container_apps.id

  # Enable HTTPS only
  https_only = true

  # Enable managed identity
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.container_apps.id]
  }

  site_config {
    always_on                         = true
    container_registry_use_managed_identity = true
    container_registry_managed_identity_client_id = azurerm_user_assigned_identity.container_apps.client_id
    
    # Health check configuration
    health_check_path                 = "/api/health"
    
    # Application stack for container
    application_stack {
      docker_image_name   = var.api_image
      docker_registry_url = var.create_container_registry ? "https://${azurerm_container_registry.main[0].login_server}" : "https://index.docker.io"
    }

    # Configure for container deployment
    ftps_state = "Disabled"
    
    # Restrict access to Front Door only
    ip_restriction {
      service_tag               = "AzureFrontDoor.Backend"
      ip_address               = null
      virtual_network_subnet_id = null
      action                   = "Allow"
      priority                 = 100
      name                     = "AllowFrontDoor"
      headers {
        x_azure_fdid = [azurerm_cdn_frontdoor_profile.main.resource_guid]
      }
    }

    # Deny all other traffic
    ip_restriction {
      ip_address = "0.0.0.0/0"
      action     = "Deny"
      priority   = 200
      name       = "DenyAll"
    }
    
    # CORS configuration for Front Door
    cors {
      allowed_origins = [
        "https://${azurerm_cdn_frontdoor_endpoint.main.host_name}",
        var.custom_domain_name != "" ? "https://${var.custom_domain_name}" : ""
      ]
      support_credentials = true
    }
  }

  # Application settings
  app_settings = {
    "NODE_ENV"                              = var.node_env
    "PORT"                                  = "80"
    "WEBSITES_PORT"                         = "3000"
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE"   = "false"
    "DOCKER_ENABLE_CI"                      = "true"
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.main.connection_string
    "APPINSIGHTS_INSTRUMENTATIONKEY"        = azurerm_application_insights.main.instrumentation_key
    
    # Database configuration using direct variables
    "POSTGRES_HOST"     = var.postgresql_server_fqdn
    "POSTGRES_USER"     = var.postgresql_admin_username
    "POSTGRES_PASSWORD" = var.postgresql_admin_password
    "POSTGRES_DATABASE" = var.database_name
  }

  # Logs configuration
  logs {
    detailed_error_messages = true
    failed_request_tracing  = true
    
    application_logs {
      file_system_level = "Information"
    }
    
    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 100
      }
    }
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# App Service for Flyway database migrations
resource "azurerm_linux_web_app" "flyway" {
  name                = "${var.app_name}-flyway-app"
  resource_group_name = azurerm_resource_group.api.name
  location            = var.location
  service_plan_id     = azurerm_service_plan.main.id

  # VNet integration for secure communication
  virtual_network_subnet_id = data.azurerm_subnet.container_apps.id

  # Enable HTTPS only
  https_only = true

  # Enable managed identity
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.container_apps.id]
  }

  site_config {
    always_on                         = false  # Can be turned off for migration jobs
    container_registry_use_managed_identity = true
    container_registry_managed_identity_client_id = azurerm_user_assigned_identity.container_apps.client_id
    
    # Application stack for container
    application_stack {
      docker_image_name   = var.flyway_image
      docker_registry_url = var.create_container_registry ? "https://${azurerm_container_registry.main[0].login_server}" : "https://index.docker.io"
    }

    # Configure for container deployment
    ftps_state = "Disabled"
  }

  # Application settings for Flyway
  app_settings = {
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
    "DOCKER_ENABLE_CI"                    = "true"
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.main.connection_string
    
    # Flyway configuration using direct variables
    "FLYWAY_URL"                = "jdbc:postgresql://${var.postgresql_server_fqdn}/${var.database_name}?sslmode=require"
    "FLYWAY_USER"               = var.postgresql_admin_username
    "FLYWAY_PASSWORD"           = var.postgresql_admin_password
    "FLYWAY_BASELINE_ON_MIGRATE" = "true"
    "FLYWAY_DEFAULT_SCHEMA"     = "app"
    "FLYWAY_CONNECT_RETRIES"    = "30"
    "FLYWAY_GROUP"              = "true"
    "FLYWAY_LOG_LEVEL"          = "DEBUG"
  }

  # Logs configuration
  logs {
    detailed_error_messages = true
    failed_request_tracing  = true
    
    application_logs {
      file_system_level = "Information"
    }
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Azure Front Door Profile - Premium for private endpoint connectivity
resource "azurerm_cdn_frontdoor_profile" "main" {
  name                = "${var.app_name}-frontdoor"
  resource_group_name = azurerm_resource_group.api.name
  sku_name            = "Premium_AzureFrontDoor"

  tags = var.common_tags
  lifecycle {
    ignore_changes = [
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Front Door Endpoint
resource "azurerm_cdn_frontdoor_endpoint" "main" {
  name                     = "${var.app_name}-endpoint"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  tags = var.common_tags
}

# Front Door Origin Group
resource "azurerm_cdn_frontdoor_origin_group" "main" {
  name                     = "${var.app_name}-origin-group"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  session_affinity_enabled = false

  restore_traffic_time_to_healed_or_new_endpoint_in_minutes = 10

  health_probe {
    interval_in_seconds = 100
    path                = "/api/health"
    protocol            = "Https"
    request_type        = "GET"
  }

  load_balancing {
    additional_latency_in_milliseconds = 50
    sample_size                        = 4
    successful_samples_required        = 3
  }
}

# Front Door Origin with Private Link
resource "azurerm_cdn_frontdoor_origin" "main" {
  name                          = "${var.app_name}-origin"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main.id
  enabled                       = true

  certificate_name_check_enabled = true
  host_name                      = azurerm_linux_web_app.api.default_hostname
  http_port                      = 80
  https_port                     = 443
  origin_host_header             = azurerm_linux_web_app.api.default_hostname
  priority                       = 1
  weight                         = 1000

  # Private Link configuration for App Service
  private_link {
    request_message        = "Request access for Front Door to App Service"
    target_type           = "sites"
    location              = var.location
    private_link_target_id = azurerm_linux_web_app.api.id
  }
}

# Front Door Custom Domain (optional, configure if you have a custom domain)
resource "azurerm_cdn_frontdoor_custom_domain" "main" {
  count                    = var.custom_domain_name != "" ? 1 : 0
  name                     = "${replace(var.custom_domain_name, ".", "-")}-domain"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  dns_zone_id              = var.dns_zone_id
  host_name                = var.custom_domain_name

  tls {
    certificate_type         = "ManagedCertificate"
  }
}

# Front Door Route with Enhanced Security
resource "azurerm_cdn_frontdoor_route" "main" {
  name                          = "${var.app_name}-route"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.main.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.main.id]

  supported_protocols    = ["Http", "Https"]
  patterns_to_match      = ["/*"]
  forwarding_protocol    = "HttpsOnly"
  link_to_default_domain = true

  # Optional: Link to custom domain
  cdn_frontdoor_custom_domain_ids = var.custom_domain_name != "" ? [azurerm_cdn_frontdoor_custom_domain.main[0].id] : []

  https_redirect_enabled = true

  # Cache configuration for better performance
  cache {
    query_string_caching_behavior = "IgnoreQueryString"
    compression_enabled           = true
    content_types_to_compress = [
      "application/eot",
      "application/font",
      "application/font-sfnt",
      "application/javascript",
      "application/json",
      "application/opentype",
      "application/otf",
      "application/pkcs7-mime",
      "application/truetype",
      "application/ttf",
      "application/vnd.ms-fontobject",
      "application/xhtml+xml",
      "application/xml",
      "application/xml+rss",
      "application/x-font-opentype",
      "application/x-font-truetype",
      "application/x-font-ttf",
      "application/x-httpd-cgi",
      "application/x-javascript",
      "application/x-mpegurl",
      "application/x-opentype",
      "application/x-otf",
      "application/x-perl",
      "application/x-ttf",
      "font/eot",
      "font/ttf",
      "font/otf",
      "font/opentype",
      "image/svg+xml",
      "text/css",
      "text/csv",
      "text/html",
      "text/javascript",
      "text/js",
      "text/plain",
      "text/richtext",
      "text/tab-separated-values",
      "text/xml",
      "text/x-script",
      "text/x-component",
      "text/x-java-source"
    ]
  }
}

# WAF Policy for Front Door Premium
resource "azurerm_cdn_frontdoor_firewall_policy" "main" {
  name                = "${replace(var.app_name, "-", "")}fdwaf"
  resource_group_name = azurerm_resource_group.api.name
  sku_name            = "Premium_AzureFrontDoor"
  enabled             = true
  mode                = "Prevention"

  # Enhanced WAF rules for Premium
  managed_rule {
    type    = "Microsoft_DefaultRuleSet"
    version = "2.1"
    action  = "Block"
    
    # Additional exclusions can be configured here if needed
    exclusion {
      match_variable = "RequestHeaderNames"
      operator       = "Equals"
      selector       = "x-company-secret-header"
    }
  }

  managed_rule {
    type    = "Microsoft_BotManagerRuleSet"
    version = "1.0"
    action  = "Block"
  }

  # Rate limiting rule (Premium feature)
  custom_rule {
    name                           = "RateLimitRule"
    enabled                        = true
    priority                       = 1
    rate_limit_duration_in_minutes = 1
    rate_limit_threshold           = var.waf_rate_limit_threshold
    type                           = "RateLimitRule"
    action                         = "Block"

    match_condition {
      match_variable     = "RemoteAddr"
      operator           = "IPMatch"
      negation_condition = false
      match_values       = ["0.0.0.0/0"]
    }
  }

  # Geo-blocking rule (Premium feature) - Allow only specific countries
  custom_rule {
    name     = "GeoBlockingRule"
    enabled  = true
    priority = 2
    type     = "MatchRule"
    action   = "Block"

    match_condition {
      match_variable     = "RemoteAddr"
      operator           = "GeoMatch"
      negation_condition = true
      match_values       = var.waf_allowed_countries
    }
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Security Policy for Front Door
resource "azurerm_cdn_frontdoor_security_policy" "main" {
  name                     = "${var.app_name}-security-policy"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.main.id

      association {
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.main.id
        }
        patterns_to_match = ["/*"]
      }

      # Optional: Associate with custom domain
      dynamic "association" {
        for_each = var.custom_domain_name != "" ? [1] : []
        content {
          domain {
            cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_custom_domain.main[0].id
          }
          patterns_to_match = ["/*"]
        }
      }
    }
  }
}

# Private Endpoint for App Service (optional, for enhanced security)
resource "azurerm_private_endpoint" "app_service" {
  count               = var.enable_private_endpoint ? 1 : 0
  name                = "${var.app_name}-app-pe"
  location            = var.location
  resource_group_name = azurerm_resource_group.api.name
  subnet_id           = data.azurerm_subnet.private_endpoint.id

  private_service_connection {
    name                           = "${var.app_name}-app-psc"
    private_connection_resource_id = azurerm_linux_web_app.api.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Auto-scaling settings for App Service Plan
resource "azurerm_monitor_autoscale_setting" "main" {
  name                = "${var.app_name}-autoscale"
  resource_group_name = azurerm_resource_group.api.name
  location            = var.location
  target_resource_id  = azurerm_service_plan.main.id

  profile {
    name = "default"

    capacity {
      default = 2
      minimum = 1
      maximum = 10
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.main.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT1M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.main.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 25
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT1M"
      }
    }
  }

  notification {
    email {
      send_to_subscription_administrator    = true
      send_to_subscription_co_administrator = true
    }
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Outputs for App Services configuration
output "app_service_url" {
  description = "The URL of the App Service"
  value       = "https://${azurerm_linux_web_app.api.default_hostname}"
}

output "front_door_endpoint_url" {
  description = "The URL of the Front Door endpoint"
  value       = "https://${azurerm_cdn_frontdoor_endpoint.main.host_name}"
}

output "front_door_custom_domain_url" {
  description = "The URL of the custom domain (if configured)"
  value       = var.custom_domain_name != "" ? "https://${var.custom_domain_name}" : ""
}

output "app_service_plan_id" {
  description = "The ID of the App Service Plan"
  value       = azurerm_service_plan.main.id
}

output "flyway_app_service_url" {
  description = "The URL of the Flyway App Service"
  value       = "https://${azurerm_linux_web_app.flyway.default_hostname}"
}

output "front_door_profile_id" {
  description = "The ID of the Front Door Profile"
  value       = azurerm_cdn_frontdoor_profile.main.id
}
