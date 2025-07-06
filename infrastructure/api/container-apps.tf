# Azure Container Apps for API backend

data "azurerm_client_config" "current" {}

# Data source for existing virtual network
data "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  resource_group_name = var.vnet_resource_group_name
}

# Data source for existing subnet for Container Apps
data "azurerm_subnet" "container_apps" {
  name                 = var.container_apps_subnet_name
  virtual_network_name = data.azurerm_virtual_network.main.name
  resource_group_name  = var.vnet_resource_group_name
}

# Data source for existing web subnet for APIM
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

# Container Apps Environment v2 with workload profiles and VNet integration
resource "azurerm_container_app_environment" "main" {
  name                           = "${var.app_name}-containerapp"
  location                       = var.location
  resource_group_name            = azurerm_resource_group.api.name
  infrastructure_subnet_id       = data.azurerm_subnet.container_apps.id
  internal_load_balancer_enabled = true

  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  # Workload profiles for v2 Container Apps Environment
  # This allows /27 subnet size instead of /23 required by consumption plan
  workload_profile {
    maximum_count = var.max_replicas
    minimum_count = var.min_replicas
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Log Analytics Workspace for Container Apps
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

# User Assigned Managed Identity for Container Apps
resource "azurerm_user_assigned_identity" "container_apps" {
  name                = "${var.app_name}-containerapp-identity"
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

# Grant Container Apps environment access to Container Registry
resource "azurerm_role_assignment" "acr_pull" {
  count                = var.create_container_registry ? 1 : 0
  scope                = azurerm_container_registry.main[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.container_apps.principal_id
}

# Container App for API Backend
resource "azurerm_container_app" "api" {
  name                         = "${var.app_name}-api"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.api.name
  revision_mode               = "Single"

  # Add explicit dependency to ensure proper order
  depends_on = [
    azurerm_container_app_environment.main,
    azurerm_log_analytics_workspace.main
  ]
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.container_apps.id]
  }
  
  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas
    init_container {
      name   = "${var.app_name}-migrations"
      image  = var.flyway_image
      cpu    = var.container_cpu
      memory = var.container_memory

      env {
        name  = "FLYWAY_URL"
        value = "jdbc:postgresql://${var.postgresql_server_fqdn}/${var.database_name}?sslmode=require"
      }

      env {
        name        = "FLYWAY_USER"
        secret_name = "postgres-user"
      }

      env {
        name        = "FLYWAY_PASSWORD"
        secret_name = "postgres-password"
      }

      env {
        name  = "FLYWAY_BASELINE_ON_MIGRATE"
        value = "true"
      }

      env {
        name  = "FLYWAY_DEFAULT_SCHEMA"
        value = "app"
      }
      env {
        name  = "FLYWAY_CONNECT_RETRIES"
        value = "30"
      }
      env {
        name  = "FLYWAY_GROUP"
        value = "true"
      }
      env {
        name  = "FLYWAY_LOG_LEVEL"
        value = "DEBUG"
      }

      # Add Application Insights connection for enhanced logging
      env {
        name  = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        value = azurerm_application_insights.main.connection_string
      }
    }
    container {
      name   = "${var.app_name}-api"
      image  = var.api_image
      cpu    = var.container_cpu
      memory = var.container_memory

      env {
        name  = "NODE_ENV"
        value = var.node_env
      }

      env {
        name  = "PORT"
        value = "3000"
      }

      env {
        name        = "POSTGRES_HOST"
        secret_name = "postgres-host"
      }

      env {
        name        = "POSTGRES_USER"
        secret_name = "postgres-user"
      }

      env {
        name        = "POSTGRES_PASSWORD"
        secret_name = "postgres-password"
      }

      env {
        name        = "POSTGRES_DATABASE"
        secret_name = "postgres-database"
      }

      # Add Application Insights for enhanced logging and monitoring
      env {
        name  = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        value = azurerm_application_insights.main.connection_string
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/api/health"
        port      = 3000
      }

      readiness_probe {
        transport = "HTTP"
        path      = "/api/health"
        port      = 3000
      }
    }
  }

  secret {
    name  = "postgres-host"
    value = var.postgresql_server_fqdn
  }

  secret {
    name  = "postgres-user"
    value = var.postgresql_admin_username
  }

  secret {
    name  = "postgres-password"
    value = var.postgresql_admin_password
  }

  secret {
    name  = "postgres-database"
    value = var.database_name
  }

  ingress {
    allow_insecure_connections = false
    external_enabled          = false
    target_port               = 3000

    traffic_weight {
      percentage      = 100
      latest_revision = true
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

# API Management v2 for proxying requests to Container Apps
resource "azurerm_api_management" "main" {
  name                = "${var.app_name}-apim"
  location            = var.location
  resource_group_name = azurerm_resource_group.api.name
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email
  sku_name           = var.apim_sku_name # e.g., "Developer_1" or "Standard_1"

  # Deploy APIM in web subnet
  virtual_network_type = "Internal"
  virtual_network_configuration {
    subnet_id = data.azurerm_subnet.web.id
  }

  # Identity for accessing other Azure resources
  identity {
    type = "SystemAssigned"
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# API Management API for Container Apps backend
resource "azurerm_api_management_api" "container_apps_api" {
  name                = "${var.app_name}-api"
  resource_group_name = azurerm_resource_group.api.name
  api_management_name = azurerm_api_management.main.name
  revision            = "1"
  display_name        = "${var.app_name} API"
  path                = "api"
  protocols           = ["https"]
  service_url         = "https://${azurerm_container_app.api.latest_revision_fqdn}"

  depends_on = [azurerm_container_app.api]
}

# API Management Backend for Container Apps
resource "azurerm_api_management_backend" "container_apps" {
  name                = "${var.app_name}-backend"
  resource_group_name = azurerm_resource_group.api.name
  api_management_name = azurerm_api_management.main.name
  protocol            = "http"
  url                 = "https://${azurerm_container_app.api.latest_revision_fqdn}"

  # TLS configuration for secure backend communication
  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }

  depends_on = [azurerm_container_app.api]
}

# API Management Operation - Health Check
resource "azurerm_api_management_api_operation" "health_check" {
  operation_id        = "health-check"
  api_name           = azurerm_api_management_api.container_apps_api.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.api.name
  display_name       = "Health Check"
  method             = "GET"
  url_template       = "/health"
  description        = "Health check endpoint for the API"
}

# API Management Operation - All API calls
resource "azurerm_api_management_api_operation" "api_proxy" {
  operation_id        = "api-proxy"
  api_name           = azurerm_api_management_api.container_apps_api.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.api.name
  display_name       = "API Proxy"
  method             = "GET"
  url_template       = "/*"
  description        = "Proxy all API calls to Container Apps backend"

  template_parameter {
    name     = "*"
    type     = "string"
    required = false
  }
}

# API Management Operation - POST/PUT/DELETE operations
resource "azurerm_api_management_api_operation" "api_proxy_post" {
  operation_id        = "api-proxy-post"
  api_name           = azurerm_api_management_api.container_apps_api.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.api.name
  display_name       = "API Proxy POST"
  method             = "POST"
  url_template       = "/*"
  description        = "Proxy POST calls to Container Apps backend"

  template_parameter {
    name     = "*"
    type     = "string"
    required = false
  }
}

# API Management Policy for backend routing
resource "azurerm_api_management_api_operation_policy" "api_proxy_policy" {
  api_name            = azurerm_api_management_api.container_apps_api.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.api.name
  operation_id        = azurerm_api_management_api_operation.api_proxy.operation_id

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="${azurerm_api_management_backend.container_apps.name}" />
    <rewrite-uri template="{urlPath}" />
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
XML
}

# API Management Product for API access control
resource "azurerm_api_management_product" "api_product" {
  product_id          = "${var.app_name}-product"
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.api.name
  display_name        = "${var.app_name} API Product"
  description         = "Product for ${var.app_name} API access"
  published           = true
  approval_required   = false
  subscription_required = var.apim_subscription_required # Set to false for public access
}

# Associate API with Product
resource "azurerm_api_management_product_api" "api_product_association" {
  api_name            = azurerm_api_management_api.container_apps_api.name
  product_id          = azurerm_api_management_product.api_product.product_id
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.api.name
}
